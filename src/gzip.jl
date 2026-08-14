# Returns index of next zero (or error if none is found)
# pointer must point to first byte where the search begins
# This can be SIMD'd but it's way fast anyway.
function bytes_until_zero(p::Ptr{UInt8}, lastindex::UInt32)::Union{UInt32, Nothing}
    pos = @ccall memchr(p::Ptr{UInt8}, 0x00::Cint, UInt(lastindex)::Csize_t)::Ptr{Cchar}
    return pos == C_NULL ? nothing : (pos - p) % UInt32
end

"Check if there are any 0x00 bytes in a block of memory"
function any_zeros(mem::ReadableMemory)::Bool
    return bytes_until_zero(Ptr{UInt8}(pointer(mem)), sizeof(mem) % UInt32) !== nothing
end

# +---+---+---+---+==================================+
# |SI1|SI2|  LEN  |... LEN bytes of subfield data ...|
# +---+---+---+---+==================================+
"""
    GzipExtraField

Data structure for gzip extra data. Fields:

* `tag::NTuple{2, UInt8}` two-byte tag
* `data::Union{Nothing, UnitRange{UInt32}}` location of subfield data in original vector,
or `nothing` if empty.
"""
struct GzipExtraField
    tag::Tuple{UInt8, UInt8} # (SI1, SI2)
    data::Union{Nothing, UnitRange{UInt32}}
end

# The pointer points to the first byte of the first field
function parse_fields!(
        fields::Vector{GzipExtraField},
        ptr::Ptr{UInt8},
        index::UInt32,
        remaining_bytes::UInt16, # Format supports no more than 0xffff bytes here
    )::Union{Vector{GzipExtraField}, LibDeflateError}
    empty!(fields)
    while !iszero(remaining_bytes)
        field = parse_extra_field(ptr, index, remaining_bytes)
        field isa LibDeflateError && return field
        push!(fields, field)

        # We zero the range field on an empty subfield, so we take
        # that possibility into account
        data = field.data
        field_len = data === nothing ? UInt16(0) : length(data) % UInt16
        total_len = field_len + UInt16(4)
        remaining_bytes -= total_len
        ptr += total_len
        index += total_len
    end
    return fields
end

# The pointer points to the first byte of the first field
function parse_fields(ptr::Ptr{UInt8}, index::UInt32, remaining_bytes::UInt16)
    return parse_fields!(GzipExtraField[], ptr, index, remaining_bytes)
end

# The pointer points to the first byte of the extra fields
function parse_extra_field(
        ptr::Ptr{UInt8}, index::UInt32, remaining_bytes::UInt16
    )::Union{GzipExtraField, LibDeflateError}
    remaining_bytes < 4 && return LibDeflateErrors.gzip_extra_too_long
    s1 = unsafe_load(ptr)
    s2 = unsafe_load(ptr + 1)
    iszero(s2) && return LibDeflateErrors.gzip_bad_extra
    field_len = ltoh(unsafe_load(Ptr{UInt16}(ptr + 2)))
    field_len + 4 > remaining_bytes && return LibDeflateErrors.gzip_extra_too_long

    # If the field is empty, we use a Nothing to convey that
    range = if iszero(field_len)
        nothing
    else
        (index + UInt32(4)):(index + UInt32(4) - UInt32(1) + field_len)
    end
    return GzipExtraField((s1, s2), range)
end

"""
    is_valid_extra_data(ptr::Ptr, remaining_bytes::UInt16)::Bool

Check if the chunk of bytes pointed to by `ptr` and `remaining_bytes`
onward represent valid gzip metadata for the "extra" field.
"""
function is_valid_extra_data(ptr::Ptr, remaining_bytes::Integer)::Bool
    rem_bytes = UInt16(remaining_bytes)
    while !iszero(rem_bytes)
        # First four bytes: S1, S2, field_len
        rem_bytes < 4 && return false
        # S2 must not be zero
        iszero(unsafe_load(Ptr{UInt8}(ptr) + 1)) && return false
        field_len = ltoh(unsafe_load(Ptr{UInt16}(ptr + 2)))
        rem_bytes < field_len + 4 && return false
        rem_bytes -= UInt16(4) + field_len
        ptr += 4 + field_len
    end
    return true
