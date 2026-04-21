# TUTORIAL — Bundling and Dockerizing Julia + CUDA / Flux Apps

This is the **complete workflow** for taking a Julia project that uses
`CUDA.jl` and / or `Flux.jl` and turning it into something you can hand to
another machine — either as a self-contained directory or as a Docker image.

> **Why this exists.** Julia's "real" AOT compilers (`juliac`, `PackageCompiler.jl`)
> currently **cannot compile CUDA code** on modern NVIDIA hardware (Hopper /
> Blackwell). The CUDA kernels' NVPTX intrinsics leak into the host LLVM
> backend and crash compilation. `JuliaCUDABundler` sidesteps the problem by
> **shipping the precompile cache** instead of producing a single binary.

---

## 0. Prerequisites

| You need on the build machine                                 | Why                              |
|---------------------------------------------------------------|----------------------------------|
| Julia ≥ 1.10 (1.12.x recommended, package images shine here)  | Builds the cache                 |
| An NVIDIA GPU + driver compatible with your CUDA.jl version   | Triggers GPU code precompilation |
| Docker (optional)                                             | Building the deployable image    |
| `nvidia-container-toolkit` (optional, for `docker run --gpus`)| GPU passthrough                  |

| You need on the **target** machine | Why |
|------------------------------------|------|
| Same OS / CPU architecture as build host (e.g. `aarch64-linux-gnu`) | `.so` package images are arch-specific |
| NVIDIA driver compatible with the CUDA runtime baked into the bundle | Driver is *not* shipped |
| Either Docker (+ `--gpus all`), **or** the bundle's launcher script | How the app is invoked |

The target does **not** need: Julia installed, internet access, `Pkg.instantiate`,
or any first-run precompilation wait.

---

## 1. Install the bundler

```bash
git clone <this repo>            # or use it locally
cd JuliaCUDABundler
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

Verify:
```bash
julia --project=. -e 'using Pkg; Pkg.test()'
# → Test Summary: JuliaCUDABundler |   10     10     ...
```

---

## 2. Structure your application

Your app must be a normal Julia package with a top-level entry function that
returns a `Cint`:

```
MyApp/
├── Project.toml
├── Manifest.toml             # optional but reproducible
└── src/
    └── MyApp.jl
```

`MyApp.jl`:

```julia
module MyApp
using CUDA, Flux

function julia_main()::Cint
    # ARGS holds the command-line arguments
    n = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 1024
    println("device: ", CUDA.functional() ? CUDA.name(CUDA.device()) : "CPU")
    a = CUDA.rand(Float32, n)
    println("sum = ", sum(a))
    return 0
end

end
```

Two ready-made examples are in `examples/`:
- `examples/CudaDemo`  — pure CUDA vector add
- `examples/FluxDemo`  — small MLP trained on GPU

---

## 3. Build the bundle

The whole API is one function and one struct:

```julia
using JuliaCUDABundler

