# Single-line boxes show the number of bytes, double-lined have
# a variable number of bytes. E.g. here: 1, 1, N, 4.
# +---+---+===============+---+---+---+---+
# |CMF|FLG|COMPRESSED DATA|     ADLER32   |
# +---+---+===============+---+---+---+---+

"""
    unsafe_zlib_decompress!(
        ::Decompressor, output::WriteableMemory, input::ReadableMemory,
        [n_out::UInt]
    )::Union{LibDeflateError, UInt}

Low-level variant of [`zlib_decompress!`](@ref) that operates directly on
`WriteableMemory` and `ReadableMemory`. It has the same decompression behavior, return
value, and errors as `zlib_decompress!`.

The caller must keep the allocations referenced by `output` and `input` alive, typically
by wrapping both construction of the memory wrappers and this call in `GC.@preserve`.
The memory regions referenced by `output` and `input` must not overlap (alias).

See also: [`zlib_decompress!`](@ref)
"""
function unsafe_zlib_decompress!(
        decompressor::Decompressor,
        output::WriteableMemory,
        input::ReadableMemory,
    )::Union{LibDeflateError, UInt}
    return _unsafe_zlib_decompress!(Base.SizeUnknown(), decompressor, output, input)
end

function unsafe_zlib_decompress!(
        decompressor::Decompressor,
        output::WriteableMemory,
        input::ReadableMemory,
        n_out::UInt,
    )::Union{LibDeflateError, UInt}
    output.len < n_out && return LibDeflateErrors.insufficient_output_space
    exact_output = WriteableMemory(pointer(output), n_out)
    return _unsafe_zlib_decompress!(
        Base.HasLength(), decompressor, exact_output, input
    )
end

function _unsafe_zlib_decompress!(
        size::Union{Base.SizeUnknown, Base.HasLength},
        decompressor::Decompressor,
        output::WriteableMemory,
        input::ReadableMemory,
    )::Union{LibDeflateError, UInt}
    # Two header bytes, at least an empty DEFLATE payload, and four checksum bytes.
    input.len < UInt(6) && return LibDeflateErrors.input_too_short

    input_ptr = Ptr{UInt8}(pointer(input))
    header = ltoh(unsafe_load(Ptr{UInt16}(input_ptr)))

    # CMF: the low nibble is the DEFLATE compression method.
    header & 0x000f != 0x0008 && return LibDeflateErrors.not_deflate

    # CINFO values 0 through 7 declare windows from 256 bytes through 32 KiB.
    header & 0x00f0 > 0x0070 && return LibDeflateErrors.zlib_bad_window_size

    # libdeflate does not support preset dictionaries.
    header & 0x2000 != 0x0000 && return LibDeflateErrors.zlib_dictionary_required

    # `header` is little-endian in memory, while the zlib check uses big-endian order.
    iszero(mod(bswap(header), UInt16(31))) ||
        return LibDeflateErrors.zlib_bad_header_checksum

    compressed = ReadableMemory(input_ptr + 2, input.len - UInt(2))
    decomp_result = _unsafe_decompress!(size, decompressor, output, compressed)
    decomp_result isa LibDeflateError && return decomp_result

    read = decomp_result.read
    written = decomp_result.written
    remaining = input.len - UInt(2) - read
    remaining < UInt(4) && return LibDeflateErrors.input_too_short
    remaining > UInt(4) && return LibDeflateErrors.zlib_trailing_data

    expected_adler32 = ntoh(
        unsafe_load(Ptr{UInt32}(input_ptr + UInt(2) + read))
    )
    checksum_input = ReadableMemory(pointer(output), written)
    unsafe_adler32(checksum_input) == expected_adler32 ||
        return LibDeflateErrors.zlib_bad_adler32

    return written
end

"""
    zlib_decompress!(
        ::Decompressor, output, input, [n_out::UInt]
    )::Union{LibDeflateError, UInt}

Decompress `input` as a zlib stream into `output`. If the exact decompressed size is
known, pass it as `n_out` to use the faster known-size path. Return the number of bytes
written or a `LibDeflateError`.

The complete input must contain exactly one zlib stream. Bytes after that stream,
including a second concatenated zlib stream, return `LibDeflateErrors.zlib_trailing_data`.

On error, return a `LibDeflateError`, and leave the content of `output` in an arbitrary
state.

`ReadableMemory(input)` and `WriteableMemory(output)` are constructed safely by
preserving both arguments from garbage collection for the duration of the call. Custom
input and output types can opt in by implementing those constructors. This function does
not check whether the input and output memory regions overlap (alias); the caller must
ensure that they do not.

See also: [`unsafe_zlib_decompress!`](@ref)

# Examples:
```jldoctest
julia> compressed = vcat(
           b"\\x78\\x5e\\x01\\x0d\\0\\xf2\\xff\\x48\\x65\\x6c\\x6c\\x6f",
           b"\\x2c\\x20\\x77\\x6f\\x72\\x6c\\x64\\x21\\x20\\x5e\\x04\\x8a",
       ); # zlib "Hello, world!"

julia> out = zeros(UInt8, 13);

julia> zlib_decompress!(decompressor, out, compressed);

julia> String(out)
"Hello, world!"
```
"""
function zlib_decompress!(
        decompressor::Decompressor, output, input
    )::Union{LibDeflateError, UInt}
    return GC.@preserve output input begin
        _zlib_decompress!(decompressor, WriteableMemory(output), ReadableMemory(input))
    end
