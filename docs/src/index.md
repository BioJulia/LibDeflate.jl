```@meta
DocTestSetup = quote
    using LibDeflate

    # Define some global variables here that will be available in your docstrings
    compressor = Compressor()
    decompressor = Decompressor()
end
```

# LibDeflate.jl
LibDeflate.jl provides high-performance, low-level APIs for compressing and decompressing gzip, zlib, and DEFLATE formats. It is much faster than other implementations, but only works with in-memory buffers; it cannot compress or decompress streamed data.
Therefore, LibDeflate.jl is useful when compression or decompression is a bottleneck, but your data is small enough to fit in memory. Examples include [blocked compression](https://www.google.com/url?sa=t&source=web&rct=j&opi=89978449&url=https://en.wikipedia.org/wiki/BGZF&ved=2ahUKEwjt3f-xraqWAxUncPEDHQA3H60QFnoECAUQAQ&usg=AOvVaw1QxdI2paqlPcgXTulNvbMU) and situations where many small gzip packages are sent over a network.

LibDeflate.jl implements the computationally lightweight parts in Julia and delegates the computationally intensive parts to Eric Biggers's C library, [libdeflate](https://github.com/ebiggers/libdeflate).

The API is intended to be low-level and precisely documented; for example, abstract types are avoided and precise unsigned integer types are used.
The APIs have low allocation overhead (but are not zero-allocation) and are trimmable.

!!! warning
    LibDeflate.jl's APIs are generally **not** thread-safe or safe in the presence of aliasing
    between memory buffers passed to a single function. It is the user's responsibility to ensure
    that no [`Compressor`](@ref) or [`Decompressor`](@ref) is used concurrently and that no two
    arguments to a function call alias.

Most APIs come in safe and unsafe variants. The unsafe ones take [`ReadableMemory`](@ref) and [`WriteableMemory`](@ref), which are structs that simply hold a pointer and a length.
These functions allow LibDeflate to be used with foreign (non-Julia-owned) memory.
The safe variants construct these memory types internally from Julia-owned memory and call the unsafe ones.
This incurs almost no overhead, so it is the preferred API when processing Julia-owned memory, such as a regular `Vector{UInt8}`.
To use custom types with the safe functions, you must implement constructors for `ReadableMemory(::MyType)` or `WriteableMemory(::MyType)`.

See the reference in the sidebar for the full API. For an overview, this package implements:

* Single-member gzip de/compression
* Multi-member gzip decompression
* DEFLATE de/compression
* zlib de/compression
* Functions for obtaining an upper bound on the number of bytes written when compressing a given number of bytes
* CRC-32
* Adler-32
