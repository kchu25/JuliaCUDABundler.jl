module FluxDemo

using Flux, CUDA, Random

"""
Train a tiny MLP on a synthetic regression task: y = sin(x1) + cos(x2).
Runs on GPU if CUDA is functional; otherwise falls back to CPU.
"""
function train(; n_samples::Int = 4096, epochs::Int = 50, hidden::Int = 64)
    Random.seed!(0)

    # Synthetic data
    X = randn(Float32, 2, n_samples)
    y = reshape(sin.(X[1, :]) .+ cos.(X[2, :]), 1, n_samples)

    # Model
    model = Chain(
        Dense(2 => hidden, relu),
        Dense(hidden => hidden, relu),
        Dense(hidden => 1),
    )

    # Move to GPU if available
    use_gpu = CUDA.functional()
    device = use_gpu ? gpu : cpu
    println("Device         : ", use_gpu ? "GPU ($(CUDA.name(CUDA.device())))" : "CPU")

    model = device(model)
    X_dev = device(X)
    y_dev = device(y)

    opt_state = Flux.setup(Adam(1e-3), model)
    loss_fn(m, x, y) = Flux.mse(m(x), y)

    print("Training       : ")
    for ep in 1:epochs
        grads = Flux.gradient(loss_fn, model, X_dev, y_dev)
        Flux.update!(opt_state, model, grads[1])
        if ep == 1 || ep % 10 == 0
            l = loss_fn(model, X_dev, y_dev)
            print("ep=$ep loss=$(round(Float32(l); digits=4))  ")
        end
    end
    println()

    final_loss = Float32(loss_fn(model, X_dev, y_dev))
    println("Final MSE      : ", final_loss)

    # Inference demo on a few new points
    Xtest = Float32[0.5 -1.0  1.5; 0.0  0.7 -0.3]
    ŷ = cpu(model(device(Xtest)))
    ytrue = sin.(Xtest[1, :]) .+ cos.(Xtest[2, :])
    println("Predictions    : ", round.(vec(ŷ); digits=3))
    println("Ground truth   : ", round.(ytrue; digits=3))

    return final_loss < 0.05f0 ? 0 : 1
end

function julia_main()::Cint
    epochs = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 50
    try
        return train(; epochs = epochs)
    catch e
        showerror(stderr, e)
        println(stderr)
        return 1
    end
end

end # module