bundle_app(BundleConfig(
    project_dir  = "/abs/path/to/MyApp",
    output_dir   = "/abs/path/to/my_bundle",
    entry_module = "MyApp",
    # all optional:
    entry_function   = "julia_main",
    bundle_julia     = true,        # copy the running Julia runtime in
    obfuscate_source = false,       # see INTERNALS.md (Docker is the real opacity)
    dockerfile_base  = "nvidia/cuda:13.0.0-runtime-ubuntu24.04",
))
```

Run it:

```bash
julia --project=/path/to/JuliaCUDABundler -e '
using JuliaCUDABundler
bundle_app(BundleConfig(
    project_dir  = "/home/me/MyApp",
    output_dir   = "/home/me/my_bundle",
    entry_module = "MyApp",
))
'
```

What gets produced:

```
my_bundle/
├── bin/MyApp           ← bash launcher (chmod +x already)
├── app/                ← copy of MyApp/ (Project.toml + src/)
├── julia/              ← Julia runtime (if bundle_julia=true)  ~ 500 MB
├── julia_depot/        ← precompiled cache (.ji + .so)         ~ 2–3 GB w/ CUDA
├── Dockerfile          ← ready to `docker build`
├── .dockerignore
└── BUNDLE_INFO.txt     ← arch, Julia version, options
```

The build will take a while the first time — it's running `Pkg.precompile()`
for **every** dependency in your project, which is the entire point: the
target machine never has to do this.

### What just happened, step by step

The bundler does six things, all logged with `[N/6]`:

| Step | Action |
|---|---|
| 1/6 | Wipe & recreate `output_dir` |
| 2/6 | Copy `project_dir` (skipping `.git`, `.github`, `.vscode`, `build`, `deps`) into `app/` |
| 3/6 | Set `JULIA_DEPOT_PATH=output_dir/julia_depot`, run `Pkg.instantiate()` + `Pkg.precompile()` + `using EntryModule` so every package image is materialized |
| 4/6 | (Optional) Source obfuscation |
| 5/6 | (Optional) Copy Julia runtime (`bin/`, `lib/`, `share/`, `libexec/`, `include/`) |
| 6/6 | Write the launcher script, the Dockerfile, and `BUNDLE_INFO.txt` |

---

## 4. Run it locally

```bash
./my_bundle/bin/MyApp arg1 arg2
```

The launcher is a small bash script that:
1. Sets `JULIA_DEPOT_PATH=<bundle>/julia_depot:$HOME/.julia`
2. Picks `<bundle>/julia/bin/julia` if present, otherwise system Julia
3. Runs `julia --project=<bundle>/app -e 'using MyApp; exit(MyApp.julia_main())' -- "$@"`

First run is essentially free — no precompilation, the cache is already there.

---

## 5. Dockerize for distribution

The bundler writes a `Dockerfile` that does the right thing.

### 5a. Build the image

```bash
cd my_bundle
docker build -t myapp:latest .
```

This produces a `~3 GB` image (CUDA runtime + bundle). For comparison:
- A `PackageCompiler.jl` sysimage with CUDA: would be `~200 MB` *if it built* — but it doesn't.
- Plain `julia + Pkg.add(CUDA)`: also ~3 GB, but the user pays the precompile cost on every container start.

### 5b. Run the image

GPU passthrough requires `nvidia-container-toolkit` on the host:

```bash
docker run --rm --gpus all myapp:latest 1000000
# device: NVIDIA GB10
# sum = 1000038.5
```

CPU-only fallback:
```bash
docker run --rm myapp:latest 1000     # works if your code has a CPU path
```

### 5c. Distribute the image

Two common ways:

**A. Push to a registry** (recommended):
```bash
docker tag myapp:latest your-registry/myapp:v1.0
docker push your-registry/myapp:v1.0

# on target:
docker pull your-registry/myapp:v1.0
docker run --rm --gpus all your-registry/myapp:v1.0
```

**B. Save as a tarball** (air-gapped systems):
```bash
docker save myapp:latest | gzip > myapp-v1.0.tar.gz   # ~1.5 GB compressed
scp myapp-v1.0.tar.gz target:/tmp/

# on target:
gunzip < /tmp/myapp-v1.0.tar.gz | docker load
docker run --rm --gpus all myapp:latest
```

---

## 6. Worked example: bundle the Flux demo

This is a small MLP that learns `y = sin(x1) + cos(x2)` on the GPU.

```bash
cd JuliaCUDABundler

# (one-time) instantiate the example
julia --project=examples/FluxDemo -e 'using Pkg; Pkg.add("cuDNN"); Pkg.instantiate()'

# bundle
julia --project=. -e '
using JuliaCUDABundler
bundle_app(BundleConfig(
    project_dir  = abspath("examples/FluxDemo"),
    output_dir   = abspath("flux_bundle"),
    entry_module = "FluxDemo",
    bundle_julia = false,
))
'

# run
./flux_bundle/bin/FluxDemo 50
# Device         : GPU (NVIDIA GB10)
# Training       : ep=1 loss=0.7302 ... ep=50 loss=0.05
# Final MSE      : 0.05
# Predictions    : Float32[1.41, -0.18, 1.95]
# Ground truth   : Float32[1.48, -0.08, 1.95]

