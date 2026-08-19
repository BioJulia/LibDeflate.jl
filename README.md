# <img src="./assets/sticker.svg" width="30%" align="right" /> LibDeflate

![CI](https://github.com/BioJulia/LibDeflate.jl/workflows/CI/badge.svg)
[![Codecov](https://codecov.io/gh/jakobnissen/LibDeflate.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/BioJulia/LibDeflate.jl)

This package provides high-performance functionality for compressing and decompressing raw DEFLATE payloads, as well as zlib and gzip data.

It presents a Julia abstraction over [`libdeflate`](https://github.com/ebiggers/libdeflate),
a heavily optimized implementation of the DEFLATE compression algorithm used in the zip, bgzip, and gzip formats.
Unlike libz or the gzip binary, LibDeflate does not support streaming, so it is intended for use with files that fit in memory or with block-compressed formats such as bgzip.
It is significantly faster than either libz or gzip.

This package's APIs prioritize performance and explicitness over convenience.
It is trimmable and low-allocation.

For more information, see [the documentation](https://biojulia.dev/LibDeflate.jl/stable/),
or load the package and explore the docstrings of exported and public methods and types.

## Quickstart
```julia
using LibDeflate

compressor = Compressor(0x09)
decompressor = Decompressor()

data = "Lorem Ipsum, and so on"

min_size = deflate_compress_bound(compressor, UInt(ncodeunits(data)))

out = zeros(UInt8, Int(min_size))
n_written = compress!(compressor, out, data)

roundtrip = zeros(UInt8, 50)
result = decompress!(decompressor, roundtrip, view(out, 1:n_written))

@assert String(view(roundtrip, 1:result.written)) == data
```

## Questions?
If you have a question about contributing or using BioJulia software, come
on over and chat to us on [the Julia Slack workspace](https://julialang.org/slack/), or you can try the
[Bio category of the Julia discourse site](https://discourse.julialang.org/c/domain/bio).

