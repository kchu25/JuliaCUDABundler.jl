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

This is the question that should keep you up at night if you're shipping
proprietary code. Honest answer: **the bundle alone gives you no source
opacity beyond what shipping `Project.toml + src/` would**. Docker is what
makes inspection annoying. Below is the full picture.

### What's in the bundle, in plain terms

| Artifact | Where it lives | Human-readable? |
|---|---|---|
| Your Julia code | `app/src/*.jl` | **Yes** (plain text) |
| Typed IR per dependency | `julia_depot/compiled/.../<hash>.ji` | No, but tools exist to dump it |
| Native machine code per dependency | `julia_depot/compiled/.../<hash>.so` | No (disassemble like any `.so`) |

When the launcher runs, the `.so` is what executes. The `.jl` files are
**only consulted by Julia's loader for staleness checking** — their function
bodies are not re-parsed. The source is *vestigial at runtime*, but it's
still there as text.

### Is bundle-in-Docker any better than source-in-Docker?

For **opacity**, no — both ship the same `.jl` files inside OverlayFS layers.

For **operations**, very different:

| Property | source + Docker | **bundle + Docker** |
|---|---|---|
| First run wait | minutes (Pkg.precompile in container) | none |
| Internet during deploy | yes (Pkg.add) | none |
| Reproducible bytes | no (depends on registry state) | yes (frozen depot) |
| Image size | ~3 GB (deps download + compile) | ~3 GB (already-compiled deps) |

So the bundle's value over "source + Docker" is **operational**, not
secrecy-related. That's the truthful framing.

### Why we can't just delete the `.jl` files

I tried. Julia 1.12's loader validates the cache against the source on
*every* `using`. The check uses size + CRC32c hash of source content,
recorded in the `.ji` header at precompile time. Flags like
`--compiled-modules=existing` and `--pkgimages=existing` only relax *which*
caches Julia is willing to *use*; they **don't** disable the staleness
check. Blank out a `.jl` after precompiling and the next `using MyApp` sees
a hash mismatch, declares the cache stale, and either re-precompiles
(yielding an empty module) or errors out.

### What we *can* do, and the trade-offs

There are three real techniques on a spectrum of effort and reward:

#### (a) Strip comments before precompile  ← **`strip_comments=true`**

Modify `.jl` files **before** the precompile step, so the recorded hashes
match the stripped content. Implemented in this package using
`Base.JuliaSyntax.tokenize`, which correctly handles strings, char
literals, and block/line comments.

```julia
bundle_app(BundleConfig(...; strip_comments = true))
```

**What it removes**: line comments (`# ...`), block comments (`#= ... =#`).
**What it leaves**: docstrings (those are string literals attached to defs,
not comments), variable names, function bodies, control flow.

**Verdict**: removes *intent* (the "why" you wrote in comments). Does **not**
remove the code itself. Casual reader sees uglier-but-still-readable code.

#### (b) Patch `.ji` cache header to drop `srctext` records

If you binary-edit the `.ji` to zero out the recorded source-hash table,
`Base.stale_cachefile` skips the source check entirely. Then you can blank
the `.jl` files to anything you want (as long as the module declaration
remains for the loader to find it).

**Status**: technically possible — the format is in `base/loading.jl`
(`parse_cache_header`, `srctext_files`). Not implemented here because:
- The `.ji` format changes between Julia point releases
- You're shipping a bundle that depends on undocumented internals
- A future `using` may regress badly if Julia adds new validation

**Verdict**: works today; brittle to maintain. Worth it only if you have
strong CI tied to a specific Julia version and you really need the `.jl`
files gone.

#### (c) Run as a service, never ship code

If your code is a genuine trade secret, **don't ship it**. Wrap it in an
HTTP/gRPC server, host it, sell API access. This is the only approach that
actually works against a determined adversary, regardless of language.

### What no Julia distribution method protects against

A user with the bundle/image and `objdump`/`gdb`/`Base.code_typed` can:
- Read `.jl` files (if present)
- Disassemble `.so` package images
- Use `methods()` and `code_typed` introspection on loaded modules to
  recover Julia-level signatures and IR
- Dump the `.ji` files with `Base.parse_cache_header` and friends

`PackageCompiler.jl` sysimages share most of these vulnerabilities —
they're not magic either.

### Practical recommendation

For most projects:
1. Use `strip_comments = true` to remove intent-revealing comments.
2. Distribute as a Docker image, not a raw folder.
3. If your code is genuinely sensitive, host it as a service.

If you must distribute readable executables of sensitive code, **Julia is
the wrong tool** today. C++ with stripped binaries + control-flow
flattening is closer to what you want, with all the productivity costs that
implies.

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
