module JuliaCUDABundler

using Pkg
using Base.JuliaSyntax: tokenize, kind, untokenize, @K_str

include("JiPatcher.jl")
using .JiPatcher: patch_ji!, is_supported as ji_patcher_supported

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
- `strip_comments::Bool = false` — strip line/block comments and docstrings
  from `.jl` files **before** precompile. The cache hashes match the stripped
  source, so the bundle still loads cleanly. Removes the *intent* (comments,
  docstrings) but the executable code remains readable. Uses Julia's own
  tokenizer so strings/char-literals containing `#` are preserved.
- `redact_source::Bool = false` — **stronger source removal.** *After*
  precompilation, replace every `.jl` file in the bundled `app/src/` with a
  redacted stub (preserving only the top-level `module ... end` shell), and
  then patch each `.ji` cache file to record the new (stub) `(fsize, hash,
  mtime)` triple plus a recomputed trailing CRC32c. The result is a bundle
  whose `.jl` files contain no logic but still loads cleanly because the
  precompile cache validates against the stub. Requires `JiPatcher` to
  support the running Julia version (currently 1.10–1.12). See
  `INTERNALS.md` §5 for caveats.
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
    strip_comments::Bool = false
    redact_source::Bool = false
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

    if cfg.strip_comments
        @info "       Stripping comments / docstrings (pre-precompile so hashes align)"
        n = _strip_comments!(app_dir)
        @info "       Stripped comment trivia from $n .jl file(s)"
    end

    @info "[3/6] Precompiling into private depot (this can take a while)"
    _precompile_into_depot(app_dir, depot, cfg.entry_module)

    if cfg.obfuscate_source
        @info "[4/6] Obfuscating source files (cache will be loaded with --pkgimages=existing)"
        _obfuscate_source!(app_dir, cfg.entry_module)
    else
        @info "[4/6] Source obfuscation disabled — .jl files left intact"
    end

    if cfg.redact_source
        ji_patcher_supported() ||
            error("redact_source=true requires Julia $(JiPatcher.SUPPORTED_VERSIONS); " *
                  "running $VERSION. Disable redact_source or update JiPatcher.")
        @info "      Redacting .jl source and re-signing .ji caches"
        n_files, n_records = _redact_source!(app_dir, depot, cfg.entry_module)
        @info "      Redacted $n_files file(s); patched $n_records .ji record(s)"
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
Strip comments and docstrings from every `.jl` file in `<app_dir>/src/`.

Uses Julia's own tokenizer (`Base.JuliaSyntax`) so strings, char literals,
and other constructs containing `#` are preserved correctly.

Runs *before* precompile, so the cache's recorded source hashes match the
stripped files and the loader is happy at runtime.
"""
function _strip_comments!(app_dir::String)
    src_dir = joinpath(app_dir, "src")
    isdir(src_dir) || return 0

    n = 0
    for (root, _, files) in walkdir(src_dir), f in files
        endswith(f, ".jl") || continue
        path = joinpath(root, f)
        src  = read(path, String)
        try
            stripped = _strip_jl_string(src)
            if stripped != src
                write(path, stripped)
                n += 1
            end
        catch e
            @warn "Could not tokenize, leaving file untouched" path exception=e
        end
    end
    return n
end

"""Tokenize Julia source and re-emit without `Comment` trivia."""
function _strip_jl_string(src::AbstractString)
    io = IOBuffer()
    for tok in tokenize(src)
        kind(tok) == K"Comment" && continue
        write(io, untokenize(tok, src))
    end
    out = String(take!(io))
    # Collapse runs of blank lines left by removed comments
    out = replace(out, r"\n[ \t]*\n[ \t]*\n+" => "\n\n")
    return out
end

"""
Replace each `.jl` file in `<app_dir>/src/` with a redacted stub, then patch
every `.ji` cache file in `<depot>/compiled/` so it accepts the new file
content. Returns `(n_files_rewritten, n_ji_records_patched)`.

The top-level module file becomes:
    # Redacted by JuliaCUDABundler
    module <ModName>
    end
Other (included) files become a single comment line. Both keep the file
present (so the loader can stat them) and the module declaration intact (so
`using <ModName>` resolves), while removing all human-readable logic.

The actual code is loaded from the precompile cache (.ji + .so) under
`<depot>/compiled/`. We rewrite the include records in each .ji so that
`Base.any_includes_stale` is satisfied, then recompute the trailing
whole-file CRC32c.
"""
function _redact_source!(app_dir::String, depot::String, entry_module::String)
    src_dir = abspath(joinpath(app_dir, "src"))
    isdir(src_dir) || return (0, 0)

    # 1. Rewrite all .jl files in src_dir to redacted stubs
    n_files = 0
    for (root, _, files) in walkdir(src_dir), f in files
        endswith(f, ".jl") || continue
        path = joinpath(root, f)
        if path == joinpath(src_dir, "$entry_module.jl")
            stub = """
                   # Redacted by JuliaCUDABundler — implementation in precompile cache
                   module $entry_module
                   end
                   """
        else
            stub = "# Redacted by JuliaCUDABundler — implementation in precompile cache\n"
        end
        write(path, stub)
        n_files += 1
    end

    # 2. Walk the depot and patch every .ji that references files under src_dir
    n_records = 0
    compiled = joinpath(depot, "compiled")
    isdir(compiled) || return (n_files, 0)
    for (root, _, files) in walkdir(compiled), f in files
        endswith(f, ".ji") || continue
        ji = joinpath(root, f)
        try
            n_records += patch_ji!(ji, src_dir)
        catch e
            @warn "Skipping .ji that could not be patched" path=ji exception=e
        end
    end
    return (n_files, n_records)
end

"""
Replace the bodies of `.jl` files in `app_dir/src/` with comment-only stubs.

Julia's loader requires the module declaration to exist (the `module X ... end`
shell), but the actual function definitions can live in the precompile cache.
We rewrite each file as a hollow module so anyone reading the bundled source
sees no logic.

NOTE: Currently produces a non-runnable bundle on its own — Julia 1.12
re-validates the cache against source hashes on `using`, sees the stub doesn't
match, and tries to recompile (yielding an empty module). Useful only as a
post-processing step inside Docker images where the bundle is never re-loaded
without a corresponding regenerated cache.
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
