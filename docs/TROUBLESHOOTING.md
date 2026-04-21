# TROUBLESHOOTING — Compatibility Issues and Common Failures

This document covers every compatibility issue you're likely to encounter when
building and deploying a `JuliaCUDABundler` bundle. Read this before opening
a bug report.

---

## 1. Architecture mismatch

### Symptom
```
docker: exec format error
```
or
```
cannot execute binary file: Exec format error
```

### Cause
The `.so` package images inside the bundle are **native machine code** — they
are compiled for a specific CPU architecture (`x86-64` or `aarch64`). A bundle
built on one architecture cannot run on another.

### Fix
Build a separate bundle **on each architecture you want to support**:

```bash
# On x86-64 machine
julia bundle_app(BundleConfig(...))
docker build -t myapp:latest-amd64 .
docker push myapp:latest-amd64

# On aarch64 machine (Jetson, Grace, Apple Silicon Linux VM, etc.)
julia bundle_app(BundleConfig(...))
docker build -t myapp:latest-arm64 .
docker push myapp:latest-arm64
```

To let `docker pull myapp:latest` auto-select the right image per host:
```bash
docker buildx imagetools create \
  -t myapp:latest \
  myapp:latest-amd64 \
  myapp:latest-arm64
```

---

## 2. Julia version mismatch

### Symptom
```
ERROR: LoadError: Cache file ... was created with a different version of Julia.
```
or the launcher silently falls back to re-precompiling from the `.jl` source
(catastrophic if you used `redact_source=true` — the module appears empty).

### Cause
The `.ji` cache format changes between Julia **minor versions** (1.11 → 1.12,
1.12 → 1.13). The bundle's depot was built with one Julia version; the deploy
host has a different one.

Patch versions are safe: Julia 1.12.0 through 1.12.x share the same `.ji`
layout.

### Fix — Docker (recommended)
Pin the exact Julia version in your `Dockerfile`:
```dockerfile
FROM julia:1.12.2   # ← exact version, never "latest"
COPY . /bundle
ENTRYPOINT ["/bundle/bin/MyApp"]
```

### Fix — bare metal
Ensure the deploy host runs the **same Julia minor version** as the build host.
Check:
```bash
julia --version        # on build host
julia --version        # on deploy host
# Both should report 1.12.x
```

### Special case: `redact_source=true`
If you used `redact_source=true`, a Julia version mismatch is particularly
bad. The `.ji` is signed against the stub `.jl` files, but if Julia rejects
the `.ji` (due to version mismatch), it falls back to compiling the stubs —
producing an empty module with no `julia_main`. **Always use Docker** when
deploying with `redact_source=true`.

---

## 3. `redact_source` on an unsupported Julia version

### Symptom
```
ERROR: JiPatcher: unsupported Julia version 1.13.0 (known: [1.10, 1.11, 1.12])
```

### Cause
`JiPatcher` re-implements a slice of Julia's internal `.ji` binary format.
That format can change between minor versions. The bundler refuses to silently
corrupt `.ji` files on an untested version.

### Fix — updating support for a new Julia version
This is a deliberate design decision: the bundler is easy to update, but
requires a human to verify the layout hasn't changed. See
[`INTERNALS.md` §5(b)](INTERNALS.md#b-patch-ji-cache-header-to-drop-source-dependence--redact_sourcetrue)
for the step-by-step procedure. In summary:

1. Open `base/loading.jl` in the new Julia version.
2. Find `_parse_cache_header` and `read_module_list`.
3. Diff against the reference in the top comment of `src/JiPatcher.jl`.
4. Update `_scan_include_offsets` if the layout changed.
5. Append `v"1.13"` (or whichever version) to `SUPPORTED_VERSIONS`.
6. Run `julia --project=. test/runtests.jl` — the `redact_source` testset
   will catch layout bugs immediately.

---

## 4. GPU compute capability mismatch

### Symptom
The bundle runs, but **first GPU kernel call is slow** (~50–500 ms). Subsequent
calls are instant.

### Cause
Not actually an error — this is expected CUDA behavior. When you precompile on
a **V100 (CC 7.0)** and deploy to an **A100 (CC 8.0)**, the CUDA driver JITs
the kernel for the new compute capability on first use, then caches it. This
is true of *all* CUDA code, not just Julia.

### Fix
If startup latency matters, **precompile on the oldest GPU you plan to
support**. Kernels compiled for older CC run fine on newer GPUs without
re-JITting. The reverse is not true.

```
CC 7.0 → deploys to CC 7.0, 8.0, 9.0  ✅ no re-JIT on all targets
CC 8.0 → deploys to CC 7.0             ⚠️ re-JIT on first call
CC 8.0 → deploys to CC 8.0, 9.0       ✅ no re-JIT (same or newer)
```

---

## 5. CUDA driver too old on deploy host

### Symptom
```
CUDA error: no kernel image is available for execution on the device (code 209, ERROR_NO_BINARY_FOR_GPU)
```
or
```
CUDA driver too old (need >= 12.x, got 11.x)
```

### Cause
The CUDA *runtime* libraries are baked into the bundle (or Docker image), but
the CUDA *driver* is on the host. The driver must be at or above the version
your CUDA runtime requires.

Check the minimum driver version for your CUDA runtime:
[https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/](https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/)

Check the runtime version used:
```julia
using CUDA; CUDA.runtime_version()
```

### Fix
Upgrade the host NVIDIA driver, or rebuild the bundle against an older CUDA
runtime:
```julia
# In your Dockerfile base:
FROM nvcr.io/nvidia/cuda:11.8.0-runtime-ubuntu22.04
```

---

## 6. No CUDA / no GPU on the deploy host

### Symptom
```
CUDA.jl not functional: no CUDA-capable device found
```
or the container crashes immediately on first `@cuda` call.

### Cause
The bundle was built with CUDA code and deployed to a machine with no NVIDIA
GPU, or without passing the GPU device to Docker.

### Fix — pass GPU to Docker
```bash
docker run --gpus all myapp:latest
# or specific GPU:
docker run --gpus '"device=0"' myapp:latest
```

### Fix — check GPU is visible inside container
```bash
docker run --gpus all --rm nvidia/cuda:12.0-base nvidia-smi
```
If this fails, `nvidia-container-toolkit` is not installed on the host.
Install it:
```bash
# Ubuntu
sudo apt install -y nvidia-container-toolkit
sudo systemctl restart docker
```

---

## 7. Bundle runs but outputs nothing / exits immediately

### Symptom
The launcher runs without error but produces no output and exits with code 0
or 1.

### Likely causes

**A) `julia_main` is not defined or not exported**
Your entry module must define:
```julia
module MyApp
function julia_main()::Cint
    # your logic here
    return 0
end
end
```
The launcher calls `using MyApp; exit(MyApp.julia_main())`. If `julia_main`
is missing, you get `UndefVarError: julia_main not defined`.

