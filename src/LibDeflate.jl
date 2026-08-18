"""
    Module LibDeflate

`LibDeflate` provides Julia bindings for the C library `libdeflate`. The C library,
and the corresponding Julia package, contain highly optimized code for compressing and
uncompressing data using the DEFLATE algorithm, including gzip, or zlib formats.
"""
module LibDeflate

using Base: FastContiguousSubArray
using libdeflate_jll

"""
    Module LibDeflateErrors

Dummy module to contain the variants of the `LibDeflateError` enum.
"""
module LibDeflateErrors

    @enum LibDeflateError::UInt8 begin
        deflate_bad_payload
        deflate_output_too_short
        deflate_insufficient_space
        gzip_header_too_short
        gzip_bad_magic_bytes
        gzip_not_deflate
        gzip_bad_flags
        gzip_string_not_null_terminated
        gzip_null_in_string
        gzip_bad_header_crc16
        gzip_bad_crc32
        gzip_extra_too_long
        gzip_bad_extra
        zlib_input_too_short
        zlib_not_deflate
        zlib_wrong_window_size
        zlib_needs_compression_dict
        zlib_bad_header_check
        zlib_bad_adler32
        zlib_insufficient_space
    end

    @doc """
        LibDeflateError

    A `UInt8` enum representing that LibDeflate encountered an error. The numerical value
    of the errors are not stable across non-breaking releases, but their names are.
    Code checking for specific errors should check by e.g. ` == LibDeflateErrors.gzip_not_deflate`.
    Successful operations will not return a `LibDeflateError`.

    # Examples:
    ```jldoctest
    julia> c = vcat(
               b"\\x01\\x0d\\0\\xf2\\xff\\x48\\x65\\x6c\\x6c",
               b"\\x6f\\x2c\\x20\\x77\\x6f\\x72\\x6c\\x64\\x21",
           );

    julia> out = zeros(UInt8, 2); # too small to hold the decompressed data

    julia> err = decompress!(decompressor, out, c);

    julia> err isa LibDeflateError
    true

    julia> err == LibDeflateErrors.deflate_insufficient_space
    true
    ```
    """
    LibDeflateError

    export LibDeflateError
end # module

using .LibDeflateErrors

const DEFAULT_COMPRESSION_LEVEL = UInt8(6)

# This is derived from the internal Base.FastContiguousSubArray, which is supposed to
# represent SubArrays that are contiguous.
const DenseByteSubArray = SubArray{UInt8, N, <:DenseArray, I, true} where {
    N, I <: Union{Tuple{Vararg{Real}}, Tuple{AbstractUnitRange, Vararg{Any}}},
}

"""
    NonZeroUInt32

Container that stores an `UInt32` value, which cannot be zero.
Obtain the inner value with the `.x` property:

# Examples
```jldoctest
julia> x = NonZeroUInt32(UInt32(3)); x.x
0x00000003

julia> NonZeroUInt32(UInt32(0))
ERROR: ArgumentError: Cannot construct a NonZeroUInt32 from zero
[...]
```
"""
struct NonZeroUInt32
    x::UInt32

    global unsafe_new_nonzerou32(x::UInt32) = new(x)

    function NonZeroUInt32(x::UInt32)
        iszero(x) && throw(ArgumentError("Cannot construct a NonZeroUInt32 from zero"))
        return new(x)
    end
end

try_nonzero_uint32(x::UInt32) = iszero(x) ? nothing : unsafe_new_nonzerou32(x)

"""
    WriteableMemory

Struct that wraps a pointer and a length. This struct is not garbage-collector aware,
so must be used with `GC.@preserve`. This type can be constructed from `DenseArray{UInt8}`,
`String`, `SubString{String}` and some `SubArray`s. It may also be directly constructed
from a `Ptr` and an `Integer`.
To make custom types available as output for `LibDeflate`, add a constructor taking
the custom type.
This type implements `pointer(::WriteableMemory)::Ptr{Nothing}` and
`sizeof(::WriteableMemory)::Int`.

See also: [`ReadableMemory`](@ref)

# Examples:
```jldoctest
julia> v = fill(0x00, 4);

julia> GC.@preserve v begin
           w = WriteableMemory(v)
           @assert sizeof(w) === 4
           ptr = Ptr{UInt32}(pointer(w))
           unsafe_store!(ptr, 0x01020304)
           unsafe_load(ptr) |> show
       end
0x01020304
```
"""
struct WriteableMemory
    ptr::Ptr{Nothing}
    len::UInt

    global function unsafe_writeable_memory(ptr::Ptr, len::UInt)
        return new(Ptr{Nothing}(ptr), len)
    end

    function WriteableMemory(ptr::Ptr, len::Integer)
        length = UInt(len)::UInt
        if length > (typemax(Int) % UInt)
            throw(DomainError(len, "WriteableMemory length cannot exceed typemax(Int)"))
        end
        return new(Ptr{Nothing}(ptr), length)
    end
