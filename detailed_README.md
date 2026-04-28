# JuliaCUDABundler — Detailed Reference

This is the longer companion to [`README.md`](README.md). It covers every `BundleConfig` option, how the bundle is laid out internally, the glue-app workflow, Docker, source-removal modes, and the gotchas you'll actually hit.

For the deepest dives, see also:

- [`docs/TUTORIAL.md`](docs/TUTORIAL.md) — full step-by-step
- [`docs/INTERNALS.md`](docs/INTERNALS.md) — `.ji` / `.so` cache theory
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — every common failure mode

---

## 1. Why this exists

Julia's stock AOT compilers (`juliac`, `PackageCompiler.jl`) currently **cannot compile CUDA-using code** on modern NVIDIA hardware (Hopper, Blackwell). They crash with errors like:

```
LLVM ERROR: Cannot select intrinsic %llvm.nvvm.barrier.cluster.*
```

Cause: GPU kernel IR (NVPTX) leaks into the host-side LLVM pipeline. AOT can't separate the two.

`JuliaCUDABundler` sidesteps the problem entirely. Instead of asking AOT to compile CUDA, it does what `using` already does — runs `Pkg.precompile()`, which produces native `.so` package images that *do* work for CUDA — and then ships those `.so` files alongside the Julia runtime in a self-contained folder. At runtime, GPU kernels are JITed by `GPUCompiler.jl` exactly as they would be in interactive Julia.

| | `juliac` / `PackageCompiler` | `JuliaCUDABundler` |
|---|---|---|
| CUDA on Hopper/Blackwell | ❌ broken | ✅ works |
| Single binary file | ✅ | ❌ folder + launcher |
| Bundle size | ~200 MB | ~3 GB (with CUDA + Flux) |
| Cold-start latency | ~50 ms | ~1–3 s (Julia init) |
| Source obfuscation | built-in | `redact_source=true` or Docker layers |

Use `juliac` / `PackageCompiler` for **pure CPU code**. Use this for **anything that touches the GPU**.

---

## 2. What gets bundled

After `bundle_app`, your `output_dir` looks like:

```
<output_dir>/
├── bin/<EntryModule>      ← bash launcher (the "executable")
├── app/                   ← Project.toml + Manifest.toml + src/
├── julia/                 ← Julia runtime (if bundle_julia=true)
├── julia_depot/           ← precompile cache (.ji + .so) — the real code
├── Dockerfile             ← ready to `docker build`
├── .dockerignore
└── BUNDLE_INFO.txt        ← metadata (Julia version, host arch, etc.)
```

The launcher is a small bash script. It sets `JULIA_DEPOT_PATH` to the bundled depot, picks the bundled (or system) Julia, and invokes:

```
julia --project=app --pkgimages=existing --compiled-modules=existing \
      -e 'using MyApp; exit(MyApp.julia_main())' -- "$@"
```

The two `--*=existing` flags tell Julia: **trust the cache, don't re-stat sources**. This is what lets the bundle run with stripped or stub `.jl` files.

---

## 3. `BundleConfig` — every field

```julia
BundleConfig(;
    project_dir,
    output_dir,
    entry_module,
    entry_function   = "julia_main",
    bundle_julia     = true,
    strip_comments   = false,
    redact_source    = false,
    obfuscate_source = false,
    juliaup_channel  = "",
    dockerfile_base  = "nvidia/cuda:13.0.0-runtime-ubuntu24.04",
)
```

### Required

| Field | Meaning |
|---|---|
| `project_dir` | Absolute path to the Julia project to bundle. |
| `output_dir` | Absolute path where the bundle is written. **Will be wiped clean first.** |
| `entry_module` | Package / module name. Must match all of: `name = ` in `Project.toml`, `module X ... end` in `src/X.jl`, and the name resolved by `using X`. Also the launcher binary's name (`bin/<entry_module>`). |

### Optional

| Field | Default | Meaning |
|---|---|---|
| `entry_function` | `"julia_main"` | Zero-arg function inside `entry_module` that returns `Cint`. The launcher calls `exit(MyApp.julia_main())`. |
| `bundle_julia` | `true` | Copy the running Julia runtime into the bundle. Set `false` if the target machine has its own Julia. |
| `strip_comments` | `false` | Tokenize each `.jl` file and remove comments / docstrings **before** precompile, so cache hashes match. Strings containing `#` are preserved. |
| `redact_source` | `false` | **Recommended source-removal.** *After* precompile, replace each `.jl` file with a stub and patch the `.ji` cache so it accepts the stubbed source (recomputes CRC32c). Real code runs from the `.so` package images. Requires Julia 1.10–1.12. |
| `obfuscate_source` | `false` | Legacy / Docker-only. Replaces `.jl` with stubs but doesn't patch `.ji`, so the bundle won't run as a standalone folder — only inside Docker where the `.so` is the loaded path. **Prefer `redact_source` for everything.** |
| `juliaup_channel` | `""` | Informational, recorded in `BUNDLE_INFO.txt`. |
| `dockerfile_base` | `"nvidia/cuda:13.0.0-runtime-ubuntu24.04"` | Base image for the auto-generated `Dockerfile`. Override if you need a different CUDA / OS. |

