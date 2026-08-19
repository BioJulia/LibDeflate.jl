using Documenter, LibDeflate

# This code will be executed in the environment your doctests inside the
# package's docstrings are run.
# Use it to define some global variables that can be referred to in your
# docstrings.
meta = quote
    using LibDeflate
    compressor = Compressor()
    decompressor = Decompressor()
end

DocMeta.setdocmeta!(LibDeflate, :DocTestSetup, meta; recursive = true)

makedocs(
    modules = [LibDeflate, LibDeflate.LibDeflateErrors],
    repo = Documenter.Remotes.GitHub("BioJulia", "LibDeflate.jl"),
    sitename = "LibDeflate.jl",
    doctest = true,
    pages = [
        "LibDeflate" => "index.md",
        "Reference" => "reference.md",
    ],
    authors = "Jakob Nybo Andersen",
    checkdocs = :public,
)

deploydocs(;
    repo = "github.com/BioJulia/LibDeflate.jl.git",
    push_preview = true,
    deps = nothing,
    make = nothing,
)
