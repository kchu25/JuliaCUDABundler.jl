using JuliaCUDABundler
using Documenter

DocMeta.setdocmeta!(JuliaCUDABundler, :DocTestSetup, :(using JuliaCUDABundler); recursive=true)

makedocs(;
    modules=[JuliaCUDABundler],
    authors="Shane Kuei-Hsien Chu (skchu@wustl.edu)",
    sitename="JuliaCUDABundler.jl",
    format=Documenter.HTML(;
        canonical="https://kchu25.github.io/JuliaCUDABundler.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/kchu25/JuliaCUDABundler.jl",
    devbranch="main",
)