end

"""
    GzipHeader

Struct representing a gzip header. It has the following fields:
* `mtime::UInt32`: Modification time of file
* `filename::Union{Nothing, UnitRange{32}}` index of filename in header
* `comment::Union{Nothing, UnitRange{32}}` index of comment in header
* `extra::Union{Nothing, Vector{GzipExtraField}}` Extra gzip fields, if applicable.
"""
struct GzipHeader
    mtime::UInt32
    filename::Union{Nothing, UnitRange{UInt32}}
    comment::Union{Nothing, UnitRange{UInt32}}
    extra::Union{Nothing, Vector{GzipExtraField}}
end

"""
    parse_gzip_header(
        input, extra_data::Union{Vector{GzipExtraField}, Nothing}
    )::Union{LibDeflateError, Tuple{UInt32, GzipHeader}}

Parse the input data, returning a `GzipHeader` object, or a `LibDeflateError`.
The parser will not read more than `max_len` bytes.
If a vector of gzip
extra data is passed, it will not allocate a new vector, but overwrite the given one.
"""
function parse_gzip_header(
        in; extra_data::Union{Vector{GzipExtraField}, Nothing} = nothing
    )::Union{LibDeflateError, Tuple{UInt32, GzipHeader}}
    GC.@preserve in begin
        read = ReadableMemory(in)
        return unsafe_parse_gzip_header(pointer(read), sizeof(read), extra_data)
    end
end