end

WriteableMemory(x::WriteableMemory) = x

function WriteableMemory(x::Union{Array{UInt8}, Memory{UInt8}})
    return unsafe_writeable_memory(pointer(x), length(x) % UInt)
end

function WriteableMemory(x::DenseByteSubArray)
    return WriteableMemory(pointer(x), UInt(length(x)))
end

"""
    ReadableMemory

Struct that wraps a pointer and a length. This struct is not garbage-collector aware,
so must be used with `GC.@preserve`. This type can be constructed from `DenseArray{UInt8}`,
`String`, `SubString{String}` and some `SubArray`s. It may also be directly constructed
from a `Ptr` and an `Integer`.
To make custom types available as input for `LibDeflate`, add a constructor taking
your custom type.

# Examples:
```jldoctest
julia> v = [0x01, 0x02, 0x03, 0x04];

julia> GC.@preserve v begin
           r = ReadableMemory(v)
           @assert sizeof(r) === 4
           ptr = Ptr{UInt32}(pointer(r))
           htol(unsafe_load(ptr)) |> show
       end
0x04030201
```

See also: [`WriteableMemory`](@ref)
"""
struct ReadableMemory
    ptr::Ptr{Nothing}
    len::UInt

    global function unsafe_readable_memory(ptr::Ptr, len::UInt)
        return new(Ptr{Nothing}(ptr), len)
    end

    function ReadableMemory(ptr::Ptr, len::Integer)
        length = UInt(len)::UInt
        if length > (typemax(Int) % UInt)
            throw(DomainError(len, "ReadableMemory length cannot exceed typemax(Int)"))
        end
        return new(Ptr{Nothing}(ptr), length)
    end
end

function ReadableMemory(x::Union{String, SubString{String}})
    return unsafe_readable_memory(pointer(x), ncodeunits(x) % UInt)
end

ReadableMemory(x::ReadableMemory) = x
ReadableMemory(x::WriteableMemory) = unsafe_readable_memory(x.ptr, x.len)

function ReadableMemory(x::Union{Array{UInt8}, Memory{UInt8}})
    return unsafe_readable_memory(pointer(x), length(x) % UInt)
end

function ReadableMemory(x::DenseByteSubArray)
    return unsafe_readable_memory(pointer(x), UInt(length(x)))
end

Base.pointer(x::Union{ReadableMemory, WriteableMemory})::Ptr{Nothing} = x.ptr

# Note: In constructors, we enforce x.len fits in an Int, so this truncate cannot overflow
Base.sizeof(x::Union{ReadableMemory, WriteableMemory})::Int = x.len % Int

# Must be mutable for the GC to be able to interact with it
"""
    Decompressor()

Create an object which can decompress using the DEFLATE algorithm.
The same decompressor cannot be used by multiple threads at the same time.

Creating this object allocates, so when decompressing multiple blocks, keep
the same decompressor in memory rather than making one for each block.

!!! warning
    `Decompressor` is not thread-safe, and therefore should not be used by
    different tasks concurrently. Concurrent use may cause undefined behaviour.

See also: [`decompress!`](@ref), [`unsafe_decompress!`](@ref)

# Examples:
```jldoctest
julia> decompressor = Decompressor();

julia> compressed =
       b"\\x01\\x0d\\0\\xf2\\xff\\x48\\x65\\x6c\\x6c\\x6f\\x2c\\x20\\x77\\x6f\\x72\\x6c\\x64\\x21";

julia> out = zeros(UInt8, 13);

julia> decompress!(decompressor, out, compressed);

julia> String(out)
"Hello, world!"
```
"""
mutable struct Decompressor
    const ptr::Ptr{Nothing}
    actual_nbytes_ret::UInt
    actual_in_nbytes_ret::UInt

    function Decompressor()
        ptr = @ccall gc_safe = true libdeflate.libdeflate_alloc_decompressor()::Ptr{Cvoid}
        decompressor = new(
            ptr,
            zero(UInt),
            zero(UInt),
        )
        finalizer(free_decompressor, decompressor)
        return decompressor
    end
