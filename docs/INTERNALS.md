# INTERNALS — How `JuliaCUDABundler` actually works

This is the conversational, explain-it-like-I'm-curious version. Read
`TUTORIAL.md` first if you just want to use the thing.

---

## 1. The core problem in one paragraph

Julia is JIT-compiled. When you write `f(x) = x + 1`, nothing native exists
until you actually call `f(2.0)` and Julia LLVM-compiles a `Float64` version.
That's great for interactive work, terrible for shipping software, because
your user has to wait for compilation on their first run. Worse, if your
package depends on `CUDA.jl`, that "first run" includes loading hundreds of
megabytes of CUDA wrappers, downloading runtime artifacts, and JIT-ting
everything.

The "official" answer used to be **PackageCompiler.jl** (build a sysimage)
or **`juliac`** (build a real binary). Both work beautifully for pure CPU
code. Both **explode** when you point them at CUDA on a modern GPU, because
GPU kernel IR (NVPTX intrinsics like `llvm.nvvm.barrier.cluster.arrive`)
ends up in the host LLVM pipeline, which has no idea what to do with PTX.

So we need a third way: not a binary, not a sysimage, but **"a folder you
can hand someone that runs immediately"**. That's the bundle.

---

## 2. What "precompilation" actually produces in Julia 1.10+

When you do `Pkg.precompile()`, Julia writes two things per package, into
`$JULIA_DEPOT_PATH/compiled/v1.12/<PackageName>/`:

