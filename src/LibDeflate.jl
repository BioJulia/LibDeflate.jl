"""
    Module LibDeflate

`LibDeflate` provides Julia bindings for the C library `libdeflate`. The C library,
and the corresponding Julia package, contain highly optimized code for compressing and
uncompressing data using the DEFLATE algorithm, including gzip, or zlib formats.
"""
module LibDeflate

using libdeflate_jll

# Alias Base unions to avoid relying on internals
const BitInteger = Union{Int128, Int16, Int32, Int64, Int8, UInt128, UInt16, UInt32, UInt64, UInt8}
const IEEEFloat = Union{Float16, Float32, Float64}

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
    Successful operations will never return a `LibDeflateError`.
    """
    LibDeflateError

    export LibDeflateError
end # module

using .LibDeflateErrors

const DEFAULT_COMPRESSION_LEVEL = 6

"""
    WriteableMemory

Struct that wraps a pointer and a length. This struct is not garbage-collector aware,
so must be used with `GC.@preserve`. This can be constructed from types that are
pointer-writeable, including contiguous dense arrays of integers and IEEE floats.
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
end


# We can only write to types where we know they are mutable, that
# `pointer` and `sizeof` are correct (unlike e.g. subarrays with non-1-strides),
# and where all bitpatterns are legal values.
function WriteableMemory(x::DenseArray{T}) where {T <: Union{BitInteger, IEEEFloat}}
    return WriteableMemory(pointer(x), sizeof(x))
end

function WriteableMemory(
        x::SubArray{T, N, P, I, true}
    ) where {
        T <: Union{BitInteger, IEEEFloat},
        N,
        P,
        I <: Union{Tuple{Vararg{Real}}, Tuple{AbstractUnitRange, Vararg{Any}}},
    }
    return WriteableMemory(pointer(x), sizeof(x))
end
WriteableMemory(x::WriteableMemory) = x

"""
    ReadableMemory

Struct that wraps a pointer and a length. This struct is not garbage-collector aware,
so must be used with `GC.@preserve`. This can be constructed from types that are
pointer-readable, including strings and contiguous dense arrays of integers and IEEE
floats. Arrays of arbitrary bitstypes are deliberately unsupported because their
representations may contain padding.
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
end

function ReadableMemory(x::DenseArray{T}) where {T <: Union{BitInteger, IEEEFloat}}
    return ReadableMemory(pointer(x), sizeof(x))
end

function ReadableMemory(
        x::SubArray{T, N, P, I, true}
    ) where {
        T <: Union{BitInteger, IEEEFloat},
        N,
        P,
        I <: Union{Tuple{Vararg{Real}}, Tuple{AbstractUnitRange, Vararg{Any}}},
    }
    return ReadableMemory(pointer(x), sizeof(x))
end

function ReadableMemory(x::Union{String, SubString{String}})
    return ReadableMemory(pointer(x), sizeof(x))
end

ReadableMemory(x::WriteableMemory) = ReadableMemory(pointer(x), sizeof(x))
ReadableMemory(x::ReadableMemory) = x

Base.pointer(x::Union{ReadableMemory, WriteableMemory})::Ptr{Nothing} = x.ptr
Base.sizeof(x::Union{ReadableMemory, WriteableMemory})::Int = x.len % Int

# Must be mutable for the GC to be able to interact with it
"""
    Decompressor()

Create an object which can decompress using the DEFLATE algorithm.
The same decompressor cannot be used by multiple threads at the same time.
To parallelize decompression, create multiple instances of `Decompressor`
and use one for each thread.
Creating this object allocates, so when decompressing multiple blocks, keep
the same decompressor in memory rather than making one for each block.

See also: [`decompress!`](@ref), [`unsafe_decompress!`](@ref)
"""
mutable struct Decompressor
    actual_nbytes_ret::UInt
    actual_in_nbytes_ret::UInt
    ptr::Ptr{Nothing}
end

Base.unsafe_convert(::Type{Ptr{Nothing}}, x::Decompressor) = x.ptr

function Decompressor()
    decompressor = Decompressor(
        0, 0, ccall((:libdeflate_alloc_decompressor, libdeflate), Ptr{Nothing}, ())
    )
    finalizer(free_decompressor, decompressor)
    return decompressor
end

function free_decompressor(decompressor::Decompressor)
    ccall(
        (:libdeflate_free_decompressor, libdeflate), Nothing, (Ptr{Nothing},), decompressor
    )
    return nothing
end

"""
    Compressor(compresslevel::Int=$(DEFAULT_COMPRESSION_LEVEL))