end

Base.unsafe_convert(::Type{Ptr{Nothing}}, x::Decompressor) = x.ptr

function free_decompressor(decompressor::Decompressor)
    GC.@preserve decompressor begin
        @ccall gc_safe = true libdeflate.libdeflate_free_decompressor(
            decompressor::Ptr{Cvoid}
        )::Cvoid
    end
    return nothing
end

"""
    Compressor(compresslevel::UInt8=$(DEFAULT_COMPRESSION_LEVEL))

Create an object which can compress using the DEFLATE algorithm. `compresslevel`
can be from 1 (fast) to 12 (slow), and defaults to $(DEFAULT_COMPRESSION_LEVEL).

Creating this object allocates, so when compressing multiple blocks, keep
the same compressor in memory rather than making one for each block.

!!! warning
    `Compressor` is not thread-safe, and therefore should not be used by
    different tasks concurrently. Concurrent use may cause undefined behaviour.

See also: [`compress!`](@ref), [`unsafe_compress!`](@ref)

# Examples:
```jldoctest
julia> compressor = Compressor();

julia> data = b"Hello, world!";

julia> out = zeros(UInt8, deflate_compress_bound(compressor, UInt(sizeof(data))));

julia> n = compress!(compressor, out, data);

julia> out[1:n] ==
       b"\\x01\\x0d\\0\\xf2\\xff\\x48\\x65\\x6c\\x6c\\x6f\\x2c\\x20\\x77\\x6f\\x72\\x6c\\x64\\x21"
true
```
"""
mutable struct Compressor
    const ptr::Ptr{Nothing}
    const level::UInt8

    function Compressor(compresslevel::UInt8 = DEFAULT_COMPRESSION_LEVEL)
        compresslevel in UInt8(1):UInt8(12) ||
            throw(ArgumentError("Compresslevel must be in 1:12"))
        ptr = @ccall gc_safe = true libdeflate.libdeflate_alloc_compressor(
            (compresslevel % Cint)::Cint
        )::Ptr{Cvoid}
        compressor = new(ptr, compresslevel)
        finalizer(free_compressor, compressor)
        return compressor
    end
end

Base.unsafe_convert(::Type{Ptr{Nothing}}, x::Compressor) = x.ptr

# Called by the garbage collecter, do not use manually
function free_compressor(compressor::Compressor)
    GC.@preserve compressor begin
        @ccall gc_safe = true libdeflate.libdeflate_free_compressor(
            compressor::Ptr{Cvoid}
        )::Cvoid
    end
    return nothing
end

# Compression and decompression functions

# Raw C call - do not export this
function _unsafe_decompress!(
        decompressor::Decompressor,
        out::WriteableMemory,
        in::ReadableMemory,
        actual_in_nbytes_ret::Ptr,
        actual_out_nbytes_ret::Ptr,
    )::Union{LibDeflateError, Nothing}
    status = GC.@preserve decompressor begin
        @ccall gc_safe = true libdeflate.libdeflate_deflate_decompress_ex(
            decompressor::Ptr{Cvoid},
            pointer(in)::Ptr{UInt8},
            in.len::Csize_t,
            pointer(out)::Ptr{UInt8},
            out.len::Csize_t,
            actual_in_nbytes_ret::Ptr{Csize_t},
            actual_out_nbytes_ret::Ptr{Csize_t}
        )::Cint
    end
    if status == Cint(1)
        return LibDeflateErrors.deflate_bad_payload
    elseif status == Cint(2)
        return LibDeflateErrors.deflate_output_too_short
    elseif status == Cint(3)
        return LibDeflateErrors.deflate_insufficient_space
    else
        return nothing
    end
end