**B) `redact_source=true` + Julia version mismatch (see §2)**
The module loads as an empty stub. `julia_main` simply doesn't exist in it.

**C) Precompile loaded the wrong version of the app**
If you ran `bundle_app` twice to the same output directory, wipe it first —
`bundle_app` clears the directory on start, but leftover processes or locked
files can interfere. Check:
```bash
ls my_bundle/julia_depot/compiled/v1.12/MyApp/
# Should contain exactly one .ji and one .so
```

---

## 8. Bundle runs but crashes on `@cuda` / GPU code

### Symptom
Works in development Julia session but crashes in the bundle.

### Cause — CUDA artifacts not fully precompiled
The bundler calls `Pkg.precompile()`, which compiles the host (CPU) side. GPU
kernels themselves are JIT-compiled at runtime by `GPUCompiler.jl`. If the
CUDA toolkit artifacts weren't downloaded during precompile, first-run JIT
may fail.

### Fix
Before bundling, trigger a **full CUDA precompile** in the same environment:
```julia
using CUDA
CUDA.precompile_runtime()  # downloads CUDA artifacts for your GPU
```
Then run `bundle_app`. The artifacts will be captured in `julia_depot/`.

---

## 9. Bundle is too large / Docker image too large

### Typical sizes
| Config | Image size |
|---|---|
| Julia only | ~500 MB |
| Julia + CUDA runtime | ~2.5 GB |
| Julia + CUDA + Flux | ~3–4 GB |

### Fix — strip unused dependencies
Remove packages from `Project.toml` that are only used at development time
(benchmarking tools, plotting, etc.). Every package in your manifest gets
precompiled and bundled.

### Fix — use a slim CUDA base image
```julia
BundleConfig(...; dockerfile_base = "nvcr.io/nvidia/cuda:12.0.0-base-ubuntu22.04")
```
`base` variants are ~200 MB vs ~3 GB for `devel`.

### Fix — don't bundle Julia
If the deploy environment guarantees Julia is available:
```julia
BundleConfig(...; bundle_julia = false)
```
Saves ~500 MB. The launcher then calls `julia` from `PATH`.

---

## 10. Bundle works locally but fails in CI / in Docker build

### Symptom
`bundle_app` hangs or fails during the precompile step inside a Docker build.

### Cause
The precompile step spawns a **subprocess** (`julia` process with a modified
`JULIA_DEPOT_PATH`). Inside Docker builds, there's no TTY and resource limits
may apply.

### Fix
Use `RUN` (not `CMD`) and ensure the container has enough memory for Julia
compilation (~2–4 GB for a CUDA bundle):
```dockerfile
# In your build container
RUN julia --project=/app -e 'using JuliaCUDABundler; bundle_app(BundleConfig(...))'
```

Also check Docker BuildKit memory limits:
```bash
docker buildx build --memory=8g ...
```

---

## 11. Introspection still works after `redact_source`

### Symptom / question
"I used `redact_source=true` but someone can still run:
```julia
using MyApp; methods(MyApp.f)
```
and see my function signatures."

### Explanation
This is expected — `redact_source=true` hides the **text** of your `.jl`
files. It does not prevent Julia's runtime introspection APIs from inspecting
the **compiled code** in the `.so`.

Anyone with the bundle can:
- See method signatures via `methods(MyApp.f)`
- Recover Julia-level typed IR via `Base.code_typed(MyApp.f, (Float64,))`
- Disassemble native code via `Base.code_native(MyApp.f, (Float64,))`

This is true of **any** compiled Julia artifact, including sysimages.

If this level of introspection is unacceptable, **do not ship the binary**.
Host your code as a service instead (see `INTERNALS.md` §5(c)).

---

## Quick reference table

| Problem | Most likely cause | Fix |
|---|---|---|
| `exec format error` | Wrong CPU architecture | Rebuild on target arch |
| `Cache file ... wrong version` | Julia minor version mismatch | Pin Julia in Dockerfile |
| `unsupported Julia version` | `JiPatcher` doesn't know new Julia | Update `src/JiPatcher.jl` |
| First GPU call slow | Compute capability mismatch | Build on oldest target GPU |
| `no kernel image for device` | CUDA driver too old | Upgrade host driver |
| `no CUDA-capable device` | No GPU passed to Docker | Add `--gpus all` |
| Bundle exits immediately | Missing `julia_main` or empty module | Check `redact_source` + Julia version |
| Bundle too large | All deps precompiled | Trim `Project.toml`; use slim CUDA base |
| Introspection still works | Expected behavior | Use service architecture if unacceptable |
