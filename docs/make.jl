using Documenter, PolynomialRings

makedocs(
    modules = [PolynomialRings],
    repo = "https://github.com/tkluck/PolynomialRings.jl.git",
    doctest = false,
    format = :html,
    sitename = "PolynomialRings.jl",
    authors = "Timo Kluck",
    pages = [
        "Home" => "index.md"
        "Getting Started" => "getting-started.md"
        "Reference Index" => "reference.md"
        "Types and Functions" => "functions.md"
    ],
)

deploydocs(
    repo   = "github.com/tkluck/PolynomialRings.jl.git",
    julia  = "0.6",
    osname = "linux",
    target = "build",
    deps   = nothing,
    make   = nothing,
)
