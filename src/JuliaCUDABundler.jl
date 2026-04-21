module JuliaCUDABundler

using Pkg

export bundle_app, BundleConfig

"""
    BundleConfig(; project_dir, output_dir, entry_module, kwargs...)

Configuration for `bundle_app`.

# Required
- `project_dir::String`  — absolute path to the Julia project to bundle.
- `output_dir::String`   — absolute path where the bundle will be created.
- `entry_module::String` — name of the top-level module (e.g. `"MyApp"`).

# Optional
- `entry_function::String = "julia_main"` — the function to call. Must have
  signature `() -> Cint` and read `ARGS` for command-line arguments.
- `bundle_julia::Bool   = true`  — copy the running Julia runtime into the
  bundle. Set to `false` if you require the target machine to have Julia.
- `obfuscate_source::Bool = false` — EXPERIMENTAL. Replaces `.jl` files
  with stubs after precompilation. Currently only useful when combined with
  Docker distribution (Julia 1.12 still validates source hashes against the
  precompile cache, so launching from a stripped bundle requires the cache
  to be regenerated, which defeats the purpose). The recommended way to hide
  source is to ship as a Docker image — source then lives in image layers
  rather than as loose files. See `INTERNALS.md`.
- `juliaup_channel::String = ""` — informational, recorded in metadata.
- `dockerfile_base::String = "nvidia/cuda:13.0.0-runtime-ubuntu24.04"` — base
  image used in the auto-generated `Dockerfile`.
"""
Base.@kwdef struct BundleConfig
    project_dir::String
    output_dir::String
    entry_module::String
    entry_function::String = "julia_main"
    bundle_julia::Bool = true
    obfuscate_source::Bool = false
    juliaup_channel::String = ""
    dockerfile_base::String = "nvidia/cuda:13.0.0-runtime-ubuntu24.04"
end

"""
    bundle_app(config::BundleConfig) -> String

Build a self-contained bundle of a Julia project (returns the output path).

The resulting directory contains:

```
<output_dir>/
├── bin/<EntryModule>     ← bash launcher (the "executable")
├── app/                  ← Project.toml + (possibly stripped) src/
├── julia/                ← Julia runtime (if bundle_julia=true)
├── julia_depot/          ← precompile cache (.ji + .so) — the real code
├── Dockerfile            ← ready to `docker build`
└── BUNDLE_INFO.txt       ← metadata
```
"""
function bundle_app(cfg::BundleConfig)
    out      = abspath(cfg.output_dir)
    bin_dir  = joinpath(out, "bin")
    app_dir  = joinpath(out, "app")
    depot    = joinpath(out, "julia_depot")

    @info "[1/6] Preparing bundle directory" output=out
    rm(out; recursive=true, force=true)
    mkpath(bin_dir); mkpath(app_dir); mkpath(depot)

    @info "[2/6] Copying project" from=cfg.project_dir
    _copy_project(cfg.project_dir, app_dir)

    @info "[3/6] Precompiling into private depot (this can take a while)"
    _precompile_into_depot(app_dir, depot, cfg.entry_module)

    if cfg.obfuscate_source
        @info "[4/6] Obfuscating source files (cache will be loaded with --pkgimages=existing)"
        _obfuscate_source!(app_dir, cfg.entry_module)
    else
        @info "[4/6] Source obfuscation disabled — .jl files left intact"
    end

    if cfg.bundle_julia
        @info "[5/6] Bundling Julia runtime"
        _bundle_julia(out)
    else
        @info "[5/6] Skipping Julia runtime (target must have julia in PATH)"
    end

    @info "[6/6] Writing launcher, Dockerfile, metadata"
    _write_launcher(bin_dir, cfg)
    _write_dockerfile(out, cfg)
    _write_metadata(out, cfg)

    @info "✅ Bundle ready" path=out
    @info "   Run locally :  $(bin_dir)/$(cfg.entry_module) [args]"
    @info "   Build image :  cd $out && docker build -t $(lowercase(cfg.entry_module)) ."
    return out
end

# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

function _copy_project(src::String, dst::String)
    # Copy contents of src into dst (which already exists).
    for entry in readdir(src)
        # Skip VCS / dev artifacts
        entry in (".git", ".github", ".vscode", "build", "deps") && continue
        cp(joinpath(src, entry), joinpath(dst, entry); force=true)
    end
end

function _precompile_into_depot(app_dir::String, depot::String, entry_module::String)
    julia_bin = joinpath(Sys.BINDIR, Base.julia_exename())
    env = copy(ENV)
    env["JULIA_DEPOT_PATH"] = depot
    env["JULIA_LOAD_PATH"]  = "@:@stdlib"

    code = """
        using Pkg
        Pkg.instantiate()
        Pkg.precompile()
        # Force-load the entry module so its package image is materialized
        try
            @eval using $entry_module
            @info "Loaded $entry_module successfully"
        catch e
            @warn "Could not load entry module" exception=e
            rethrow()
        end
    """
    run(setenv(`$julia_bin --project=$app_dir --startup-file=no -e $code`, env))
end

