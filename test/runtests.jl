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
end