Create an object which can compress using the DEFLATE algorithm. `compresslevel`
can be from 1 (fast) to 12 (slow), and defaults to $(DEFAULT_COMPRESSION_LEVEL).
The same compressor cannot be used by multiple threads at the same time.
To parallelize compression, create multiple instances of `Compressor` and use one for each thread.
Creating this object allocates, so when compressing multiple blocks, keep
the same compressor in memory rather than making one for each block.

See also: [`compress!`](@ref), [`unsafe_compress!`](@ref)
"""
mutable struct Compressor
    level::Int
    ptr::Ptr{Nothing}
end

Base.unsafe_convert(::Type{Ptr{Nothing}}, x::Compressor) = x.ptr

function Compressor(compresslevel::Integer = DEFAULT_COMPRESSION_LEVEL)
    compresslevel in 1:12 || throw(ArgumentError("Compresslevel must be in 1:12"))
    ptr = ccall(
        (:libdeflate_alloc_compressor, libdeflate), Ptr{Nothing}, (Cint,), compresslevel
    )
    compressor = Compressor(compresslevel, ptr)
    finalizer(free_compressor, compressor)
    return compressor
end

# Called by the garbage collecter, do not use manually
function free_compressor(compressor::Compressor)
    ccall((:libdeflate_free_compressor, libdeflate), Nothing, (Ptr{Nothing},), compressor)
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
    status = ccall(
        (:libdeflate_deflate_decompress_ex, libdeflate),
        Cint,
        (
            Ptr{Nothing},
            Ptr{UInt8},
            Csize_t,
            Ptr{UInt8},
            Csize_t,
            Ptr{Csize_t},
            Ptr{Csize_t},
        ),
        decompressor,
        pointer(in),
        sizeof(in),
        pointer(out),
        sizeof(out),
        actual_in_nbytes_ret,
        actual_out_nbytes_ret,
    )
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
    )::Union{LibDeflateError, @NamedTuple{read::Int, written::Int}}
    y = GC.@preserve decompressor begin
        base_ptr = Ptr{UInt8}(pointer_from_objref(decompressor))
        actual_in_ptr = Ptr{Csize_t}(
            base_ptr + fieldoffset(Decompressor, 2)
        )
        _unsafe_decompress!(
            decompressor, out, in, actual_in_ptr, C_NULL
        )
    end
    return if y isa LibDeflateError
        y
    else
        (; read = decompressor.actual_in_nbytes_ret % Int, written = sizeof(out))
    end
end

"""
    unsafe_decompress!(
        ::Decompressor, output::WriteableMemory, input::ReadableMemory,
        [n_out::Integer]
    )::Union{@NamedTuple{read::Int, written::Int}, LibDeflateError}

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
"""
function unsafe_decompress!(
        decompressor::Decompressor,
        output::WriteableMemory,
        input::ReadableMemory,
    )::Union{LibDeflateError, @NamedTuple{read::Int, written::Int}}
    return _unsafe_decompress!(Base.SizeUnknown(), decompressor, output, input)
end

function unsafe_decompress!(
        decompressor::Decompressor,
        output::WriteableMemory,
        input::ReadableMemory,
        n_out::Integer,
    )::Union{LibDeflateError, @NamedTuple{read::Int, written::Int}}
    sizeof(output) < n_out && return LibDeflateErrors.deflate_insufficient_space
    exact_output = WriteableMemory(pointer(output), n_out % UInt)
    return _unsafe_decompress!(Base.HasLength(), decompressor, exact_output, input)
end

"""
    decompress!(
        ::Decompressor, output, input, [n_out::Integer]
    )::Union{LibDeflateError, @NamedTuple{read::Int, written::Int}}

Decompress a DEFLATE payload from the beginning of `input` and write decompressed
data to the beginning of `output`. On success, return the number of bytes read and
written. Reading stops at the end of the DEFLATE stream, so trailing input is left
unread.

If the decompressed size is known, pass it as `n_out`. This is faster, but returns
an error if the size is incorrect.