"""
Replace the bodies of `.jl` files in `app_dir/src/` with comment-only stubs.

Julia's loader requires the module declaration to exist (the `module X ... end`
shell), but the actual function definitions can live in the precompile cache.
We rewrite each file as a hollow module so anyone reading the bundled source
sees no logic.
"""
function _obfuscate_source!(app_dir::String, entry_module::String)
    src_dir = joinpath(app_dir, "src")
    isdir(src_dir) || return

    files = String[]
    for (root, _, fs) in walkdir(src_dir)
        for f in fs
            endswith(f, ".jl") && push!(files, joinpath(root, f))
        end
    end

    for path in files
        rel  = relpath(path, src_dir)
        modname = splitext(basename(path))[1]
        if path == joinpath(src_dir, "$entry_module.jl")
            # Top-level module file: keep module declaration intact, drop body.
            stub = """
            # === Source removed by JuliaCUDABundler ===
            # File: src/$rel
            # The actual implementation is loaded from the precompile cache
            # under julia_depot/compiled/. This stub exists only so Julia's
            # package loader can locate the module.
            module $entry_module
            end
            """
            write(path, stub)
        else
            # included file: blank module shell so any `include(...)` still
            # resolves to a valid file.
            stub = """
            # === Source removed by JuliaCUDABundler ===
            # File: src/$rel
            """
            write(path, stub)
        end
    end
    @info "    Stripped $(length(files)) source file(s)"
end

function _bundle_julia(out::String)
    julia_root = dirname(Sys.BINDIR)  # e.g. /opt/julia-1.12.2
    dest = joinpath(out, "julia")
    mkpath(dest)
    for d in ("bin", "lib", "share", "libexec", "include")
        s = joinpath(julia_root, d)
        isdir(s) && cp(s, joinpath(dest, d); force=true)
    end
end

function _write_launcher(bin_dir::String, cfg::BundleConfig)
    launcher = joinpath(bin_dir, cfg.entry_module)
    julia_rel = cfg.bundle_julia ? "julia/bin/julia" : ""

    script = """
    #!/usr/bin/env bash
    # === JuliaCUDABundler launcher for $(cfg.entry_module) ===
    set -e
    DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
    ROOT="\$(dirname "\$DIR")"

    # Use the bundle's private depot first; fall back to user depot if unset
    export JULIA_DEPOT_PATH="\$ROOT/julia_depot:\${JULIA_DEPOT_PATH:-\$HOME/.julia}"
    export JULIA_LOAD_PATH="@:@stdlib"

    # Pick the bundled Julia if present, otherwise system Julia
    JULIA_BIN="\$ROOT/$julia_rel"
    if [ -z "$julia_rel" ] || [ ! -x "\$JULIA_BIN" ]; then
        JULIA_BIN="\$(command -v julia || true)"
        if [ -z "\$JULIA_BIN" ]; then
            echo "error: no Julia runtime available (bundle has none and 'julia' is not in PATH)" >&2
            exit 127
        fi
    fi

    # --pkgimages=existing + --compiled-modules=existing make Julia use the
    # bundled precompile cache *without* checking it against source files.
    # This is what lets us ship stripped/obfuscated .jl files: the real code
    # lives in julia_depot/compiled/ and is loaded directly.
    exec "\$JULIA_BIN" --project="\$ROOT/app" \\
        --startup-file=no \\
        --pkgimages=existing \\
        --compiled-modules=existing \\
        -e '
            using $(cfg.entry_module)
            exit($(cfg.entry_module).$(cfg.entry_function)())
        ' -- "\$@"
    """
    write(launcher, script)
    chmod(launcher, 0o755)
end

function _write_dockerfile(out::String, cfg::BundleConfig)
    df = """
    # === Auto-generated by JuliaCUDABundler ===
    # Build :  docker build -t $(lowercase(cfg.entry_module)) .
    # Run   :  docker run --rm --gpus all $(lowercase(cfg.entry_module)) [args]
    FROM $(cfg.dockerfile_base)

    # System libs Julia tends to pull in
    RUN apt-get update && apt-get install -y --no-install-recommends \\
            ca-certificates libatomic1 \\
        && rm -rf /var/lib/apt/lists/*

    COPY . /opt/app
    RUN chmod +x /opt/app/bin/$(cfg.entry_module)

    ENV PATH="/opt/app/bin:\$PATH"
    ENTRYPOINT ["/opt/app/bin/$(cfg.entry_module)"]
    """
    write(joinpath(out, "Dockerfile"), df)

    # .dockerignore to prevent accidental host-junk inclusion when building
    write(joinpath(out, ".dockerignore"), """
    # nothing to ignore — the bundle is the build context
    """)
end

function _write_metadata(out::String, cfg::BundleConfig)
    info = """
    JuliaCUDABundler bundle
    =======================
    Entry module    : $(cfg.entry_module)
    Entry function  : $(cfg.entry_function)
    Built with Julia: $(VERSION)
    Built on host   : $(Sys.MACHINE)
    Bundled Julia   : $(cfg.bundle_julia)
    Source stripped : $(cfg.obfuscate_source)
    Docker base     : $(cfg.dockerfile_base)
    """
    write(joinpath(out, "BUNDLE_INFO.txt"), info)
end

end # module