---

## 4. Glue-app workflow (combining local packages)

A common setup: a thin top-level "glue" package depending on several local packages that aren't on the General registry.

### 4.1 Lay out the directories

```
~/work/
├── BanzhafInference/      ← local package
├── EpicHyperSketch/       ← local package
├── EntroPlots/            ← local package
├── GlyphEctoplasm/        ← local package
└── MyGlueApp/             ← the glue you bundle
    ├── Project.toml
    └── src/
        └── MyGlueApp.jl
```

### 4.2 Wire deps via `[sources]`

`MyGlueApp/Project.toml`:

```toml
name = "MyGlueApp"
uuid = "your-uuid-here"
version = "0.1.0"

[deps]
BanzhafInference = "1dcd8bad-b4e2-4929-895b-5ffffc074544"
EpicHyperSketch  = "c73a71ba-f77a-4450-b81e-a1166e41307d"
EntroPlots       = "742586e2-2ccd-48a5-bc1c-31de6daa8fd7"
GlyphEctoplasm   = "8227acd8-3ec4-4c13-8000-5272694d2f9b"

[sources]
BanzhafInference = { path = "/home/you/work/BanzhafInference" }
EpicHyperSketch  = { path = "/home/you/work/EpicHyperSketch" }
EntroPlots       = { path = "/home/you/work/EntroPlots" }
GlyphEctoplasm   = { path = "/home/you/work/GlyphEctoplasm" }
```

### 4.3 Define the entry point

`MyGlueApp/src/MyGlueApp.jl`:

```julia
module MyGlueApp
using BanzhafInference, EpicHyperSketch, EntroPlots, GlyphEctoplasm

function julia_main()::Cint
    # parse ARGS, dispatch to the right pipeline, etc.
    return 0
end
end
```

### 4.4 Bundle

```julia
using JuliaCUDABundler
bundle_app(BundleConfig(
    project_dir  = "/home/you/work/MyGlueApp",
    output_dir   = "/home/you/deploy/glue_bundle",
    entry_module = "MyGlueApp",
))
```

`bundle_app` runs `Pkg.precompile()` over the entire dependency graph — every local package gets its own `.so` in the private depot. The output folder is fully self-contained and portable across machines of the same arch + Julia version.

### 4.5 Chained path-deps (`glue → inference → ...`)

Real glue setups are usually deeper than one level — e.g.

```
MyGlueApp  (path)
    └── InferencePkg  (path)
            └── DeepDep  (path)
                    └── ...registry packages...
```

**The rule (Julia 1.11+):** *each package declares only its own immediate path-deps* in its own `[sources]`. Pkg follows the chain transitively when resolving the manifest. So:

- `MyGlueApp/Project.toml` lists `InferencePkg` in `[sources]`.
- `InferencePkg/Project.toml` lists `DeepDep` in `[sources]`.
- `DeepDep/Project.toml` lists nothing (or whatever else *it* depends on by path).

**The mistake to avoid:** putting transitive deps in the top-level `[sources]`. Pkg will reject it with:

```
ERROR: Sources for `DeepDep` not listed in `deps` or `extras` section
       at "/path/MyGlueApp/Project.toml"
```

That's because `[sources]` entries must correspond to packages in that *same* project's `[deps]` or `[extras]`. So if `MyGlueApp` doesn't directly use `DeepDep`, it can't put `DeepDep` in its `[sources]` — and it doesn't need to, because Pkg will pick it up via `InferencePkg`'s `[sources]`.

This means a 4-level glue-app stack works the same way as a 1-level one — each package owns its immediate dependencies.

### 4.6 Verify

The test suite includes two stress tests for this:

- `glue app: project with local path-dep bundles correctly` — flat case (one level)
- `glue app: transitive path-deps (3-level chain)` — `Glue → InferencePkg → DeepDep`, each declaring only its immediate path-deps

Both verify all package images land in the bundle's private depot and that the chained call executes correctly through the launcher. Run `Pkg.test()` before bundling your real glue app to confirm the workflow is intact on your machine.

---

## 5. Docker workflow

`bundle_app` writes a `Dockerfile` in `output_dir` that's ready to build:

```bash
cd /path/to/bundle
docker build -t myapp .
docker run --rm --gpus all myapp arg1 arg2
```

The default base is `nvidia/cuda:13.0.0-runtime-ubuntu24.04`. To pin a different CUDA version or OS, pass `dockerfile_base`:

```julia
bundle_app(BundleConfig(
    ...,
    dockerfile_base = "nvidia/cuda:12.6.0-runtime-ubuntu22.04",
))
```