"""
    unsafe_parse_gzip_header(
        in_ptr::Ptr, max_len::Integer,
        extra_data::Union{Vector{GzipExtraField}, Nothing}=nothing
    )

Parse the input data, returning a `GzipHeader` object, or a `LibDeflateError`.
The parser will not read more than `max_len` bytes. If a vector of gzip
extra data is passed, it will not allocate a new vector, but overwrite the given one.
"""
function unsafe_parse_gzip_header(
        in_ptr::Ptr,
        max_len::Integer, # maximum length of header
        extra_data::Union{Vector{GzipExtraField}, Nothing} = nothing,
    )::Union{LibDeflateError, Tuple{UInt32, GzipHeader}}

    # header is at least 10 bytes
    max_len = UInt(max_len)
    max_len > 9 || return LibDeflateErrors.gzip_header_too_short
    # Bytes 1 - 10. Check first four bytes, skip rest
    # +---+---+---+---+---+---+---+---+---+---+
    # |ID1|ID2|CM |FLG|     MTIME     |XFL|OS | (more-->)
    # +---+---+---+---+---+---+---+---+---+---+
    ptr = Ptr{UInt8}(in_ptr) - UInt(1) # zero-indexed pointer
    header = ltoh(unsafe_load(Ptr{UInt32}(ptr + 1)))
    header & 0x0000ffff == 0x00008b1f || return LibDeflateErrors.gzip_bad_magic_bytes
    header & 0x00ff0000 == 0x00080000 || return LibDeflateErrors.gzip_not_deflate
    iszero(header & 0xe0000000) || return LibDeflateErrors.gzip_bad_flags
    FLAG_HCRC = !iszero(header & 0x02000000)
    FLAG_EXTRA = !iszero(header & 0x04000000)
    FLAG_NAME = !iszero(header & 0x08000000)
    FLAG_COMMENT = !iszero(header & 0x10000000)
    mtime = ltoh(unsafe_load(Ptr{UInt32}(ptr + 5)))

    # 32-bit index because this library only works with 32-bit buffers anyway
    # (skip MTIME, XFL, OS), they're not useful anyway
    index = UInt32(11)

    extra = nothing
    if FLAG_EXTRA
        # +---+---+=================================+
        # | XLEN  |...XLEN bytes of "extra field"...| (more-->)
        # +---+---+=================================+
        UInt(index) + UInt(1) <= max_len ||
            return LibDeflateErrors.gzip_header_too_short
        extra_len = ltoh(unsafe_load(Ptr{UInt16}(ptr + index)))
        UInt(extra_len) <= max_len - UInt(index) - UInt(1) ||
            return LibDeflateErrors.gzip_extra_too_long
        extra_vector = if extra_data === nothing
            GzipExtraField[]
        else
            extra_data
        end
        extra = parse_fields!(extra_vector, ptr + index + 2, index + UInt32(2), extra_len)
        extra isa LibDeflateError && return extra
        index += extra_len + UInt32(2)
    end

    filename = nothing
    if FLAG_NAME
        # +=========================================+
        # |...original file name, zero-terminated...| (more-->)
        # +=========================================+
        UInt(index) <= max_len ||
            return LibDeflateErrors.gzip_string_not_null_terminated
        remaining = max_len - UInt(index) + UInt(1)
        until_zero = bytes_until_zero(ptr + index, remaining % UInt32)
        until_zero === nothing && return LibDeflateErrors.gzip_string_not_null_terminated
        zero_pos = index + until_zero
        filename = index:(zero_pos - one(UInt32))
        index = zero_pos + one(UInt32)
    end

    # Skip comment
    comment = nothing
    if FLAG_COMMENT
        UInt(index) <= max_len ||
            return LibDeflateErrors.gzip_string_not_null_terminated
        remaining = max_len - UInt(index) + UInt(1)
        until_zero = bytes_until_zero(ptr + index, remaining % UInt32)
        until_zero === nothing && return LibDeflateErrors.gzip_string_not_null_terminated
        zero_pos = index + until_zero
        comment = index:(zero_pos - one(UInt32))
        index = zero_pos + one(UInt32)
    end

    # Verify header CRC16, if present
    if FLAG_HCRC
        # Lower 16 bits of crc32 up to, not including, this index
        # +---+---+
        # | CRC16 |
        # +---+---+
        UInt(index) + UInt(1) <= max_len ||
            return LibDeflateErrors.gzip_header_too_short
        crc_obs_16 = unsafe_crc32(ptr + one(UInt), index - one(UInt)) % UInt16
        crc_exp_16 = ltoh(unsafe_load(Ptr{UInt16}(ptr + index)))
        crc_obs_16 == crc_exp_16 || return LibDeflateErrors.gzip_bad_header_crc16
        index += UInt32(2)
    end

    return (index - UInt32(1), GzipHeader(mtime, filename, comment, extra))
end

"""
    GzipDecompressResult

Result of `LibDeflate`'s gzip decompression on byte vector.

It has the following fields:
* `len::UInt32` length of decompressed data
* `header::GzipHeader` metadata
"""
struct GzipDecompressResult
    len::UInt32 # length of decompressed data
    header::GzipHeader
end

"""
    gzip_decompress!(
        ::Decompressor, out::Vector{UInt8}, in_data, max_len=typemax(Int)
    )::Union{GzipDecompressResult, LibDeflateError}

Gzip decompress the input data into `out`, and resize `out` to fit.
Only the first gzip member is decompressed; any following members or trailing
data are left unread.

See also: [`unsafe_gzip_decompress!`](@ref)
"""
function gzip_decompress!(
        decompressor::Decompressor,
        out_data::Vector{UInt8},
        in_data;
        extra_data::Union{Vector{GzipExtraField}, Nothing} = nothing,
        max_len::Integer = typemax(Int),
    )::Union{LibDeflateError, GzipDecompressResult}
    GC.@preserve in_data out_data begin
        read = ReadableMemory(in_data)
        result = unsafe_gzip_decompress!(
            decompressor,
            out_data,
            UInt(max_len),
            Ptr{UInt8}(pointer(read)),
            sizeof(read) % UInt,
            extra_data,
        )
    end
    result isa LibDeflateError && return result
    length(out_data) == result.len || resize!(out_data, result.len)
    return result