function _unsafe_decompress!(
        ::Base.HasLength,
        decompressor::Decompressor,
        out::WriteableMemory,
        in::ReadableMemory,
    )::Union{LibDeflateError, @NamedTuple{read::UInt, written::UInt}}
    y = GC.@preserve decompressor begin
        base_ptr = Ptr{UInt8}(pointer_from_objref(decompressor))
        actual_in_ptr = Ptr{Csize_t}(
            base_ptr + fieldoffset(Decompressor, 3)
        )
        _unsafe_decompress!(
            decompressor, out, in, actual_in_ptr, C_NULL
        )
    end
    return if y isa LibDeflateError
        y
    else
        (; read = decompressor.actual_in_nbytes_ret, written = out.len)
    end
end

"""
    unsafe_decompress!(
        ::Decompressor, output::WriteableMemory, input::ReadableMemory,
        [n_out::UInt]
    )::Union{@NamedTuple{read::UInt, written::UInt}, LibDeflateError}

Decompress a DEFLATE stream, reading up to `sizeof(input)` compressed bytes and
writing into `output`. Reading stops at the end of the DEFLATE stream, even if fewer
than `sizeof(input)` bytes have been read.

Without `n_out`, `sizeof(output)` is the available capacity and the function returns
`LibDeflate.deflate_insufficient_space` if the decompressed data does not fit. If the
exact decompressed size is known, pass it as `n_out` to use the faster known-size path.
An incorrect size returns `LibDeflate.deflate_output_too_short` or
`LibDeflate.deflate_insufficient_space`.

On success, return the number of bytes read from `input` and written to `output`.
The referenced memory must remain valid for the duration of the call.

See also: [`decompress!`](@ref)

# Examples:
```jldoctest
julia> compressed =
       b"\\x01\\x0d\\0\\xf2\\xff\\x48\\x65\\x6c\\x6c\\x6f\\x2c\\x20\\x77\\x6f\\x72\\x6c\\x64\\x21";

julia> out = zeros(UInt8, 13);

julia> result = GC.@preserve compressed out begin
           unsafe_decompress!(decompressor, WriteableMemory(out), ReadableMemory(compressed))
       end;

julia> result.written === UInt(13)
true

julia> String(out)
"Hello, world!"
```
"""
function unsafe_decompress!(
        decompressor::Decompressor,
        output::WriteableMemory,
        input::ReadableMemory,
    )::Union{LibDeflateError, @NamedTuple{read::UInt, written::UInt}}
    return _unsafe_decompress!(Base.SizeUnknown(), decompressor, output, input)
end

function unsafe_decompress!(
        decompressor::Decompressor,
        output::WriteableMemory,
        input::ReadableMemory,
        n_out::UInt,
    )::Union{LibDeflateError, @NamedTuple{read::UInt, written::UInt}}
    output.len < n_out && return LibDeflateErrors.deflate_insufficient_space
    exact_output = WriteableMemory(pointer(output), n_out)
    return _unsafe_decompress!(Base.HasLength(), decompressor, exact_output, input)
end

"""
    decompress!(
        ::Decompressor, output, input, [n_out::UInt]
    )::Union{LibDeflateError, @NamedTuple{read::UInt, written::UInt}}

Decompress a DEFLATE payload from the beginning of `input` and write decompressed
data to the beginning of `output`. On success, return the number of bytes read and
written. Reading stops at the end of the DEFLATE stream, so trailing input is left
unread.

If the decompressed size is known, pass it as `n_out`. This is faster, but returns
an error if the size is incorrect.

Custom input and output types can opt in by implementing `ReadableMemory(input)`
and `WriteableMemory(output)`, respectively.

# Examples:
```jldoctest
julia> compressed =
       b"\\x01\\x0d\\0\\xf2\\xff\\x48\\x65\\x6c\\x6c\\x6f\\x2c\\x20\\x77\\x6f\\x72\\x6c\\x64\\x21";

julia> out = zeros(UInt8, 13);

julia> decompress!(decompressor, out, compressed);

julia> String(out)
"Hello, world!"
```
"""
function decompress!(
        decompressor::Decompressor, output, input, n_out::UInt
    )::Union{LibDeflateError, @NamedTuple{read::UInt, written::UInt}}
    return GC.@preserve output input begin
        _decompress!(decompressor, WriteableMemory(output), ReadableMemory(input), n_out)
    end
end

