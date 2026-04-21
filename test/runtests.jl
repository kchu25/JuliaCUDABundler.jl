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
end
