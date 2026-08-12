# Single-line boxes show the number of bytes, double-lined have
# a variable number of bytes. E.g. here: 1, 1, N, 4.
# +---+---+===============+---+---+---+---+
# |CMF|FLG|COMPRESSED DATA|     ADLER32   |
# +---+---+===============+---+---+---+---+

"""
    zlib_decompress!(
        ::Decompressor, output, input, [n_out::Integer]
    )::Union{LibDeflateError, Int}

Zlib decompress from `input` to `output`.
If the precise number of decompressed bytes is known, pass it in as `n_out`
for added performance. If it is wrong, the function will return an error.

Return the number of bytes written, or a `LibDeflateError`.

See also: [`unsafe_zlib_decompress!`](@ref)
"""
function zlib_decompress! end

function zlib_decompress!(
        decompressor::Decompressor, output, input
    )::Union{LibDeflateError, Int}
    return GC.@preserve output input begin
        write = WriteableMemory(output)
        read = ReadableMemory(input)
        unsafe_zlib_decompress!(
            Base.SizeUnknown(),
            decompressor,
            pointer(write),
            sizeof(write),
            pointer(read),
            sizeof(read),
        )
    end
end

function zlib_decompress!(
        decompressor::Decompressor, output, input, n_out::Integer
    )::Union{LibDeflateError, Int}
    return GC.@preserve output input begin
        write = WriteableMemory(output)
        read = ReadableMemory(input)
        n_out > sizeof(write) && return LibDeflateErrors.deflate_insufficient_space
        unsafe_zlib_decompress!(
            Base.HasLength(),
            decompressor,
            pointer(write),
            n_out,
            pointer(read),
            sizeof(read),
        )
    end
end

"""
    unsafe_zlib_decompress!(
        size::Union{Base.SizeUnknown, Base.HasLength},
        ::Decompressor,
        out_ptr::Ptr, n_out::Integer,
        in_ptr::Ptr, len::Integer
    )::Union{LibDeflateError, Int}

Zlib decompress data beginning at `in_ptr` and `len` bytes onwards, into `out_ptr`.
Return the number of bytes written, or a `LibDeflateError`.
`size`` can be `SizeUnknown` or `HasLength`. If the former, `n_out` tells how much space
is available at the output. If the latter, `n_out` is the exact number of bytes
that the payload decompresses to. The latter is faster.

See also: [`zlib_decompress!`](@ref)
"""
function unsafe_zlib_decompress!(
        size::Union{Base.SizeUnknown, Base.HasLength},
        decompressor::Decompressor,
        out_ptr::Ptr,
        n_out::Integer,
        in_ptr::Ptr,
        len::Integer,
    )::Union{LibDeflateError, Int}
    # Must be at least 6 bytes in length + compressed
    len < 6 && return LibDeflateErrors.zlib_input_too_short

    ptr = in_ptr
    header = ltoh(unsafe_load(Ptr{UInt16}(ptr)))
    ptr += 2

    # Parse CMF: First 4 bits must be 0x8 = DEFLATE algorithm
    header & 0x000f != 0x0008 && return LibDeflateErrors.zlib_not_deflate

    # CINFO values 0 through 7 declare window sizes from 256 bytes through 32 KiB.
    # Values above 7 are not valid for the DEFLATE compression method.
    header & 0x00f0 > 0x0070 && return LibDeflateErrors.zlib_wrong_window_size

    # libdeflate does not support a custom decompression dict, I think
    header & 0x2000 != 0x0000 && return LibDeflateErrors.zlib_needs_compression_dict

    # This is ntoh, because the header checksum is interpreted as a big-endian integer.
    iszero(mod(ntoh(header), UInt16(31))) || return LibDeflateErrors.zlib_bad_header_check

    # Decompress payload
    compressed_len = len - 6
    decomp_result = unsafe_decompress_ex!(
        size, decompressor, out_ptr, n_out, ptr, compressed_len
    )
    decomp_result isa LibDeflateError && return decomp_result
    consumed, nbytes = decomp_result
    consumed == compressed_len || return LibDeflateErrors.deflate_bad_payload

    # Then check adler32, also stored as big-endian
    exp_adler32 = ntoh(unsafe_load(Ptr{UInt32}(in_ptr) + len - 4))
    obs_adler32 = unsafe_adler32(out_ptr, nbytes)
    obs_adler32 == exp_adler32 || return LibDeflateErrors.zlib_bad_adler32

    return nbytes
end

"""
    zlib_compress!(
        ::Compressor, output, input
    )::Union{LibDeflateError, Int}

Zlib compress from `input` to `output`.
Return the number of bytes written, or a `LibDeflateError`.

See also: [`unsafe_zlib_compress!`](@ref)
"""
function zlib_compress!(compressor::Compressor, output, input)::Union{LibDeflateError, Int}
    return GC.@preserve output input begin
        write = WriteableMemory(output)
        read = ReadableMemory(input)
        unsafe_zlib_compress!(
            compressor, pointer(write), sizeof(write), pointer(read), sizeof(read)
        )
    end
end

"""
    unsafe_zlib_compress!(
        ::Compressor,
        out_ptr::Ptr, max_outlen::Integer,
        in_ptr::Ptr, len::Integer
    )::Union{LibDeflateError, Int}

Zlib compress data beginning at `in_ptr` and `len` bytes onwards, into `out_ptr`.
Return the number of bytes written, or a `LibDeflateError`.

See also: [`zlib_compress!`](@ref)
"""
function unsafe_zlib_compress!(
        compressor::Compressor, out_ptr::Ptr, max_outlen::Integer, in_ptr::Ptr, len::Integer
    )::Union{LibDeflateError, Int}
    max_outlen < 6 && return LibDeflateErrors.zlib_insufficient_space
    # Be sure to check that all these 4 results are zero mod 31 when big-endian ordered
    header = if compressor.level == 1
        0x0178
    elseif compressor.level == DEFAULT_COMPRESSION_LEVEL
        0x5e78
    elseif compressor.level == 12
        0xda78
    else
        0x9c78
    end
    unsafe_store!(Ptr{UInt16}(out_ptr), htol(header))
    out_ptr += 2
    n_bytes = unsafe_compress!(compressor, out_ptr, max_outlen - 6, in_ptr, len)
    n_bytes isa LibDeflateError && return n_bytes
    out_ptr += n_bytes
    # Alder32 is also big-endian stored
    unsafe_store!(Ptr{UInt32}(out_ptr), hton(unsafe_adler32(in_ptr, len)))
    return n_bytes + 6
end
