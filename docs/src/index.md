```@meta
DocTestSetup = quote
    using LibDeflate

    # Define some global variables here that will be available in your docstrings
    compressor = Compressor()
    decompressor = Decompressor()
end
```

# LibDeflate.jl
LibDeflate.jl provides bindings to

It uses the C library [libdeflate](https://github.com/ebiggers/libdeflate) for the computationally demanding parts.
