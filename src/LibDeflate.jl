module LibDeflate

using Base: FastContiguousSubArray
using libdeflate_jll

"""
    Module LibDeflateErrors

Dummy module to contain the variants of the `LibDeflateError` enum.
"""
module LibDeflateErrors

    @enum LibDeflateError::UInt8 begin
        overflow
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

const MutableDenseByteSubArray = SubArray{UInt8, N, <:Union{Array, Memory}, I, true} where {
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
so must be used with `GC.@preserve`. This type can be constructed from `Vector{UInt8}`,
`Memory{UInt8}`, and some subtypes of `SubArray`. It may also be directly constructed
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

function WriteableMemory(x::MutableDenseByteSubArray)
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
function ReadableMemory(x::Base.CodeUnits{UInt8, <:Union{String, SubString{String}}})
    return unsafe_readable_memory(pointer(x), length(x) % UInt)
end


ReadableMemory(x::ReadableMemory) = x
ReadableMemory(x::WriteableMemory) = unsafe_readable_memory(x.ptr, x.len)

function ReadableMemory(x::Union{Array{UInt8}, Memory{UInt8}})
    return unsafe_readable_memory(pointer(x), length(x) % UInt)
end

function ReadableMemory(x::Union{DenseByteSubArray, DenseArray{UInt8}})
    return unsafe_readable_memory(pointer(x), UInt(length(x)))
end

Base.pointer(x::Union{ReadableMemory, WriteableMemory})::Ptr{Nothing} = x.ptr

# Note: In constructors, we enforce x.len fits in an Int, so this truncate cannot overflow
Base.sizeof(x::Union{ReadableMemory, WriteableMemory})::Int = x.len % Int

# Must be mutable for the GC to be able to interact with it
"""
    Decompressor()

Create an object which can decompress using the DEFLATE algorithm.

Creating this object allocates, so when decompressing multiple blocks, keep
the same decompressor in memory rather than making one for each block.
If the C library fails to allocate this object, an `OutOfMemory` error is thrown.

!!! warning
    `Decompressor` is not thread safe, and therefore should not be used by
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
        # The C library returns a null pointer on failure to allocate
        ptr == C_NULL && throw(OutOfMemoryError())
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
    Compressor(compresslevel::UInt8=$(repr(DEFAULT_COMPRESSION_LEVEL)))

Create an object which can compress using the DEFLATE algorithm. `compresslevel`
can be from 1 (fast) to 12 (slow), and defaults to $(repr(DEFAULT_COMPRESSION_LEVEL)).

Creating this object allocates, so when compressing multiple blocks, keep
the same compressor in memory rather than making one for each block.
If the C library fails to allocate this object, an `OutOfMemory` error is thrown.

!!! warning
    `Compressor` is not thread safe, and therefore should not be used by
    different tasks concurrently. Concurrent use may cause undefined behaviour.

See also: [`compress!`](@ref), [`unsafe_compress!`](@ref)

# Examples:
```jldoctest
julia> compressor = Compressor();

julia> data = b"Hello, world!";

julia> out = zeros(UInt8, deflate_compress_bound(compressor, UInt(sizeof(data))));

julia> n = compress!(compressor, out, data);

julia> roundtrip = zeros(UInt8, sizeof(data));

julia> decompress!(Decompressor(), roundtrip, view(out, 1:n), UInt(sizeof(data)));

julia> roundtrip == data
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
        # The C library returns a null pointer on failure to allocate
        ptr == C_NULL && throw(OutOfMemoryError())
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

Low-level variant of [`decompress!`](@ref) that operates directly on
`WriteableMemory` and `ReadableMemory`. It has the same decompression behavior, return
values, and errors as `decompress!`.

The caller must keep the allocations referenced by `output` and `input` alive, typically
by wrapping both construction of the memory wrappers and this call in `GC.@preserve`.
The memory regions referenced by `output` and `input` must not overlap (alias).

See also: [`decompress!`](@ref)
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

Decompress a DEFLATE stream, reading from the beginning of `input` and writing
decompressed data to the beginning of `output`. Reading stops at the end of the
DEFLATE stream, so trailing input is left unread. On success, return the number of
bytes read and written; on error, return a `LibDeflateError`.

The function returns `LibDeflateErrors.deflate_insufficient_space` if the decompressed data
does not fit. If the exact decompressed size is known, pass it as `n_out` to use the
faster known-size path. An incorrect size returns
`LibDeflateErrors.deflate_output_too_short` or
`LibDeflateErrors.deflate_insufficient_space`.

`ReadableMemory(input)` and `WriteableMemory(output)` are constructed safely by
preserving both arguments from garbage collection for the duration of the call. Custom
input and output types can opt in by implementing those constructors. This function does
not check whether the input and output memory regions overlap (alias); the caller must
ensure that they do not.

See also: [`unsafe_decompress!`](@ref)

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
    deflate_compress_bound(compressor::Compressor, input_size::UInt)::Union{LibDeflateError, UInt}

Return a worst-case upper bound on the number of bytes produced by
[`compress!`](@ref) when compressing `input_size` bytes with `compressor`.
This is generally slightly larger than `input_size`.

The bound may overestimate the required space, but an output buffer of this size is
guaranteed to be sufficient. This calculation is constant-time with respect to `input_size`.
Returns `LibDeflateErrors.overflow` if the bound cannot be represented as a `UInt`.

# Examples:
```jldoctest
julia> bound = deflate_compress_bound(compressor, UInt(1000));

julia> bound >= 1000
true
```
"""
function deflate_compress_bound(
        compressor::Compressor, input_size::UInt
    )::Union{LibDeflateError, UInt}
    bound = GC.@preserve compressor begin
        @ccall gc_safe = true libdeflate.libdeflate_deflate_compress_bound(
            compressor::Ptr{Cvoid}, input_size::Csize_t
        )::Csize_t
    end
    return bound < input_size ? LibDeflateErrors.overflow : bound
end

"""
    unsafe_compress!(
        ::Compressor, out::WriteableMemory, in::ReadableMemory
    )::Union{UInt, LibDeflateError}

Low-level variant of [`compress!`](@ref) that operates directly on `WriteableMemory`
and `ReadableMemory`. It has the same compression behavior, return value, and errors as
`compress!`.

The caller must keep the allocations referenced by `out` and `in` alive, typically by
wrapping both construction of the memory wrappers and this call in `GC.@preserve`.
The memory regions referenced by `out` and `in` must not overlap (alias).

See also: [`compress!`](@ref)
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
the number of bytes written or `LibDeflateErrors.deflate_insufficient_space` if the
output is too small. The output is never resized.

`ReadableMemory(input)` and `WriteableMemory(output)` are constructed safely by
preserving both arguments from garbage collection for the duration of the call. Custom
input and output types can opt in by implementing those constructors. This function does
not check whether the input and output memory regions overlap (alias); the caller must
ensure that they do not.

See also: [`unsafe_compress!`](@ref)

# Examples:
```jldoctest
julia> data = b"Hello, world!";

julia> out = zeros(UInt8, deflate_compress_bound(compressor, UInt(sizeof(data))));

julia> n = compress!(compressor, out, data);

julia> roundtrip = zeros(UInt8, sizeof(data));

julia> decompress!(decompressor, roundtrip, view(out, 1:n), UInt(sizeof(data)));

julia> roundtrip == data
true
```
"""
function compress!(compressor::Compressor, output, input)::Union{LibDeflateError, UInt}
    return GC.@preserve output input begin
        unsafe_compress!(compressor, WriteableMemory(output), ReadableMemory(input))
    end
end

"""
    unsafe_crc32(in::ReadableMemory, start::UInt32=UInt32(0))::UInt32

Low-level variant of [`crc32`](@ref) that operates directly on `ReadableMemory` and has
the same checksum behavior. The caller must keep the allocation referenced by `in`
alive, typically by wrapping both construction of the memory wrapper and this call in
`GC.@preserve`.

See also: [`crc32`](@ref)
"""
function unsafe_crc32(in::ReadableMemory, start::UInt32 = UInt32(0))::UInt32
    return @ccall gc_safe = true libdeflate.libdeflate_crc32(
        start::UInt32, pointer(in)::Ptr{UInt8}, in.len::Csize_t
    )::UInt32
end

"""
    crc32(data, start::UInt32=UInt32(0))::UInt32

Calculate the CRC-32 checksum of `data` with seed `start`.
Note that CRC-32 is a different and slower algorithm than the `crc32c` provided
in the Julia standard library.

`ReadableMemory(data)` is constructed safely by preserving `data` from garbage
collection for the duration of the call. Custom input types can opt in by implementing
that constructor.

See also: [`unsafe_crc32`](@ref)

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
    unsafe_adler32(in::ReadableMemory, start::UInt32=UInt32(1))::UInt32

Low-level variant of [`adler32`](@ref) that operates directly on `ReadableMemory` and
has the same checksum behavior. The caller must keep the allocation referenced by `in`
alive, typically by wrapping both construction of the memory wrapper and this call in
`GC.@preserve`.

See also: [`adler32`](@ref)
"""
function unsafe_adler32(in::ReadableMemory, start::UInt32 = UInt32(1))::UInt32
    return @ccall gc_safe = true libdeflate.libdeflate_adler32(
        start::UInt32, pointer(in)::Ptr{UInt8}, in.len::Csize_t
    )::UInt32
end

"""
    adler32(data, start::UInt32=UInt32(1))::UInt32

Calculate the Adler-32 checksum of `data` with seed `start`.

`ReadableMemory(data)` is constructed safely by preserving `data` from garbage
collection for the duration of the call. Custom input types can opt in by implementing
that constructor.

See also: [`unsafe_adler32`](@ref)

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