end

"""
    unsafe_gzip_decompress!(
        ::Decompressor, out_data::Vector{UInt8},
        max_outlen::Integer, in_ptr::Ptr, len::Integer,
        extra_data::Union{Vector{GzipExtraField}, Nothing}
    )::Union{LibDeflateError, GzipDecompressResult}

Use the `Decompressor` to decompress gzip data at `in_ptr` and `len` bytes forward
into `out_data`. If there is not enough room at `out_data`, resize `out_data`, except
if it would be bigger than `max_outlen`, in that case return an error.
If `extra_data` is not `nothing`, reuse the vector by overwriting.
Only the first gzip member is decompressed; any following members or trailing
data are left unread.

Return a `GzipDecompressResult`

See also: [`gzip_decompress!`](@ref)
"""
function unsafe_gzip_decompress!(
        decompressor::Decompressor,
        out_data::Vector{UInt8},
        max_outlen::Integer,
        in_ptr::Ptr,
        len::Integer,
        extra_data::Union{Vector{GzipExtraField}, Nothing} = nothing,
    )::Union{LibDeflateError, GzipDecompressResult}
    # We need to have at least 2 + 4 + 4 bytes left after header
    nonheader_min_len = 2 + 4 + 4
    len < nonheader_min_len && return LibDeflateErrors.gzip_header_too_short
    len = UInt(len)

    # First decompress header
    hdr_result = unsafe_parse_gzip_header(in_ptr, UInt(len - nonheader_min_len), extra_data)
    hdr_result isa LibDeflateError && return hdr_result
    header_len, header = hdr_result

    # Decompress the first DEFLATE stream.  Its trailer cannot be found from the
    # end of the input, since another gzip member may follow it, so use
    # libdeflate's consumed-input count to locate it.
    max_capacity = min(UInt(max_outlen), UInt(typemax(UInt32)), UInt(typemax(Int)))
    capacity = min(UInt(length(out_data)), max_capacity)
    decomp_result = LibDeflateErrors.deflate_insufficient_space
    while true
        decomp_result = GC.@preserve out_data unsafe_decompress_ex!(
            Base.SizeUnknown(),
            decompressor,
            pointer(out_data),
            capacity,
            in_ptr + header_len,
            len - header_len,
        )
        decomp_result != LibDeflateErrors.deflate_insufficient_space && break
        capacity == max_capacity && break

        capacity = iszero(capacity) ? one(UInt) : min(2 * capacity, max_capacity)
        resize!(out_data, capacity % Int)
    end
    decomp_result isa LibDeflateError && return decomp_result
    consumed, uncompressed_size = decomp_result

    # Check this member's trailer rather than the last eight bytes of the input.
    # +---+---+---+---+---+---+---+---+
    # |     CRC32     |     ISIZE     | (possibly another member)
    # +---+---+---+---+---+---+---+---+
    trailer_offset = UInt(header_len) + UInt(consumed)
    len - trailer_offset >= UInt(8) || return LibDeflateErrors.gzip_header_too_short
    trailer_ptr = Ptr{UInt8}(in_ptr) + trailer_offset
    size_exp = ltoh(unsafe_load(Ptr{UInt32}(trailer_ptr + 4)))
    size_exp == uncompressed_size % UInt32 ||
        return LibDeflateErrors.deflate_bad_payload

    # Check for CRC checksum and validate it
    crc_exp = ltoh(unsafe_load(Ptr{UInt32}(trailer_ptr)))
    crc_obs = GC.@preserve out_data unsafe_crc32(pointer(out_data), uncompressed_size)
    crc_exp == crc_obs || return LibDeflateErrors.gzip_bad_crc32

    return GzipDecompressResult(uncompressed_size % UInt32, header)
end