Custom input and output types can opt in by implementing `ReadableMemory(input)`
and `WriteableMemory(output)`, respectively.
"""
function decompress!(decompressor::Decompressor, output, input, n_out::Integer)
    return GC.@preserve output input begin
        _decompress!(decompressor, WriteableMemory(output), ReadableMemory(input), n_out)
    end
end

function _decompress!(
        decompressor::Decompressor,
        output::WriteableMemory,
        input::ReadableMemory,
        n_out::Integer,
    )::Union{LibDeflateError, @NamedTuple{read::Int, written::Int}}
    return unsafe_decompress!(decompressor, output, input, n_out)
end

function decompress!(decompressor::Decompressor, output, input)
    return GC.@preserve output input begin
        _decompress!(decompressor, WriteableMemory(output), ReadableMemory(input))
    end
end

function _decompress!(
        decompressor::Decompressor, output::WriteableMemory, input::ReadableMemory
    )::Union{LibDeflateError, @NamedTuple{read::Int, written::Int}}
    return unsafe_decompress!(decompressor, output, input)
end

function _unsafe_decompress!(
        ::Base.SizeUnknown,
        decompressor::Decompressor,
        out::WriteableMemory,
        in::ReadableMemory,
    )::Union{LibDeflateError, @NamedTuple{read::Int, written::Int}}
    y = GC.@preserve decompressor begin
        base_ptr = Ptr{UInt8}(pointer_from_objref(decompressor))
        actual_out_ptr = Ptr{Csize_t}(
            base_ptr + fieldoffset(Decompressor, 1)
        )
        actual_in_ptr = Ptr{Csize_t}(
            base_ptr + fieldoffset(Decompressor, 2)
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
            read = decompressor.actual_in_nbytes_ret % Int,
            written = decompressor.actual_nbytes_ret % Int,
        )
    end
end

"""
    deflate_compress_bound(compressor::Compressor, input_size::Int)::Int

Return a worst-case upper bound on the number of bytes produced by
[`compress!`](@ref) when compressing `input_size` bytes with `compressor`.

The bound may overestimate the required space, but an output buffer of this size is
guaranteed to be sufficient. This calculation does not inspect any input data and is
constant-time with respect to `input_size`.
"""
function deflate_compress_bound(compressor::Compressor, input_size::Int)::Int
    input_size >= 0 || throw(ArgumentError("input_size must be nonnegative"))
    return ccall(
        (:libdeflate_deflate_compress_bound, libdeflate),
        Csize_t,
        (Ptr{Nothing}, Csize_t),
        compressor,
        input_size,
    ) % Int
end

"""
    unsafe_compress!(
        ::Compressor, out::WriteableMemory, in::ReadableMemory
    )::Union{Int, LibDeflateError}

Use the passed `Compressor` to compress the bytes in `in` into `out`.

Return the number of written bytes to the output, or a `LibDeflateError`.

See also: [`compress!`](@ref)
"""
function unsafe_compress!(
        compressor::Compressor, out::WriteableMemory, in::ReadableMemory
    )::Union{LibDeflateError, Int}
    bytes = ccall(
        (:libdeflate_deflate_compress, libdeflate),
        Csize_t,
        (Ptr{Nothing}, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
        compressor,
        pointer(in),
        sizeof(in),
        pointer(out),
        sizeof(out),
    )
    iszero(bytes) && return LibDeflateErrors.deflate_insufficient_space
    return bytes % Int
end

"""
    compress!(::Compressor, output, input)::Union{LibDeflateError, Int}

Compress `input` as a DEFLATE payload into the beginning of `output`, returning
the number of bytes written or a `LibDeflateError`.

Custom input and output types can opt in by implementing `ReadableMemory(input)`
and `WriteableMemory(output)`, respectively.
"""
function compress!(compressor::Compressor, output, input)
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
"""
function unsafe_crc32(in::ReadableMemory, start::UInt32 = UInt32(0))
    return ccall(
        (:libdeflate_crc32, libdeflate),
        UInt32,
        (UInt32, Ptr{UInt8}, Csize_t),
        start,
        pointer(in),
        sizeof(in),
    )
end

"""
    crc32(data, start=UInt32(0))::UInt32

Calculate the CRC-32 checksum of `data` with seed `start`.
"""
function crc32(data, start::UInt32 = UInt32(0))
    return GC.@preserve data unsafe_crc32(ReadableMemory(data), start)
end

"""
    unsafe_adler32(in::ReadableMemory, start=UInt32(1))::UInt32

Calculate the Adler-32 checksum of the bytes in `in`,
with seed `start` (default is 1).

See also: [`adler32`](@ref)
"""
function unsafe_adler32(in::ReadableMemory, start::UInt32 = UInt32(1))
    return ccall(
        (:libdeflate_adler32, libdeflate),
        UInt32,
        (UInt32, Ptr{UInt8}, Csize_t),
        start,
        pointer(in),
        sizeof(in),
    )
end

"""
    adler32(data, start=UInt32(1))::UInt32

Calculate the Adler-32 checksum of `data` with seed `start`.
"""
function adler32(data, start::UInt32 = UInt32(1))
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
