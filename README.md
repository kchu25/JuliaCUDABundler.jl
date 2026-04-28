# JuliaCUDABundler

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://kchu25.github.io/JuliaCUDABundler.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://kchu25.github.io/JuliaCUDABundler.jl/dev/)
[![Build Status](https://github.com/kchu25/JuliaCUDABundler.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/kchu25/JuliaCUDABundler.jl/actions/workflows/CI.yml?query=branch%3Amain)

> Ship a Julia + CUDA app as a folder you run, or a Docker image you `docker run`. No `juliac`, no `PackageCompiler.jl`, no LLVM crashes on Hopper / Blackwell GPUs.

## Install

```julia
using Pkg; Pkg.add(url="https://github.com/kchu25/JuliaCUDABundler.jl")
```

## Bundle in 3 lines

```julia
using JuliaCUDABundler
bundle_app(BundleConfig(
    project_dir  = "/abs/path/to/MyApp",   # your Julia package
    output_dir   = "/abs/path/to/bundle",  # where the bundle is written
    entry_module = "MyApp",                # the package's name
))
```

Your package needs **one function**, called `julia_main`:

```julia
module MyApp
function julia_main()::Cint
    # your code; read CLI args from ARGS
    return 0
end
end
```

## Run it

```bash
./bundle/bin/MyApp arg1 arg2
```

## Make a Docker image (the "binary")

`bundle_app` already wrote a `Dockerfile` for you. Just:

```bash
cd bundle
docker build -t myapp .
docker run --rm --gpus all myapp arg1 arg2
```

The image carries your code, the Julia runtime, and CUDA artifacts — runs anywhere with Docker + NVIDIA drivers.

## Working examples

- [`examples/CudaDemo`](examples/CudaDemo) — minimal CUDA vector-add
- [`examples/FluxDemo`](examples/FluxDemo) — Flux MLP training on GPU

Try one end-to-end:

```julia
using JuliaCUDABundler
bundle_app(BundleConfig(
    project_dir  = joinpath(pkgdir(JuliaCUDABundler), "examples", "CudaDemo"),
    output_dir   = "/tmp/cuda_demo_bundle",
    entry_module = "CudaDemo",
))
```

## Bundling a "glue" app (combining several local packages)

If your app depends on packages that aren't in the General registry, point at them with `[sources]` in your `Project.toml`:

```toml
name = "MyGlueApp"
uuid = "..."
version = "0.1.0"

[deps]
BanzhafInference = "1dcd8bad-b4e2-4929-895b-5ffffc074544"
EpicHyperSketch  = "c73a71ba-f77a-4450-b81e-a1166e41307d"

[sources]
BanzhafInference = { path = "/abs/path/to/BanzhafInference" }
EpicHyperSketch  = { path = "/abs/path/to/EpicHyperSketch" }
```

`bundle_app` precompiles every dep into the bundle's private depot, so an N-package glue app still ships as a single folder.

**Chains (`glue → inference → deep`) work too** — each package declares only its own immediate path-deps in its own `[sources]`; Pkg follows the chain. See [`detailed_README.md` §4.5](detailed_README.md#45-chained-path-deps-glue--inference--).

## Status

- ✅ Pure CUDA.jl apps (verified on NVIDIA Grace Hopper / GB10, aarch64 Linux)
- ✅ Flux.jl GPU training (verified end-to-end)
- ✅ Docker image generation (auto-`Dockerfile`, NVIDIA CUDA base)
- ✅ Multi-file projects, local path-deps, source redaction
- ⚠️ Bundles are arch- and Julia-version-specific — build on the deploy target's OS/CPU

## Need more?

- **[`detailed_README.md`](detailed_README.md)** — every `BundleConfig` option, how the bundle works inside, glue-app walkthrough, source-removal modes, gotchas.
- Deeper dives: [`docs/TUTORIAL.md`](docs/TUTORIAL.md) · [`docs/INTERNALS.md`](docs/INTERNALS.md) · [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)
