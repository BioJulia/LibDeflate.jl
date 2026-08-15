# LibDeflate.jl

![CI](https://github.com/jakobnissen/LibDeflate.jl/workflows/CI/badge.svg)
[![Codecov](https://codecov.io/gh/jakobnissen/LibDeflate.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/jakobnissen/LibDeflate.jl)

This package provides Julia bindings for [libdeflate](https://github.com/ebiggers/libdeflate).

Libdeflate is a heavily optimized implementation of the DEFLATE compression algorithm used in the zip, bgzip and gzip formats. Unlike libz or gzip, libdeflate does not support streaming, and so is intended for use in of files that fit in-memory or for block-compressed files like bgzip. But it is significantly faster than either libz or gzip.

This package provides simple functionality for working with raw DEFLATE payloads, zlib and gzip data. It is intended for internal use by other packages, not to be used directly by users. Hence, its interface is somewhat small.

### Interface
Many functions have a "safe" and an "unsafe" variant. Unsafe variants accept
`ReadableMemory` and `WriteableMemory`, which are simple pointer-and-length wrappers.
Safe variants accept generic Julia objects and convert them to these wrappers. Custom
container types can opt in by implementing `ReadableMemory(::MyType)` and, for mutable
outputs, `WriteableMemory(::MyType)`.

Built-in array conversions are limited to contiguous dense arrays of integer or IEEE
floating-point elements; arbitrary bitstypes may contain padding and require an explicit
opt-in constructor.

Buffer lengths, byte offsets, byte counts, and count results use native `UInt`, matching
libdeflate's `size_t` interface. APIs that accept counts require that concrete type; a
nonnegative `length` or `sizeof` result can be converted without a range check using
`n % UInt`. In accordance with Base conventions, `sizeof(::ReadableMemory)` and
`sizeof(::WriteableMemory)` still return `Int`.

Narrower unsigned types identify actual format limits: checksum values and gzip wire
fields use `UInt32`, gzip XLEN values use `UInt16`, and compression levels use `UInt8`.

When possible, use the safe variants as the overhead is rather small. Raw DEFLATE
`decompress!` returns a named tuple containing the number of input bytes read and output
bytes written, so callers can retain trailing input. Gzip decompression similarly reports
the number of bytes occupied by the first gzip member through `GzipDecompressResult.read`.
Use `gzip_decompress_all!` when the input must be a complete gzip file and every
concatenated member should be decoded into one output buffer. If a later member is
invalid, it returns `(completed, error)`, where `completed` reports the valid members
decoded before the error.

All compression and decompression functions ending in `!` write into fixed-size output
buffers and never resize them. If an output buffer is too small, they return
`deflate_insufficient_space`. The `deflate_compress_bound`, `gzip_compress_bound`, and
`zlib_compress_bound` functions return output sizes that are guaranteed to be sufficient
for compression. These bound functions take byte counts and compute their results in
constant time without inspecting input data. The raw DEFLATE, zlib, and single-member
gzip decompressors provide an optional trailing `n_out` argument for the faster
exact-size path, in both their safe and unsafe APIs. Multi-member gzip decompression
instead reports the total number of bytes written for callers to verify.

For more details on these functions, read their docstrings which define their API.
Functions and types without a docstring are internal.

Compression, decompression, and data-format errors are represented by
`LibDeflateError` objects. Most operations return the error directly;
`gzip_decompress_all!` also returns the successfully completed prefix alongside it.

__Common exported types__
* `Decompressor`: Create an object that decompresses using DEFLATE.
* `Compressor(level::UInt8)`: Create an object that compresses using the given DEFLATE
  level.
* `LibDeflateError`: An enum with all LibDeflate errors.
* `ReadableMemory`: A pointer and a length. Constructable from types that are pointer-readable.
* `WriteableMemory`: A pointer and a length. Constructable from types that are pointer-writeable.

__Working with DEFLATE payloads__
* `(unsafe_)decompress!`: DEFLATE decompress payload.
* `(unsafe_)compress!`: DEFLATE compress payload
* `deflate_compress_bound`: Get a worst-case compressed size.

__Working with gzip files__
* `(unsafe_)gzip_decompress!`: Decompress gzip data.
* `(unsafe_)gzip_decompress_all!`: Decompress all members of a complete gzip file.
* `(unsafe_)gzip_compress!`: Compress gzip data and/or metadata
* `gzip_compress_bound`: Get a worst-case compressed size, including metadata.

* `(unsafe_)parse_gzip_header`: Parse out gzip header
* `(unsafe_)is_valid_extra_data`: Check if some bytes are valid metadata for the gzip "extra" field.

__Working with Libz files__
* `(unsafe_)zlib_decompress!`: Decompress zlib data.
* `(unsafe_)zlib_compress!`: Compress zlib data
* `zlib_compress_bound`: Get a worst-case compressed size.

__Miscellaneous__
* `(unsafe)_crc32`: Compute the crc32 checksum of the bytes at `data`. Note that this is _not_ the same algorithm as `crc32c`.
* `(unsafe)_adler32`: Compute the Adler32 checksum of the bytes at `data`.