# dockerize
cd flux_bundle
docker build -t fluxdemo .
docker run --rm --gpus all fluxdemo 100
```

---

## 7. Common knobs and tweaks

### Smaller bundles
- Set `bundle_julia = false` and require the user to install Julia. Saves ~500 MB.
- Trim your `Project.toml` — every dep gets precompiled.
- Use a `slim` CUDA base image:
  ```julia
  dockerfile_base = "nvidia/cuda:13.0.0-base-ubuntu24.04"
  ```

### Strip comments / docstrings
```julia
BundleConfig(...; strip_comments = true)
```
Runs *before* precompile so cache hashes still align. Removes `# ...` and
`#= ... =#`. Strings containing `#` are preserved (uses Julia's tokenizer).
Does **not** remove docstrings or executable code — see `INTERNALS.md` §5
for what this does and does not protect against.

### Remove all `.jl` source from the bundle
```julia
BundleConfig(...; redact_source = true)
```
Precompiles normally, then **rewrites every `.jl` in `app/src/` to a stub**
(your entry module becomes literally `module MyApp\nend`) and re-signs the
`.ji` cache headers so Julia accepts the cache. The loader maps the `.so`
package image and runs your real native code — but on-disk inspection
shows no Julia source.

Supported Julia versions: **1.10, 1.11, 1.12**. The bundler refuses to run
on unsupported versions. See `INTERNALS.md` §5(b) for the full caveats and
the per-version update procedure.

### Different CUDA version
Edit `dockerfile_base`. The CUDA *runtime* in the image must match the
runtime that `CUDA.jl` was precompiled against. Check with:
```julia
julia> using CUDA; CUDA.runtime_version()
v"13.0.0"
```

### Multiple GPUs / specific GPU at runtime
Standard Docker semantics:
```bash
docker run --rm --gpus '"device=0"' myapp        # GPU 0 only
docker run --rm --gpus 2 myapp                   # any 2 GPUs
```

### Custom entry function
```julia
BundleConfig(...; entry_function = "my_main")
```
Only requirement: zero-arg, returns `Cint`, reads `ARGS` for input.

---

## 8. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `Could not load entry module` during build | Your project has a runtime error during `using MyApp`. Run it manually with `julia --project=MyApp -e 'using MyApp'` to see the trace. |
| `LLVM ERROR: Cannot select: intrinsic %llvm.nvvm.barrier.cluster.arrive` | You tried to run `juliac` or `PackageCompiler.create_app` on CUDA code. This bundler exists *because* of that error. Use `bundle_app` instead. |
| `CUDA not functional` inside Docker | Missing `--gpus all`, or `nvidia-container-toolkit` not installed on host. |
| `failed process: ... ProcessExited(127)` | No Julia in the launcher's PATH. Either rebuild with `bundle_julia=true`, or install Julia on the target. |
| Bundle works on build host, fails on target with `Illegal instruction` | Built on a CPU with newer instructions than target. Set `JULIA_CPU_TARGET=generic` before the build. |
| `Downloading artifact: CUDA_Runtime ... ERROR: Data Error` | Transient network issue during `Pkg.precompile`. Re-run; artifacts are usually cached. |

---

## 9. Cheat sheet (copy-paste)

```bash
# build the bundler once
git clone … && cd JuliaCUDABundler && julia --project=. -e 'using Pkg; Pkg.instantiate()'

# bundle your app
julia --project=. -e 'using JuliaCUDABundler; bundle_app(BundleConfig(
    project_dir="/abs/MyApp", output_dir="/abs/MyApp_bundle", entry_module="MyApp"))'

# run locally
/abs/MyApp_bundle/bin/MyApp arg1 arg2

# dockerize
cd /abs/MyApp_bundle && docker build -t myapp .
docker run --rm --gpus all myapp arg1 arg2

# ship offline
docker save myapp | gzip > myapp.tar.gz   # → scp to target
docker load < myapp.tar.gz                # on target
```

For *why* any of this works the way it does, read **`INTERNALS.md`**.