function _decompress!(
        decompressor::Decompressor,
        output::WriteableMemory,
        input::ReadableMemory,
        n_out::UInt,
    )::Union{LibDeflateError, @NamedTuple{read::UInt, written::UInt}}
    return unsafe_decompress!(decompressor, output, input, n_out)
end

function decompress!(
        decompressor::Decompressor, output, input
    )::Union{LibDeflateError, @NamedTuple{read::UInt, written::UInt}}
    return GC.@preserve output input begin
        _decompress!(decompressor, WriteableMemory(output), ReadableMemory(input))
    end
end

function _decompress!(
        decompressor::Decompressor, output::WriteableMemory, input::ReadableMemory
    )::Union{LibDeflateError, @NamedTuple{read::UInt, written::UInt}}
    return unsafe_decompress!(decompressor, output, input)
end

function _unsafe_decompress!(
        ::Base.SizeUnknown,
        decompressor::Decompressor,
        out::WriteableMemory,
        in::ReadableMemory,
    )::Union{LibDeflateError, @NamedTuple{read::UInt, written::UInt}}
    y = GC.@preserve decompressor begin
        base_ptr = Ptr{UInt8}(pointer_from_objref(decompressor))
        actual_out_ptr = Ptr{Csize_t}(
            base_ptr + fieldoffset(Decompressor, 2)
        )
        actual_in_ptr = Ptr{Csize_t}(
            base_ptr + fieldoffset(Decompressor, 3)
        )
        _unsafe_decompress!(
            decompressor,
            out,
            in,
            actual_in_ptr,
            actual_out_ptr,
        )
    end
    return if y isa LibDeflateError
        y
    else
        (;
            read = decompressor.actual_in_nbytes_ret,
            written = decompressor.actual_nbytes_ret,
        )
    end
end

"""
    deflate_compress_bound(compressor::Compressor, input_size::UInt)::UInt

Return a worst-case upper bound on the number of bytes produced by
[`compress!`](@ref) when compressing `input_size` bytes with `compressor`.

The bound may overestimate the required space, but an output buffer of this size is
guaranteed to be sufficient. This calculation does not inspect any input data and is
constant-time with respect to `input_size`.

# Examples:
```jldoctest
julia> bound = deflate_compress_bound(compressor, UInt(1000));

julia> bound >= 1000
true
```
"""
function deflate_compress_bound(compressor::Compressor, input_size::UInt)::UInt
    return GC.@preserve compressor begin
        @ccall gc_safe = true libdeflate.libdeflate_deflate_compress_bound(
            compressor::Ptr{Cvoid}, input_size::Csize_t
        )::Csize_t
    end
end

"""
    unsafe_compress!(
        ::Compressor, out::WriteableMemory, in::ReadableMemory
    )::Union{UInt, LibDeflateError}

Use the passed `Compressor` to compress the bytes in `in` into `out`.

Return the number of written bytes to the output, or a `LibDeflateError`.

See also: [`compress!`](@ref)

# Examples:
```jldoctest
julia> data = b"Hello, world!";

julia> out = zeros(UInt8, deflate_compress_bound(compressor, UInt(sizeof(data))));

julia> n = GC.@preserve data out begin
           unsafe_compress!(compressor, WriteableMemory(out), ReadableMemory(data))
       end;

julia> out[1:n] ==
       b"\\x01\\x0d\\0\\xf2\\xff\\x48\\x65\\x6c\\x6c\\x6f\\x2c\\x20\\x77\\x6f\\x72\\x6c\\x64\\x21"
true
```
"""
function unsafe_compress!(
        compressor::Compressor, out::WriteableMemory, in::ReadableMemory
    )::Union{LibDeflateError, UInt}
    bytes = GC.@preserve compressor begin
        @ccall gc_safe = true libdeflate.libdeflate_deflate_compress(
            compressor::Ptr{Cvoid},
            pointer(in)::Ptr{UInt8},
            in.len::Csize_t,
            pointer(out)::Ptr{UInt8},
            out.len::Csize_t
        )::Csize_t
    end
    iszero(bytes) && return LibDeflateErrors.deflate_insufficient_space
    return bytes
end