| File | What it is | Format |
|---|---|---|
| `<hash>.ji` | Serialized typed Julia IR + metadata + edges to all dependencies | Custom binary (Julia's own format) |
| `<hash>.so` (or `.dylib` / `.dll`) | **Native machine code** for as many type-specialized methods as Julia can prove are needed | ELF/Mach-O/PE shared library |

Yes — the `.so` is **a real, native, compiled-by-LLVM shared library**
sitting on your disk. Julia 1.9 introduced this as "package images"
(pkgimages). When you `using SomePackage` and the cache is fresh, Julia
`dlopen()`s the `.so` and binds its native methods straight into the
package's module table. **No JIT, no LLVM, no parsing.**

This is the trick. The bundler doesn't compile your app — it *triggers*
Julia's normal precompilation in a controlled location, then ships the
result.

> Think of it like Python's `__pycache__/` directory containing `.pyc`
> files, except the cached files contain real native code, not just
> bytecode.

---

## 3. The bundle's anatomy, mapped to *why*

```
my_bundle/
├── bin/MyApp
├── app/
├── julia/
├── julia_depot/
├── Dockerfile
└── BUNDLE_INFO.txt
```

| Dir | Role | Analogy |
|---|---|---|
| `bin/MyApp` | Bash launcher. The "executable". | `node_modules/.bin/foo` shim |
| `app/` | Your project: `Project.toml`, `Manifest.toml`, `src/`. The Manifest pins exact versions. | A locked Python venv |
| `julia/` | The Julia runtime itself (`bin/julia`, `lib/libjulia.so`, stdlib `.ji`s). | Bundling Python interpreter into a PyInstaller exe |
| `julia_depot/` | The precompile cache (`.ji` + `.so`) for **every dependency** including stdlib extensions. This is **the actual code that will execute.** | A frozen `__pycache__/` of every imported module |
| `Dockerfile` | Stage-zero container recipe. | n/a |

The launcher does this (paraphrased):

```bash
export JULIA_DEPOT_PATH="$BUNDLE/julia_depot:$HOME/.julia"
export JULIA_LOAD_PATH="@:@stdlib"
exec "$BUNDLE/julia/bin/julia" --project="$BUNDLE/app" \
     -e 'using MyApp; exit(MyApp.julia_main())' -- "$@"
```

The `JULIA_DEPOT_PATH` line is the magic. Julia searches depots **left to
right** for cached files. The bundle's depot wins. Every `using Foo` finds
`julia_depot/compiled/.../Foo.so` immediately, `dlopen`s it, and you're
running native code in milliseconds.

---

## 4. Why this works for CUDA when nothing else does

The AOT compilers fail at **build time** because they try to merge GPU IR
into a single host-targeted LLVM module. The bundle never does that. At
build time it just runs `Pkg.precompile()` — exactly the same precompilation
your normal Julia development uses every day, which works fine for CUDA.

At **run time**, when your code does `CUDA.@cuda mykernel(x)`, that kernel
is JIT-compiled to PTX (GPU code) by `GPUCompiler.jl`, then handed to the
NVIDIA driver to JIT to SASS for your specific GPU. This part is *supposed*
to happen at runtime, and it always has. We are not trying to AOT GPU
kernels. We are just shipping the **CPU side** in pre-compiled form, which
is precisely what `.so` package images are.

Trade-off: the first call to a `@cuda` kernel does pay a small JIT cost
(typically tens to hundreds of ms). For most workloads this is invisible
amortized over training/inference. If you need it gone, that's a separate
problem (kernel caching with `CUDA.set_runtime_version!` etc.) and is
outside the bundler's scope.

---

## 5. "Is the source actually hidden?"

Honest answer: **partially, and Docker is doing most of the work.**

What's in the bundle:

| Where the logic exists | Form | Human-readable? |
|---|---|---|
| `app/src/MyApp.jl` | Plain Julia source | **Yes** |
| `julia_depot/compiled/.../MyApp.ji` | Serialized typed IR (Julia's binary format) | No, but tools exist to dump it |
| `julia_depot/compiled/.../MyApp.so` | Native machine code | No (you can disassemble it like any `.so`) |

When the launcher runs, the `.so` is what executes. The `.jl` is **read by
Julia's loader for staleness checking** but its function bodies are not
re-compiled. So you could argue the source is "vestigial" — but it's still
sitting there as plain text.

### Why we don't strip the `.jl` files by default

I tried. Julia 1.12's loader validates the cache against the source on
*every* `using`. The check uses CRC32c hashes of source content and
included-file lists. The flags `--compiled-modules=existing` and
`--pkgimages=existing` change *what* Julia is willing to load, but they
**don't** disable the staleness check. So if you blank out a `.jl` after
precompiling, the next `using MyApp` sees the hash mismatch, decides the
cache is stale, and either re-precompiles (giving you an empty module) or
errors out.

Hard-bypassing this would require patching the binary `.ji` header
(rewriting the recorded source-hash table), which is brittle — every Julia
point release can change the format. The `obfuscate_source = true` flag is
left in as an experimental hook for people who want to try; the default is
**off**.

### Where opacity actually comes from: Docker

Once you `docker build`, the `app/`, `julia/`, and `julia_depot/`
directories live as **OverlayFS layers inside the image**. From the
recipient's perspective:

- They run `docker run --gpus all myapp` and see only stdout/stderr.
- They cannot trivially `cat /opt/app/src/MyApp.jl` — they would have to
  start the container, exec into it, `apt install vim`, and dig.
- A determined attacker can `docker save | tar xv` and pull every layer's
  contents, including your `.jl`. There is no defense against that. **No
  Julia distribution method protects against it**, including PackageCompiler
  sysimages (sysimages can be partially reverse-engineered with `methods()`
  introspection).

The honest summary: **bundling does not protect source. Containerization
makes casual inspection annoying. If your code is a trade secret, run it as
a server and ship API access, not a container.**

---

## 6. Why Julia, why now: pkgimages changed everything

Before Julia 1.9 (May 2023), `.ji` files held only typed IR — Julia still
had to feed that IR through LLVM at load time, which was *slow* (a `using
DifferentialEquations` could take 30+ seconds). PackageCompiler.jl
sysimages existed precisely to avoid that.

Julia 1.9 added **package images** (`.so` files alongside `.ji`). Now
loading a fully-precompiled package costs roughly the same as `dlopen` —
microseconds to single-digit milliseconds. Suddenly the question "what's
the difference between a sysimage and a directory of pkgimages?" became:
**not much, except the sysimage is one file**.

This bundler is built on that observation. We're not inventing a packaging
format — we're observing that Julia 1.9+'s native-by-default precompilation
produces something already shippable, if you just **freeze a private
depot** and **bring along the runtime**.

---

## 7. Software-engineering shape of the codebase

```
JuliaCUDABundler/
├── Project.toml          # deps: just Pkg + SHA (and Test for runtests)
├── src/
│   └── JuliaCUDABundler.jl   # ~200 LoC, six private helpers + one public function
├── test/runtests.jl      # bundles a TinyApp, executes it, checks output
├── examples/
│   ├── CudaDemo/         # vector add on GPU
│   └── FluxDemo/         # MLP trained on GPU
└── docs/
    ├── TUTORIAL.md       # workflow + Docker
    └── INTERNALS.md      # this file
```

Design decisions worth naming:

1. **Single public function (`bundle_app`).** Easy to script, easy to test,
   easy to call from CI.
2. **`BundleConfig` is a `Base.@kwdef struct`.** All the knobs live in one
   place; the function signature never grows. This is the "options struct"
   pattern from Go/Rust idioms.
3. **The bundler shells out to a fresh `julia` subprocess for the precompile
   step.** This is essential — you cannot mutate the running Julia's depot
   from inside it without polluting your dev environment.
4. **`JULIA_DEPOT_PATH` and `JULIA_LOAD_PATH` are the only state we set.**
   No environment variables persist after `bundle_app` returns. The bundle
   itself sets them only in its launcher, scoped to the bundle.
5. **The Dockerfile is generated, not templated.** Generated content is
   smaller and easier to inspect than a templating dependency.
6. **No global state, no caches in the bundler module itself.** A second
   call to `bundle_app` is idempotent (the output dir is wiped first).

---

## 8. Limits and what's on the horizon

What the bundler can't fix:

- **Architecture lock-in.** Native `.so` files are arch-specific. Bundle on
  `aarch64`, deploy on `aarch64`. Build twice for `x86_64`.
- **GPU compute capability lock-in (partial).** CUDA.jl precompilation
  records device IR specialized for the build host's GPU. On a different
  GPU, the first kernel call re-JITs. Usually fine; can be a startup hitch.
- **Driver mismatch.** The CUDA *runtime* is in the bundle; the *driver* is
  not (and shouldn't be — it's kernel-mode). Target driver must be ≥ what
  your CUDA runtime requires.
- **Bundle size.** ~3 GB with CUDA + Flux. Unavoidable while we ship the
  cache; the bytes are the point.

What might change soon:

- `GPUCompiler.jl` is actively being refactored to mark device IR as
  opaque to the host LLVM pipeline. When that lands, `juliac` and
  `PackageCompiler.jl` will start working with CUDA, and the bundler
  becomes a fallback rather than the only option.
- Julia 1.13+ may expose first-class APIs for "relocatable depots", which
  would let the bundler skip the manual `JULIA_DEPOT_PATH` dance.
- True relocatable single-file binaries (think `pyinstaller --onefile`)
  for Julia + CUDA: not on the roadmap I'm aware of, and architecturally
  hard. Probably not soon.

---

## 9. TL;DR

You're shipping three things stapled together:

1. **A Julia interpreter.** (`julia/`)
2. **A pre-warmed cache of native code for every dependency you use.** (`julia_depot/`)
3. **A two-line bash script that points #1 at #2 and runs your `julia_main`.** (`bin/MyApp`)

That's it. No new compiler, no new format, no clever IR rewriting — just an
honest acknowledgment that Julia 1.9+'s package images are *already* a
shippable artifact, and we just have to box them up.