#Computes maximal output length of a gzip compression
function max_out_len(
        input_len::UInt,
        comment_len::UInt,
        filename_len::UInt,
        extra_len::UInt16,
        header_crc::Bool,
    )
    # Taken from libdeflate source code
    # with slight modifications
    static = 10 + 8 + 9 # header + footer + padding

    n_chunks = max(cld(input_len, 10000), 1)
    len = static + input_len + 5 * n_chunks # 5 byte overhead per chunk
    len += comment_len + !iszero(comment_len) # incl. null byte
    len += filename_len + !iszero(filename_len) # incl. null byte
    len += extra_len + 2 * !iszero(extra_len) # incl. 2-byte leader
    len += 2 * header_crc
    return len
end

"""
    gzip_compress!(
        compressor::Compressor,
        output::Vector{UInt8},
        input::ReadableMemory
        comment=nothing,
        filename=nothing,
        extra=nothing,
        header_crc::Bool=false
    )::Union{LibDeflateError, Vector{UInt8}}

Gzip compress `input` into `output` and resizing output to fit. Returns `output`.

Adds optional data `comment`, `filename`, `extra`. All these must be `nothing` if
not applicable.
* `comment` and `filename` must not include the byte `0x00`.
* `extra` must be at most `typemax(UInt16)` bytes long.

If `header_crc` is true, add the header CRC checksum.

See also: [`unsafe_gzip_compress!`](@ref)
"""
function gzip_compress!(
        compressor::Compressor,
        output::Vector{UInt8},
        input;
        comment = nothing,
        filename = nothing,
        extra = nothing,
        header_crc::Bool = false,
    )::Union{LibDeflateError, Vector{UInt8}}
    # Resize output to maximal possible length
    GC.@preserve input comment filename extra begin
        read = ReadableMemory(input)
        mem_comment = comment === nothing ? nothing : ReadableMemory(comment)
        mem_filename = filename === nothing ? nothing : ReadableMemory(filename)
        mem_extra = extra === nothing ? nothing : ReadableMemory(extra)

        maxlen = max_out_len(
            sizeof(read) % UInt,
            mem_comment === nothing ? UInt(0) : sizeof(mem_comment) % UInt,
            mem_filename === nothing ? UInt(0) : sizeof(mem_filename) % UInt,
            mem_extra === nothing ? UInt16(0) : sizeof(mem_extra) % UInt16,
            header_crc,
        )

        # We add 8 extra bytes to make sure Libdeflate don't error due to off-by-one errors
        resize!(output, maxlen + 8)

        GC.@preserve output begin
            write = WriteableMemory(output)
            n_bytes = unsafe_gzip_compress!(
                compressor,
                pointer(write),
                sizeof(write) % UInt,
                pointer(read),
                sizeof(read) % UInt,
                mem_comment,
                mem_filename,
                mem_extra,
                header_crc,
            )
        end
    end
    n_bytes isa LibDeflateError && return n_bytes
    resize!(output, n_bytes % UInt)
    return output
end

