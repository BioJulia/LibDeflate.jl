# <img src="./assets/sticker.svg" width="30%" align="right" /> LibDeflate.jl

[![CI](https://github.com/BioJulia/LibDeflate.jl/actions/workflows/UnitTests.yml/badge.svg)](https://github.com/BioJulia/LibDeflate.jl/actions/workflows/UnitTests.yml)
[![Codecov](https://codecov.io/gh/jakobnissen/LibDeflate.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/BioJulia/LibDeflate.jl)
[![Documentation](https://img.shields.io/badge/docs-dev-blue.svg)](https://biojulia.github.io/BioJuliaTemplate.jl/stable)

This package provides high-performance compression and decompression of gzip, zlib and raw DEFLATE payloads, as well as Adler32 and CRC32 checksumming.
It is a Julia abstraction over [Eric Biggers's C library `libdeflate`](https://github.com/ebiggers/libdeflate).

LibDeflate.jl outperforms CodecZlib.jl and is on par with isa-l. However, unlike CodecZlib.jl, LibDeflate does not support streaming, so it is intended for use with files that fit in memory or with block-compressed formats such as bgzip.

This package's APIs prioritize performance and explicitness over convenience.
It is trimmable and low-allocation.

For more information, see [the documentation](https://biojulia.dev/LibDeflate.jl/stable/),
or load the package and explore the docstrings of public functions and types.

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

