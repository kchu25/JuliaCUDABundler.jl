using JuliaCUDABundler
using Test

# Build a tiny non-GPU app so tests are fast & run anywhere.
const TEST_DIR = mktempdir()
const APP_DIR  = joinpath(TEST_DIR, "TinyApp")
const OUT_DIR  = joinpath(TEST_DIR, "tiny_bundle")

mkpath(joinpath(APP_DIR, "src"))
write(joinpath(APP_DIR, "Project.toml"), """
name = "TinyApp"
uuid = "33333333-3333-3333-3333-333333333333"
version = "0.1.0"
""")
write(joinpath(APP_DIR, "src", "TinyApp.jl"), """
module TinyApp
function julia_main()::Cint
    println("hello from TinyApp, args=", ARGS)
    return 0
end
end
""")

@testset "JuliaCUDABundler" begin
    @testset "BundleConfig defaults" begin
        c = BundleConfig(project_dir=APP_DIR, output_dir=OUT_DIR, entry_module="TinyApp")
        @test c.entry_function == "julia_main"
        @test c.bundle_julia
        @test !c.obfuscate_source
    end

    @testset "bundle_app builds and runs" begin
        bundle_app(BundleConfig(
            project_dir  = APP_DIR,
            output_dir   = OUT_DIR,
            entry_module = "TinyApp",
            bundle_julia = false,
        ))

        @test isfile(joinpath(OUT_DIR, "bin", "TinyApp"))
        @test isfile(joinpath(OUT_DIR, "Dockerfile"))
        @test isfile(joinpath(OUT_DIR, "BUNDLE_INFO.txt"))
        @test isdir(joinpath(OUT_DIR, "julia_depot", "compiled"))

        # Native .so package images must exist (the actual compiled code)
        compiled = joinpath(OUT_DIR, "julia_depot", "compiled")
        sos = String[]
        for (root, _, files) in walkdir(compiled), f in files
            endswith(f, ".so") && push!(sos, joinpath(root, f))
        end
        @test !isempty(sos)

        # Launcher must run and print from the cached code
        out = read(`$(joinpath(OUT_DIR, "bin", "TinyApp")) one two`, String)
        @test occursin("hello from TinyApp", out)
        @test occursin("one", out) && occursin("two", out)
    end

    @testset "_strip_jl_string preserves semantics" begin
        f = JuliaCUDABundler._strip_jl_string
        # comments removed
        @test !occursin("comment", f("# a comment\nx = 1"))
        # string contents preserved
        s = f("""x = "# not a comment"\n# real comment""")
        @test occursin("# not a comment", s)
        @test !occursin("real comment", s)
        # block comment removed
        @test !occursin("inside", f("a #= inside =# b"))
    end

    @testset "strip_comments produces a runnable bundle" begin
        APP2 = joinpath(TEST_DIR, "CommApp")
        OUT2 = joinpath(TEST_DIR, "comm_bundle")
        mkpath(joinpath(APP2, "src"))
        write(joinpath(APP2, "Project.toml"), """
        name = "CommApp"
        uuid = "44444444-4444-4444-4444-444444444444"
        version = "0.1.0"
        """)
        write(joinpath(APP2, "src", "CommApp.jl"), """
        # SECRET ALGORITHM: do not share
        module CommApp
        # this comment should disappear
        function julia_main()::Cint
            x = "# this # stays"   # but this trailing one goes
            println(x)
            return 0
        end
        end
        """)

        bundle_app(BundleConfig(
            project_dir    = APP2,
            output_dir     = OUT2,
            entry_module   = "CommApp",
            bundle_julia   = false,
            strip_comments = true,
        ))

        bundled_src = read(joinpath(OUT2, "app", "src", "CommApp.jl"), String)
        @test !occursin("SECRET ALGORITHM", bundled_src)
        @test !occursin("disappear", bundled_src)
        @test !occursin("trailing one goes", bundled_src)
        # string contents preserved
        @test occursin("# this # stays", bundled_src)

        # And the bundle still runs
        out = read(`$(joinpath(OUT2, "bin", "CommApp"))`, String)
        @test occursin("# this # stays", out)
    end

    @testset "redact_source removes logic but keeps bundle runnable" begin
        APP3 = joinpath(TEST_DIR, "RedactApp")
        OUT3 = joinpath(TEST_DIR, "redact_bundle")
        mkpath(joinpath(APP3, "src"))
        write(joinpath(APP3, "Project.toml"), """
        name = "RedactApp"
        uuid = "55555555-5555-5555-5555-555555555555"
        version = "0.1.0"
        """)
        write(joinpath(APP3, "src", "RedactApp.jl"), """
        module RedactApp
        const PROPRIETARY_CONSTANT = 12345
        function secret_algorithm(x)
            return x * PROPRIETARY_CONSTANT + 7
        end
        function julia_main()::Cint
            println("answer = ", secret_algorithm(3))
            return 0
        end
        end
        """)

        bundle_app(BundleConfig(
            project_dir   = APP3,
            output_dir    = OUT3,
            entry_module  = "RedactApp",
            bundle_julia  = false,
            redact_source = true,
        ))

        bundled = read(joinpath(OUT3, "app", "src", "RedactApp.jl"), String)
        @test !occursin("PROPRIETARY_CONSTANT", bundled)
        @test !occursin("12345", bundled)
        @test !occursin("secret_algorithm", bundled)
        @test occursin("module RedactApp", bundled)
        @test occursin("Redacted", bundled)

        # Bundle must still execute the (cached) original logic
        out = read(`$(joinpath(OUT3, "bin", "RedactApp"))`, String)
        @test occursin("answer = 37042", out)   # 3 * 12345 + 7
    end

    @testset "redact_source: multi-file project" begin
        APP4 = joinpath(TEST_DIR, "MultiFile")
        OUT4 = joinpath(TEST_DIR, "multi_bundle")
        mkpath(joinpath(APP4, "src"))
        write(joinpath(APP4, "Project.toml"), """
        name = "MultiFile"
        uuid = "88888888-8888-8888-8888-888888888888"
        version = "0.1.0"
        """)
        write(joinpath(APP4, "src", "helpers.jl"), """
        const HELPER_CONSTANT = 100
        helper_compute(x) = x * HELPER_CONSTANT
        """)
        write(joinpath(APP4, "src", "more.jl"), """
        extra(x) = x + 1
        """)
        write(joinpath(APP4, "src", "MultiFile.jl"), """
        module MultiFile
        include("helpers.jl")
        include("more.jl")
        function julia_main()::Cint
            println("result = ", extra(helper_compute(2)))
            return 0
        end
        end
        """)

        bundle_app(BundleConfig(
            project_dir   = APP4,
            output_dir    = OUT4,
            entry_module  = "MultiFile",
            bundle_julia  = false,
            redact_source = true,
        ))

        # Every .jl file in src/ is redacted
        for f in ("MultiFile.jl", "helpers.jl", "more.jl")
            bundled = read(joinpath(OUT4, "app", "src", f), String)
            @test !occursin("HELPER_CONSTANT", bundled)
            @test !occursin("helper_compute", bundled)
            @test !occursin("extra(", bundled)
        end
        # Top-level file keeps module shell so `using MultiFile` resolves
        top = read(joinpath(OUT4, "app", "src", "MultiFile.jl"), String)
        @test occursin("module MultiFile", top)

        # Bundle runs the cached implementation: extra(helper_compute(2)) = 201
        out = read(`$(joinpath(OUT4, "bin", "MultiFile"))`, String)
        @test occursin("result = 201", out)
    end

    @testset "glue app: project with local path-dep bundles correctly" begin
        # Mirrors the user's intended workflow: a thin "glue" package depending
        # on one (or several) local sibling packages declared via `[sources]`.
        # The bundler must precompile both into the private depot and the
        # launcher must execute code from the dep, not just the entry module.
        GLUE_ROOT = joinpath(TEST_DIR, "glue_root")
        PKG_B     = joinpath(GLUE_ROOT, "MyLibB")
        PKG_A     = joinpath(GLUE_ROOT, "GlueApp")
        OUT5      = joinpath(GLUE_ROOT, "glue_bundle")
        mkpath(joinpath(PKG_B, "src"))
        mkpath(joinpath(PKG_A, "src"))

        write(joinpath(PKG_B, "Project.toml"), """
        name = "MyLibB"
        uuid = "66666666-6666-6666-6666-666666666666"
        version = "0.1.0"
        """)
        write(joinpath(PKG_B, "src", "MyLibB.jl"), """
        module MyLibB
        export greet
        greet(name) = "hello from MyLibB to \$name"
        end
        """)

        write(joinpath(PKG_A, "Project.toml"), """
        name = "GlueApp"
        uuid = "77777777-7777-7777-7777-777777777777"
        version = "0.1.0"

        [deps]
        MyLibB = "66666666-6666-6666-6666-666666666666"

        [sources]
        MyLibB = {path = "$(PKG_B)"}
        """)
        write(joinpath(PKG_A, "src", "GlueApp.jl"), """
        module GlueApp
        using MyLibB
        function julia_main()::Cint
            println(greet("glue"))
            return 0
        end
        end
        """)

        bundle_app(BundleConfig(
            project_dir  = PKG_A,
            output_dir   = OUT5,
            entry_module = "GlueApp",
            bundle_julia = false,
        ))

        # Both package images must land in the private depot
        compiled = joinpath(OUT5, "julia_depot", "compiled")
        sos = String[]
        for (root, _, files) in walkdir(compiled), f in files
            endswith(f, ".so") && push!(sos, joinpath(root, f))
        end
        @test any(s -> occursin("GlueApp", s), sos)
        @test any(s -> occursin("MyLibB",  s), sos)

        # The dep's code actually runs through the launcher
        out = read(`$(joinpath(OUT5, "bin", "GlueApp"))`, String)
        @test occursin("hello from MyLibB to glue", out)
    end

    @testset "glue app: transitive path-deps (3-level chain)" begin
        # Real-world glue scenario: Glue → InferencePkg → DeepDep, where each
        # package declares its own immediate path-deps in its own [sources].
        # Julia 1.11+ follows [sources] transitively, so the top-level glue
        # only needs to know about its direct path-deps.
        ROOT  = joinpath(TEST_DIR, "chain_root")
        DEEP  = joinpath(ROOT, "DeepDep")
        INF   = joinpath(ROOT, "InferencePkg")
        GLUE  = joinpath(ROOT, "Glue")
        OUT7  = joinpath(ROOT, "chain_bundle")
        for d in (DEEP, INF, GLUE); mkpath(joinpath(d, "src")); end

        # Leaf
        write(joinpath(DEEP, "Project.toml"), """
        name = "DeepDep"
        uuid = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        version = "0.1.0"
        """)
        write(joinpath(DEEP, "src", "DeepDep.jl"), """
        module DeepDep
        leaf() = "from DeepDep"
        end
        """)

        # Middle: declares DeepDep in its own [sources]
        write(joinpath(INF, "Project.toml"), """
        name = "InferencePkg"
        uuid = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        version = "0.1.0"

        [deps]
        DeepDep = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

        [sources]
        DeepDep = {path = "$(DEEP)"}
        """)
        write(joinpath(INF, "src", "InferencePkg.jl"), """
        module InferencePkg
        using DeepDep
        mid() = "InferencePkg->" * DeepDep.leaf()
        end
        """)

        # Top: declares only InferencePkg; Pkg follows InferencePkg's [sources]
        # transitively to find DeepDep.
        write(joinpath(GLUE, "Project.toml"), """
        name = "Glue"
        uuid = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        version = "0.1.0"

        [deps]
        InferencePkg = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

        [sources]
        InferencePkg = {path = "$(INF)"}
        """)
        write(joinpath(GLUE, "src", "Glue.jl"), """
        module Glue
        using InferencePkg
        function julia_main()::Cint
            println("Glue->" * InferencePkg.mid())
            return 0
        end
        end
        """)

        bundle_app(BundleConfig(
            project_dir  = GLUE,
            output_dir   = OUT7,
            entry_module = "Glue",
            bundle_julia = false,
        ))

        # All three package images must land in the private depot
        compiled = joinpath(OUT7, "julia_depot", "compiled")
        sos = String[]
        for (root, _, files) in walkdir(compiled), f in files
            endswith(f, ".so") && push!(sos, joinpath(root, f))
        end
        @test any(s -> occursin("Glue",         s), sos)
        @test any(s -> occursin("InferencePkg", s), sos)
        @test any(s -> occursin("DeepDep",      s), sos)

        # End-to-end: every link in the chain executes
        out = read(`$(joinpath(OUT7, "bin", "Glue"))`, String)
        @test occursin("Glue->InferencePkg->from DeepDep", out)
    end

    @testset "re-bundling to the same output dir is idempotent" begin
        APP6 = joinpath(TEST_DIR, "ReApp")
        OUT6 = joinpath(TEST_DIR, "re_bundle")
        mkpath(joinpath(APP6, "src"))
        write(joinpath(APP6, "Project.toml"), """
        name = "ReApp"
        uuid = "99999999-9999-9999-9999-999999999999"
        version = "0.1.0"
        """)
        write(joinpath(APP6, "src", "ReApp.jl"), """
        module ReApp
        function julia_main()::Cint
            println("re-app run ", get(ENV, "REAPP_TAG", "?"))
            return 0
        end
        end
        """)

        cfg = BundleConfig(
            project_dir  = APP6,
            output_dir   = OUT6,
            entry_module = "ReApp",
            bundle_julia = false,
        )

        bundle_app(cfg)
        out1 = read(setenv(`$(joinpath(OUT6, "bin", "ReApp"))`, "REAPP_TAG" => "first"), String)
        @test occursin("re-app run first", out1)

        # Re-bundle to the same output dir; bundle_app must wipe + rebuild
        bundle_app(cfg)
        out2 = read(setenv(`$(joinpath(OUT6, "bin", "ReApp"))`, "REAPP_TAG" => "second"), String)
        @test occursin("re-app run second", out2)
    end
end