end

function _zlib_decompress!(
        decompressor::Decompressor, output::WriteableMemory, input::ReadableMemory
    )::Union{LibDeflateError, UInt}
    return unsafe_zlib_decompress!(decompressor, output, input)
end

function zlib_decompress!(
        decompressor::Decompressor, output, input, n_out::UInt
    )::Union{LibDeflateError, UInt}
    return GC.@preserve output input begin
        _zlib_decompress!(
            decompressor, WriteableMemory(output), ReadableMemory(input), n_out
        )
    end
end

function _zlib_decompress!(
        decompressor::Decompressor,
        output::WriteableMemory,
        input::ReadableMemory,
        n_out::UInt,
    )::Union{LibDeflateError, UInt}
    return unsafe_zlib_decompress!(decompressor, output, input, n_out)
end

"""
    zlib_compress_bound(compressor::Compressor, input_size::UInt)::Union{LibDeflateError, UInt}

Return a worst-case upper bound on the number of bytes produced by
[`zlib_compress!`](@ref) when compressing `input_size` bytes with `compressor`.

The bound may overestimate the required space, but an output buffer of this size is
guaranteed to be sufficient. This calculation does not inspect any input data and is
constant-time with respect to `input_size`. Returns `LibDeflateErrors.overflow` if the
bound cannot be represented as a `UInt`.

# Examples:
```jldoctest
julia> bound = zlib_compress_bound(compressor, UInt(1000));

julia> bound >= 1000
true
```
"""
function zlib_compress_bound(
        compressor::Compressor, input_size::UInt
    )::Union{LibDeflateError, UInt}
    deflate_bound = deflate_compress_bound(compressor, input_size)
    deflate_bound isa LibDeflateError && return deflate_bound
    bound, overflowed = Base.Checked.add_with_overflow(deflate_bound, UInt(6))
    return overflowed ? LibDeflateErrors.overflow : bound
end

"""
    zlib_compress!(::Compressor, output, input)::Union{LibDeflateError, UInt}

Compress `input` as a zlib stream into `output`, returning the number of bytes written.
The output is never resized.
On error, return a `LibDeflateError`, and leave the content of `output` in an arbitrary
state.

`ReadableMemory(input)` and `WriteableMemory(output)` are constructed safely by
preserving both arguments from garbage collection for the duration of the call. Custom
input and output types can opt in by implementing those constructors. This function does
not check whether the input and output memory regions overlap (alias); the caller must
ensure that they do not.

See also: [`unsafe_zlib_compress!`](@ref)

# Examples:
```jldoctest
julia> data = b"Hello, world!";

julia> out = zeros(UInt8, zlib_compress_bound(compressor, UInt(sizeof(data))));

julia> n = zlib_compress!(compressor, out, data);

julia> roundtrip = zeros(UInt8, sizeof(data));

julia> zlib_decompress!(
           decompressor, roundtrip, view(out, 1:n), UInt(sizeof(data)),
       );

julia> roundtrip == data
true
```
"""
function zlib_compress!(
        compressor::Compressor, output, input
    )::Union{LibDeflateError, UInt}
    return GC.@preserve output input begin
        unsafe_zlib_compress!(compressor, WriteableMemory(output), ReadableMemory(input))
    end
end

"""
    unsafe_zlib_compress!(
        ::Compressor, output::WriteableMemory, input::ReadableMemory
    )::Union{LibDeflateError, UInt}

Low-level variant of [`zlib_compress!`](@ref) that operates directly on
`WriteableMemory` and `ReadableMemory`. It has the same compression behavior, return
value, and errors as `zlib_compress!`.

The caller must keep the allocations referenced by `output` and `input` alive, typically
by wrapping both construction of the memory wrappers and this call in `GC.@preserve`.
The memory regions referenced by `output` and `input` must not overlap (alias).

See also: [`zlib_compress!`](@ref)
"""
function unsafe_zlib_compress!(
        compressor::Compressor, output::WriteableMemory, input::ReadableMemory
    )::Union{LibDeflateError, UInt}
    output.len < UInt(6) && return LibDeflateErrors.insufficient_output_space

    # Each header is divisible by 31 when interpreted in big-endian order.
    # This is required for the zlib specification.
    header = if compressor.level ∈ 0x00:0x01
        0x0178 # FLEVEL 0
    elseif compressor.level ∈ 0x02:0x05
        0x5e78 # FLEVEL 1
    elseif compressor.level ∈ 0x06:0x0b
        0x9c78 # FLEVEL 2
    else
        0xda78 # FLEVEL 3
    end

    output_ptr = Ptr{UInt8}(pointer(output))
    unsafe_store!(Ptr{UInt16}(output_ptr), htol(header))
    compressed_output = WriteableMemory(output_ptr + 2, output.len - UInt(6))
    n_bytes = unsafe_compress!(compressor, compressed_output, input)
    n_bytes isa LibDeflateError && return n_bytes

    # Adler-32 is stored in big-endian order after the payload.
    unsafe_store!(Ptr{UInt32}(output_ptr + 2 + n_bytes), hton(unsafe_adler32(input)))
    return n_bytes + UInt(6)
end