"""
    compress!(::Compressor, output, input)::Union{LibDeflateError, UInt}

Compress `input` as a DEFLATE payload into the beginning of `output`, returning
the number of bytes written or a `LibDeflateError`.

Custom input and output types can opt in by implementing `ReadableMemory(input)`
and `WriteableMemory(output)`, respectively.

# Examples:
```jldoctest
julia> data = b"Hello, world!";

julia> out = zeros(UInt8, deflate_compress_bound(compressor, UInt(sizeof(data))));

julia> n = compress!(compressor, out, data);

julia> out[1:n] ==
       b"\\x01\\x0d\\0\\xf2\\xff\\x48\\x65\\x6c\\x6c\\x6f\\x2c\\x20\\x77\\x6f\\x72\\x6c\\x64\\x21"
true
```
"""
function compress!(compressor::Compressor, output, input)::Union{LibDeflateError, UInt}
    return GC.@preserve output input begin
        unsafe_compress!(compressor, WriteableMemory(output), ReadableMemory(input))
    end
end

"""
    unsafe_crc32(in::ReadableMemory, start::UInt32)::UInt32

Calculate the CRC-32 checksum of `in` with seed `start` (default is 0).
Note that crc32 is a different and slower algorithm than the `crc32c` provided
in the Julia standard library.

See also: [`crc32`](@ref)

# Examples:
```jldoctest
julia> data = b"hello world";

julia> GC.@preserve data unsafe_crc32(ReadableMemory(data))
0x0d4a1185
```
"""
function unsafe_crc32(in::ReadableMemory, start::UInt32 = UInt32(0))::UInt32
    return @ccall gc_safe = true libdeflate.libdeflate_crc32(
        start::UInt32, pointer(in)::Ptr{UInt8}, in.len::Csize_t
    )::UInt32
end

"""
    crc32(data, start=UInt32(0))::UInt32

Calculate the CRC-32 checksum of `data` with seed `start`.

# Examples:
```jldoctest
julia> crc32(b"hello world")
0x0d4a1185

julia> crc32(b" world", crc32(b"hello")) == crc32(b"hello world")
true
```
"""
function crc32(data, start::UInt32 = UInt32(0))::UInt32
    return GC.@preserve data unsafe_crc32(ReadableMemory(data), start)
end

"""
    unsafe_adler32(in::ReadableMemory, start=UInt32(1))::UInt32

Calculate the Adler-32 checksum of the bytes in `in`,
with seed `start` (default is 1).

See also: [`adler32`](@ref)

# Examples:
```jldoctest
julia> data = b"hello world";

julia> GC.@preserve data unsafe_adler32(ReadableMemory(data))
0x1a0b045d
```
"""
function unsafe_adler32(in::ReadableMemory, start::UInt32 = UInt32(1))::UInt32
    return @ccall gc_safe = true libdeflate.libdeflate_adler32(
        start::UInt32, pointer(in)::Ptr{UInt8}, in.len::Csize_t
    )::UInt32
end

"""
    adler32(data, start=UInt32(1))::UInt32

Calculate the Adler-32 checksum of `data` with seed `start`.

# Examples:
```jldoctest
julia> adler32(b"hello world")
0x1a0b045d

julia> adler32(b" world", adler32(b"hello")) == adler32(b"hello world")
true
```
"""
function adler32(data, start::UInt32 = UInt32(1))::UInt32
    return GC.@preserve data unsafe_adler32(ReadableMemory(data), start)
end

include("gzip.jl")
include("zlib.jl")

export Decompressor,
    Compressor,
    LibDeflateErrors,
    LibDeflateError,
    GzipHeader,
    GzipExtraField,
    GzipDecompressResult,
    GzipDecompressAllScratch,
    GzipDecompressAllResult,
    NonZeroUInt32,
    WriteableMemory,
    ReadableMemory,
    unsafe_decompress!,
    decompress!,
    unsafe_compress!,
    compress!,
    deflate_compress_bound,
    unsafe_gzip_decompress!,
    gzip_decompress!,
    unsafe_gzip_decompress_all!,
    gzip_decompress_all!,
    unsafe_gzip_compress!,
    gzip_compress!,
    gzip_compress_bound,
    unsafe_zlib_decompress!,
    zlib_decompress!,
    unsafe_zlib_compress!,
    zlib_compress!,
    zlib_compress_bound,
    unsafe_crc32,
    crc32,
    unsafe_adler32,
    adler32,
    unsafe_parse_gzip_header,
    parse_gzip_header,
    unsafe_is_valid_extra_data,
    is_valid_extra_data

end # module
