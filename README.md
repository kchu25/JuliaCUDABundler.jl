# JuliaCUDABundler

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://kchu25.github.io/JuliaCUDABundler.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://kchu25.github.io/JuliaCUDABundler.jl/dev/)
[![Build Status](https://github.com/kchu25/JuliaCUDABundler.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/kchu25/JuliaCUDABundler.jl/actions/workflows/CI.yml?query=branch%3Amain)

> **Ship Julia + CUDA / Flux apps as a self-contained directory or Docker image, without `juliac` or `PackageCompiler.jl`.**

Julia's AOT compilers (`juliac`, `PackageCompiler.jl`) currently **cannot
compile CUDA code** on modern NVIDIA hardware (Hopper, Blackwell). They
crash with `LLVM ERROR: Cannot select intrinsic %llvm.nvvm.barrier.cluster.*`.

`JuliaCUDABundler` sidesteps the problem by **shipping the precompile
cache** (Julia 1.9+ package images, `.so` native code) along with the Julia
runtime in a folder you can hand to anyone or wrap in Docker.

## Quick start

```julia
using Pkg; Pkg.add(url="https://github.com/kchu25/JuliaCUDABundler.jl")
using JuliaCUDABundler

bundle_app(BundleConfig(
    project_dir  = "/abs/path/to/MyApp",
    output_dir   = "/abs/path/to/my_bundle",
    entry_module = "MyApp",
))
```

```bash
./my_bundle/bin/MyApp arg1 arg2          # run locally
cd my_bundle && docker build -t myapp .  # ship as image
docker run --rm --gpus all myapp arg1
```

Your app must define `julia_main()::Cint` (reads `ARGS`, returns exit code).
See `examples/CudaDemo` and `examples/FluxDemo` for working setups.

## Documentation

- **[`docs/TUTORIAL.md`](docs/TUTORIAL.md)** — full workflow, every command
  explained, Docker process, troubleshooting.
- **[`docs/INTERNALS.md`](docs/INTERNALS.md)** — what's actually happening
  under the hood, why this works for CUDA when AOT doesn't, and an honest
  discussion of source opacity.

## Status

- ✅ Pure CUDA.jl apps (verified on NVIDIA Grace Hopper / GB10, aarch64 Linux)
- ✅ Flux.jl GPU training (verified end-to-end)
- ✅ Docker image generation
- ✅ `strip_comments=true` removes line/block comments before precompile
  (uses Julia's tokenizer; safe with strings)
- ⚠️ `obfuscate_source = true` is experimental — Docker layer separation is
  the recommended opacity story
- ⚠️ Bundles are arch-specific (build on the OS/CPU of the deployment target)

## Why not `juliac` / `PackageCompiler.jl`?

| Feature | `juliac` / `PackageCompiler` | `JuliaCUDABundler` |
|---|---|---|
| CUDA on Hopper/Blackwell | ❌ broken | ✅ works |
| Single binary | ✅ | ❌ folder + launcher |
| Bundle size | ~200 MB | ~3 GB (with CUDA + Flux) |
| Startup latency | ~50 ms | ~1–3 s (Julia init) |
| Source obfuscation | ✅ | Docker layers (see INTERNALS) |

Use `juliac` / `PackageCompiler.jl` for **pure CPU code**.
Use this for **anything that touches the GPU**.
