module CudaDemo

using CUDA

function run_demo(n::Int)
    if !CUDA.functional()
        println(stderr, "CUDA is not functional on this machine")
        return 1
    end
    println("GPU            : ", CUDA.name(CUDA.device()))
    println("Vector length  : ", n)
    a = CUDA.rand(Float32, n)
    b = CUDA.rand(Float32, n)
    c = a .+ b
    CUDA.synchronize()
    s = sum(c)
    println("sum(a .+ b)    = ", s, "   (expected ≈ ", n, ")")
    return 0
end

function julia_main()::Cint
    n = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 1_000_000
    try
        return run_demo(n)
    catch e
        println(stderr, "error: ", e)
        return 1
    end
end

end # module