Tips:

- **Match the Docker base's GPU driver to the host.** The CUDA *runtime* is bundled; the *driver* must come from the host (via `--gpus all`).
- **Architecture matters.** A bundle built on x86-64 won't run in an aarch64 image, and vice versa. Use `docker buildx build --platform linux/arm64 ...` if cross-building.
- **Image size will be large** (~3 GB+ with CUDA+Flux). That's expected — the entire CUDA runtime + Julia runtime + native package images all ship together.

---

## 6. Source-removal modes

You have three options for what the bundled `.jl` files look like to anyone inspecting the folder. The actual executable code lives in the `.so` package images regardless — these only affect the `.jl` text on disk.

| Mode | What `.jl` looks like | Bundle still runs? | Use when |
|---|---|---|---|
| (default) | Original source | ✅ | You don't care who reads the source. |
| `strip_comments=true` | Code, no comments / docstrings | ✅ | You want intent / explanations gone but logic is fine. Run before precompile so hashes align. |
| `redact_source=true` | Single-line stub (top file keeps `module X end`) | ✅ | You want **no readable Julia logic** on disk. Patches `.ji` cache so loader is happy. **Recommended.** Julia 1.10 / 1.11 / 1.12 only. |
| `obfuscate_source=true` | Stub | ❌ as a folder, ✅ in Docker | Legacy. Prefer `redact_source`. |

`redact_source` is the strongest, fully working option. See [`docs/INTERNALS.md`](docs/INTERNALS.md) §5 for how cache re-signing works (it rewrites every include record's `(fsize, hash, mtime)` triple in each `.ji` and recomputes the trailing CRC32c).

---

## 7. Gotchas

### 7.1 Bundles are not portable across architectures

Native `.so` package images are CPU-arch-specific. A bundle built on x86-64 won't run on aarch64 (and vice versa). Build per target arch — `docker buildx` is the easiest way to cross-build.

### 7.2 Bundles pin to a specific Julia version

The `.ji` cache format changes between Julia minor versions. A bundle built with Julia 1.12 will reject a 1.11 runtime. The launcher uses the **bundled** Julia (`bundle_julia=true` by default) to avoid this — keep that on unless you really mean it.

If you set `bundle_julia=false`, ensure the deploy target has the **exact same Julia minor version**.

### 7.3 `redact_source` is version-windowed

`JiPatcher.SUPPORTED_VERSIONS` declares which Julia minor versions are known. Currently `1.10 / 1.11 / 1.12`. If you upgrade to a version whose `.ji` layout changes, follow the upgrade procedure in `src/JiPatcher.jl` (top-of-file comment) — diff Julia's `Base._parse_cache_header` against the version we know, add a new layout branch if needed.

### 7.4 CUDA artifacts must download into the *bundle's* depot

`Pkg.precompile()` alone doesn't trigger CUDA's lazy artifact download (libcuda stubs, PTX tools, cuDNN). `bundle_app` explicitly calls `CUDA.precompile_runtime()` *with `JULIA_DEPOT_PATH` pointed at the bundle depot*, so artifacts land in the bundle, not in `~/.julia/artifacts/`.

If you build on a machine without a GPU, you'll see a warning ("CUDA not functional during precompile"). The bundle may still work on a GPU machine if all artifacts were resolvable; if not, build on a GPU machine.

### 7.5 Local path-deps need absolute paths in `[sources]`

Relative paths in `[sources]` are resolved against the *bundled* `Project.toml`, which lives at `app/Project.toml` inside the bundle — so a relative path like `../MyDep` won't work after copy. Use absolute paths. (Once precompile completes, the path is no longer needed at runtime: code loads from the bundle's `.so`.)

### 7.6 Re-bundling wipes `output_dir`

`bundle_app` does `rm(output_dir; recursive=true, force=true)` first. If you point it at a directory that contains anything else, you'll lose it. Always use a dedicated output directory.

---

## 8. Tests as documentation

`test/runtests.jl` is small and worth reading as a tour:

| Testset | Demonstrates |
|---|---|
| `BundleConfig defaults` | Field defaults |
| `bundle_app builds and runs` | Minimal end-to-end happy path |
| `_strip_jl_string preserves semantics` | Tokenizer correctness with `#` in strings |
| `strip_comments produces a runnable bundle` | Comments gone but bundle still runs |
| `redact_source removes logic but keeps bundle runnable` | Cache re-signing works |
| `redact_source: multi-file project` | Multi-file `include()` chain redacted cleanly |
| `glue app: project with local path-dep bundles correctly` | One-level glue-app (flat) |
| `glue app: transitive path-deps (3-level chain)` | `Glue → InferencePkg → DeepDep` — `[sources]` followed transitively |
| `re-bundling to the same output dir is idempotent` | Wipe-and-rebuild is safe |

All tests run on CPU (no GPU required) and complete in a few minutes total.