"""
    unsafe_gzip_compress!(
        compressor::Compressor,
        out_ptr::Ptr, out_len::Integer,
        in_ptr::Ptr, in_len::Integer,
        comment::Union{Nothing, ReadableMemory},
        filename::Union{Nothing, ReadableMemory},
        extra::Union{Nothing, ReadableMemory},
        header_crc::Bool
    )::Union{LibDeflateError, Int}

Use the `Compressor` to gzip compress input at `in_ptr` and `in_len` bytes onwards
to, `out_ptr`.
If the resulting gzip data could be longer than `out_len`, return an error.
Optionally, include gzip comment, filename or extra data. All these must be `nothing` if
not applicable.

Adds optional data `comment`, `filename`, `extra`. 
* `comment` and `filename` must not include the byte `0x00`.
* `extra` must be at most `typemax(UInt16)` bytes long.

Returns the number of bytes written to `out_ptr`.

See also: [`gzip_compress!`](@ref)
"""
function unsafe_gzip_compress!(
        compressor::Compressor,
        out_ptr::Ptr,
        out_len::Integer,
        in_ptr::Ptr,
        in_len::Integer,
        comment::Union{Nothing, ReadableMemory},
        filename::Union{Nothing, ReadableMemory},
        extra::Union{Nothing, ReadableMemory},
        header_crc::Bool,
    )::Union{LibDeflateError, Int}
    # Check output len is long enough
    max_out_len(
        UInt(in_len),
        comment === nothing ? UInt(0) : sizeof(comment) % UInt,
        filename === nothing ? UInt(0) : sizeof(filename) % UInt,
        if extra === nothing
            UInt16(0)
        else
            # No more than typemax(UInt16) bytes for extra field
            sizeof(extra) > typemax(UInt16) && return LibDeflateErrors.gzip_extra_too_long
            sizeof(extra) % UInt16
        end,
        header_crc,
    ) > out_len && return LibDeflateErrors.deflate_insufficient_space

    # Write first four bytes - magix number, compression type, flags
    header = 0x00088b1f
    if comment !== nothing
        # Check for absence of zero byte
        any_zeros(comment) && return LibDeflateErrors.gzip_null_in_string
        header |= 0x10000000
    end
    if filename !== nothing
        # Check for absence of zero byte
        any_zeros(filename) && return LibDeflateErrors.gzip_null_in_string
        header |= 0x08000000
    end
    if extra !== nothing
        # Validate extra data
        is_valid_extra_data(pointer(extra), sizeof(extra) % UInt16) ||
            return LibDeflateErrors.gzip_bad_extra
        header |= 0x04000000
    end
    header = ifelse(header_crc, header | 0x02000000, header)
    ptr = Ptr{UInt8}(out_ptr) - 1
    unsafe_store!(Ptr{UInt32}(ptr + 1), htol(header))

    # Add system time (take lower 32 bits if it overflows)
    unsafe_store!(Ptr{UInt32}(ptr + 5), htol(unsafe_trunc(UInt32, time())))

    # Add system (unknown) and XFL (zero)
    unsafe_store!(Ptr{UInt16}(ptr + 9), htol(0x00ff))

    index = UInt(11)

    # Add in extra data
    if extra !== nothing
        unsafe_store!(Ptr{UInt16}(ptr + index), htol(sizeof(extra) % UInt16))
        unsafe_copyto!(ptr + index + 2, Ptr{UInt8}(pointer(extra)), sizeof(extra))
        index += UInt(2) + sizeof(extra)
    end

    # Add in filename
    if filename !== nothing
        unsafe_copyto!(ptr + index, Ptr{UInt8}(pointer(filename)), sizeof(filename))
        index += sizeof(filename) + one(UInt) # null byte
        unsafe_store!(ptr + index - 1, 0x00)
    end

    # Add in comment
    if comment !== nothing
        unsafe_copyto!(ptr + index, Ptr{UInt8}(pointer(comment)), sizeof(comment))
        index += sizeof(comment) + one(UInt) # null byte
        unsafe_store!(ptr + index - 1, 0x00)
    end

    # Add in CRC16
    if header_crc
        header_crc = unsafe_crc32(ptr + one(UInt), index - one(UInt)) % UInt16
        unsafe_store!(Ptr{UInt16}(ptr + index), htol(header_crc))
        index += UInt(2)
    end

    # Add in compressed data
    remaining_out_data = out_len - index + 1 - 8 # tail
    n_compressed = unsafe_compress!(
        compressor, ptr + index, remaining_out_data, in_ptr, in_len
    )
    n_compressed isa LibDeflateError && return n_compressed
    index += n_compressed

    # Add in crc32 of uncompressed data
    crc = unsafe_crc32(in_ptr, in_len)
    unsafe_store!(Ptr{UInt32}(ptr + index), htol(crc))
    index += 4

    # Add in isize (uncompressed size)
    unsafe_store!(Ptr{UInt32}(ptr + index), htol(in_len % UInt32))
    return (index + 3) % Int # 4 bytes isize - off-by-one
end
