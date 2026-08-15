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
    unsafe_is_valid_extra_data(data::ReadableMemory)::Bool

Check whether `data` represents valid gzip metadata for the "extra" field.
Gzip extra data cannot exceed `typemax(UInt16)` bytes.

The memory referenced by `data` must remain valid for the duration of the call.

See also: [`is_valid_extra_data`](@ref)
"""
function unsafe_is_valid_extra_data(data::ReadableMemory)::Bool
    sizeof(data) > typemax(UInt16) && return false
    ptr = Ptr{UInt8}(pointer(data))
    rem_bytes = sizeof(data) % UInt16
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
    is_valid_extra_data(data)::Bool

Check whether `data` represents valid gzip metadata for the "extra" field.
Custom input types can opt in by implementing `ReadableMemory(data)`.

See also: [`unsafe_is_valid_extra_data`](@ref)
"""
function is_valid_extra_data(data)::Bool
    return GC.@preserve data unsafe_is_valid_extra_data(ReadableMemory(data))
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
    )::Union{LibDeflateError, @NamedTuple{read::UInt32, header::GzipHeader}}

Parse the input data, returning the number of bytes read and a `GzipHeader`, or a
`LibDeflateError`.
If a vector of gzip extra data is passed, the parser will reuse and overwrite it.
"""
function parse_gzip_header(
        in; extra_data::Union{Vector{GzipExtraField}, Nothing} = nothing
    )::Union{LibDeflateError, @NamedTuple{read::UInt32, header::GzipHeader}}
    return GC.@preserve in unsafe_parse_gzip_header(ReadableMemory(in), extra_data)
end

"""
    unsafe_parse_gzip_header(
        input::ReadableMemory,
        extra_data::Union{Vector{GzipExtraField}, Nothing}=nothing
    )

Parse the input data, returning the number of bytes read and a `GzipHeader`, or a
`LibDeflateError`.
The parser will not read more than `sizeof(input)` bytes. If a vector of gzip extra
data is passed, it will not allocate a new vector, but overwrite the given one.
"""
function unsafe_parse_gzip_header(
        input::ReadableMemory,
        extra_data::Union{Vector{GzipExtraField}, Nothing} = nothing,
    )::Union{LibDeflateError, @NamedTuple{read::UInt32, header::GzipHeader}}

    # header is at least 10 bytes
    max_len = sizeof(input) % UInt
    max_len > 9 || return LibDeflateErrors.gzip_header_too_short
    # Bytes 1 - 10. Check first four bytes, skip rest
    # +---+---+---+---+---+---+---+---+---+---+
    # |ID1|ID2|CM |FLG|     MTIME     |XFL|OS | (more-->)
    # +---+---+---+---+---+---+---+---+---+---+
    ptr = Ptr{UInt8}(pointer(input)) - UInt(1) # one-indexed pointer
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
    extra_data === nothing || empty!(extra_data)
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
        crc_input = ReadableMemory(ptr + one(UInt), (index - one(UInt)) % UInt)
        crc_obs_16 = unsafe_crc32(crc_input) % UInt16
        crc_exp_16 = ltoh(unsafe_load(Ptr{UInt16}(ptr + index)))
        crc_obs_16 == crc_exp_16 || return LibDeflateErrors.gzip_bad_header_crc16
        index += UInt32(2)
    end

    return (; read = index - UInt32(1), header = GzipHeader(mtime, filename, comment, extra))
end

"""
    GzipDecompressResult

Result of `LibDeflate`'s gzip decompression.

It has the following fields:
* `written::UInt32` number of decompressed bytes written
* `read::UInt32` number of bytes read from input
* `header::GzipHeader` metadata
"""
struct GzipDecompressResult
    written::UInt32 # number of decompressed bytes written
    read::UInt32 # number of bytes read of the stream
    header::GzipHeader
end

"""
    gzip_decompress!(
        ::Decompressor, output, input, [n_out::Integer]; extra_data=nothing
    )::Union{GzipDecompressResult, LibDeflateError}

Decompress the first gzip member in `input` into the fixed-size buffer `output`.
Return `LibDeflate.deflate_insufficient_space` if the decompressed data does not fit.

If the exact decompressed size is known, pass it as `n_out` to use the faster
known-size decompression path. An incorrect size returns
`LibDeflate.deflate_output_too_short` or `LibDeflate.deflate_insufficient_space`.

On success, the returned result reports both the decompressed length and the total
number of input bytes consumed by that member. Following gzip members or trailing data
are left unread. Custom input and output types can opt in by implementing
`ReadableMemory(input)` and `WriteableMemory(output)`, respectively.
"""
function gzip_decompress!(
        decompressor::Decompressor,
        output,
        input;
        extra_data::Union{Vector{GzipExtraField}, Nothing} = nothing,
    )::Union{LibDeflateError, GzipDecompressResult}
    return GC.@preserve input output begin
        unsafe_gzip_decompress!(
            decompressor,
            WriteableMemory(output),
            ReadableMemory(input);
            extra_data,
        )
    end
end

function gzip_decompress!(
        decompressor::Decompressor,
        output,
        input,
        n_out::Integer;
        extra_data::Union{Vector{GzipExtraField}, Nothing} = nothing,
    )::Union{LibDeflateError, GzipDecompressResult}
    return GC.@preserve input output begin
        unsafe_gzip_decompress!(
            decompressor,
            WriteableMemory(output),
            ReadableMemory(input),
            n_out;
            extra_data,
        )
    end
end

"""
    unsafe_gzip_decompress!(
        ::Decompressor, output::WriteableMemory, input::ReadableMemory,
        [n_out::Integer]; extra_data=nothing
    )::Union{LibDeflateError, GzipDecompressResult}

Use the `Decompressor` to decompress the first gzip member in `input` into `output`.
Without `n_out`, `sizeof(output)` is the available capacity. If the exact decompressed
size is known, pass it as `n_out` to use the faster known-size path. Return an error if
the output size is insufficient or incorrect.

If `extra_data` is not `nothing`, reuse the vector by overwriting.
Only the first gzip member is decompressed; any following members or trailing
data are left unread.

Return a `GzipDecompressResult` on success.

See also: [`gzip_decompress!`](@ref)
"""
function unsafe_gzip_decompress!(
        decompressor::Decompressor,
        output::WriteableMemory,
        input::ReadableMemory;
        extra_data::Union{Vector{GzipExtraField}, Nothing} = nothing,
    )::Union{LibDeflateError, GzipDecompressResult}
    return _unsafe_gzip_decompress!(
        Base.SizeUnknown(), decompressor, output, input, extra_data
    )
end

function unsafe_gzip_decompress!(
        decompressor::Decompressor,
        output::WriteableMemory,
        in::ReadableMemory,
        n_out::Integer;
        extra_data::Union{Vector{GzipExtraField}, Nothing} = nothing,
    )::Union{LibDeflateError, GzipDecompressResult}
    sizeof(output) < n_out && return LibDeflateErrors.deflate_insufficient_space
    exact_output = WriteableMemory(pointer(output), n_out % UInt)
    return _unsafe_gzip_decompress!(
        Base.HasLength(), decompressor, exact_output, in, extra_data
    )
end

function _unsafe_gzip_decompress!(
        size::Union{Base.SizeUnknown, Base.HasLength},
        decompressor::Decompressor,
        output::WriteableMemory,
        in::ReadableMemory,
        extra_data::Union{Vector{GzipExtraField}, Nothing},
    )::Union{LibDeflateError, GzipDecompressResult}
    # We need to have at least 2 + 4 + 4 bytes left after header
    nonheader_min_len = 2 + 4 + 4
    len = sizeof(in) % UInt
    sizeof(in) < nonheader_min_len && return LibDeflateErrors.gzip_header_too_short

    # First decompress header
    header_input = ReadableMemory(pointer(in), len - UInt(nonheader_min_len))
    hdr_result = unsafe_parse_gzip_header(header_input, extra_data)
    hdr_result isa LibDeflateError && return hdr_result
    header_len = hdr_result.read
    header = hdr_result.header

    # The trailer cannot be found from the end of the input, since another gzip
    # member may follow it. Use libdeflate's consumed-input count to locate it.
    compressed = ReadableMemory(pointer(in) + header_len, len - header_len)
    decomp_result = _unsafe_decompress!(size, decompressor, output, compressed)
    decomp_result isa LibDeflateError && return decomp_result
    consumed = decomp_result.read
    uncompressed_size = decomp_result.written

    # Check this member's trailer rather than the last eight bytes of the input.
    # +---+---+---+---+---+---+---+---+
    # |     CRC32     |     ISIZE     | (possibly another member)
    # +---+---+---+---+---+---+---+---+
    trailer_offset = UInt(header_len) + UInt(consumed)
    len - trailer_offset >= UInt(8) || return LibDeflateErrors.gzip_header_too_short
    trailer_ptr = Ptr{UInt8}(pointer(in)) + trailer_offset
    size_exp = ltoh(unsafe_load(Ptr{UInt32}(trailer_ptr + 4)))
    size_exp == uncompressed_size % UInt32 ||
        return LibDeflateErrors.deflate_bad_payload

    # Check for CRC checksum and validate it
    crc_exp = ltoh(unsafe_load(Ptr{UInt32}(trailer_ptr)))
    crc_input = ReadableMemory(pointer(output), uncompressed_size % UInt)
    crc_obs = unsafe_crc32(crc_input)
    crc_exp == crc_obs || return LibDeflateErrors.gzip_bad_crc32

    total_read = trailer_offset + UInt(8)
    return GzipDecompressResult(uncompressed_size % UInt32, total_read % UInt32, header)
end

"""
    gzip_decompress_all!(
        ::Decompressor, output, input; extra_data=nothing
    )::Union{LibDeflateError, @NamedTuple{read::Int, written::Int, members::Int}}

Decompress every member of a gzip file in `input` into the fixed-size buffer `output`.
The input must contain at least one complete member and no trailing data. Return
`LibDeflate.deflate_insufficient_space` if the decompressed data does not fit.

On success, return the total input bytes read, output bytes written, and members decoded.
If `extra_data` is not `nothing`, reuse it while parsing each header; after success it
contains the extra fields from the final member, with data ranges indexed into the full
`input`. Custom input and output types can opt in by implementing `ReadableMemory(input)`
and `WriteableMemory(output)`, respectively.

See also: [`gzip_decompress!`](@ref), [`unsafe_gzip_decompress_all!`](@ref)
"""
function gzip_decompress_all!(
        decompressor::Decompressor,
        output,
        input;
        extra_data::Union{Vector{GzipExtraField}, Nothing} = nothing,
    )::Union{
        LibDeflateError,
        @NamedTuple{read::Int, written::Int, members::Int},
    }
    return GC.@preserve input output begin
        unsafe_gzip_decompress_all!(
            decompressor,
            WriteableMemory(output),
            ReadableMemory(input);
            extra_data,
        )
    end
end

"""
    unsafe_gzip_decompress_all!(
        ::Decompressor, output::WriteableMemory, input::ReadableMemory;
        extra_data=nothing
    )::Union{LibDeflateError, @NamedTuple{read::Int, written::Int, members::Int}}

Unsafe variant of [`gzip_decompress_all!`](@ref). Decompress every member of a gzip file
in `input` into `output`. The input must contain at least one complete member and no
trailing data.

`sizeof(output)` is the available capacity. The referenced memory must remain valid for
the duration of the call.

If `extra_data` is not `nothing`, reuse it while parsing each header; after success it
contains the extra fields from the final member, with data ranges indexed into the full
`input`.
"""
function unsafe_gzip_decompress_all!(
        decompressor::Decompressor,
        output::WriteableMemory,
        input::ReadableMemory;
        extra_data::Union{Vector{GzipExtraField}, Nothing} = nothing,
    )::Union{
        LibDeflateError,
        @NamedTuple{read::Int, written::Int, members::Int},
    }
    input_size = sizeof(input)
    output_size = sizeof(output)
    read = 0
    written = 0
    members = 0

    while read < input_size || iszero(members)
        member_input = ReadableMemory(
            pointer(input) + read, (input_size - read) % UInt
        )
        member_output = WriteableMemory(
            pointer(output) + written, (output_size - written) % UInt
        )
        result = _unsafe_gzip_decompress!(
            Base.SizeUnknown(), decompressor, member_output, member_input, extra_data
        )
        result isa LibDeflateError && return result

        if extra_data !== nothing && result.header.extra !== nothing && !iszero(read)
            member_offset = read % UInt32
            for index in eachindex(extra_data)
                field = extra_data[index]
                data = field.data
                data === nothing && continue
                extra_data[index] = GzipExtraField(
                    field.tag, (first(data) + member_offset):(last(data) + member_offset)
                )
            end
        end

        read += result.read
        written += result.written
        members += 1
    end

    return (; read, written, members)
end

function _gzip_wrapper_size(
        comment_len::Union{Nothing, Int},
        filename_len::Union{Nothing, Int},
        extra_len::Union{Nothing, Int},
        header_crc::Bool,
    )::Union{LibDeflateError, Int}
    comment_len !== nothing && comment_len < 0 &&
        throw(ArgumentError("comment_len must be nonnegative"))
    filename_len !== nothing && filename_len < 0 &&
        throw(ArgumentError("filename_len must be nonnegative"))
    extra_len !== nothing && extra_len < 0 &&
        throw(ArgumentError("extra_len must be nonnegative"))
    extra_len !== nothing && extra_len > typemax(UInt16) &&
        return LibDeflateErrors.gzip_extra_too_long

    size = 10 + 8
    comment_len === nothing || (size += comment_len + 1)
    filename_len === nothing || (size += filename_len + 1)
    extra_len === nothing || (size += extra_len + 2)
    size += 2 * header_crc
    return size
end

"""
    gzip_compress_bound(
        compressor::Compressor, input_size::Int;
        comment_len=nothing, filename_len=nothing, extra_len=nothing, header_crc=false
    )::Union{LibDeflateError, Int}

Return a worst-case upper bound on the number of bytes produced by
[`gzip_compress!`](@ref) with the given input and metadata sizes. A metadata length of
`nothing` means that the corresponding optional field will not be present, while `0`
represents a present but empty field.

The bound may overestimate the required space, but an output buffer of this size is
guaranteed to be sufficient. Return `LibDeflate.gzip_extra_too_long` if `extra_len`
cannot be represented in a gzip header. This calculation does not inspect any input or
metadata and is constant-time with respect to all supplied sizes.
"""
function gzip_compress_bound(
        compressor::Compressor,
        input_size::Int;
        comment_len::Union{Nothing, Int} = nothing,
        filename_len::Union{Nothing, Int} = nothing,
        extra_len::Union{Nothing, Int} = nothing,
        header_crc::Bool = false,
    )::Union{LibDeflateError, Int}
    wrapper_size = _gzip_wrapper_size(comment_len, filename_len, extra_len, header_crc)
    wrapper_size isa LibDeflateError && return wrapper_size
    return deflate_compress_bound(compressor, input_size) + wrapper_size
end

"""
    gzip_compress!(
        compressor::Compressor, output, input;
        comment=nothing, filename=nothing, extra=nothing, header_crc=false
    )::Union{LibDeflateError, Int}

Compress `input` as gzip data into the fixed-size buffer `output`, returning the
number of bytes written or `LibDeflate.deflate_insufficient_space` if it does not fit.
The output is never resized.

Use [`gzip_compress_bound`](@ref) to determine an output size that is guaranteed to
be sufficient. Custom input, output, and metadata types can opt in by implementing
`ReadableMemory` and `WriteableMemory`.
"""
function gzip_compress!(
        compressor::Compressor,
        output,
        input;
        comment = nothing,
        filename = nothing,
        extra = nothing,
        header_crc::Bool = false,
    )::Union{LibDeflateError, Int}
    return GC.@preserve output input comment filename extra begin
        _gzip_compress!(
            compressor,
            WriteableMemory(output),
            ReadableMemory(input),
            comment === nothing ? nothing : ReadableMemory(comment),
            filename === nothing ? nothing : ReadableMemory(filename),
            extra === nothing ? nothing : ReadableMemory(extra),
            header_crc,
        )
    end
end

function _gzip_compress!(
        compressor::Compressor,
        output::WriteableMemory,
        input::ReadableMemory,
        comment::Union{Nothing, ReadableMemory},
        filename::Union{Nothing, ReadableMemory},
        extra::Union{Nothing, ReadableMemory},
        header_crc::Bool,
    )::Union{LibDeflateError, Int}
    return unsafe_gzip_compress!(
        compressor,
        output,
        input,
        comment,
        filename,
        extra,
        header_crc,
    )
end

"""
    unsafe_gzip_compress!(
        compressor::Compressor,
        out::WriteableMemory,
        in::ReadableMemory,
        comment::Union{Nothing, ReadableMemory},
        filename::Union{Nothing, ReadableMemory},
        extra::Union{Nothing, ReadableMemory},
        header_crc::Bool
    )::Union{LibDeflateError, Int}

Use the `Compressor` to gzip compress input at `pointer(in)` and `sizeof(in)` bytes onwards
to, `pointer(out)`.
If the resulting gzip data does not fit in `sizeof(out)`, return
`LibDeflate.deflate_insufficient_space`.
Optionally, include gzip comment, filename or extra data. All these must be `nothing` if
not applicable.

Adds optional data `comment`, `filename`, `extra`. 
* `comment` and `filename` must not include the byte `0x00`.
* `extra` must be at most `typemax(UInt16)` bytes long.

Returns the number of bytes written to `pointer(out)`.

See also: [`gzip_compress!`](@ref)
"""
function unsafe_gzip_compress!(
        compressor::Compressor,
        out::WriteableMemory,
        in::ReadableMemory,
        comment::Union{Nothing, ReadableMemory},
        filename::Union{Nothing, ReadableMemory},
        extra::Union{Nothing, ReadableMemory},
        header_crc::Bool,
    )::Union{LibDeflateError, Int}
    out_len = sizeof(out) % UInt
    wrapper_size = _gzip_wrapper_size(
        comment === nothing ? nothing : sizeof(comment),
        filename === nothing ? nothing : sizeof(filename),
        extra === nothing ? nothing : sizeof(extra),
        header_crc,
    )
    wrapper_size isa LibDeflateError && return wrapper_size
    sizeof(out) < wrapper_size && return LibDeflateErrors.deflate_insufficient_space

    # Validate metadata before modifying the output.
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
        unsafe_is_valid_extra_data(extra) ||
            return LibDeflateErrors.gzip_bad_extra
        header |= 0x04000000
    end
    header = ifelse(header_crc, header | 0x02000000, header)

    # Write first four bytes - magic number, compression type, flags
    ptr = Ptr{UInt8}(pointer(out)) - 1
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
        crc_input = ReadableMemory(ptr + one(UInt), index - one(UInt))
        header_crc = unsafe_crc32(crc_input) % UInt16
        unsafe_store!(Ptr{UInt16}(ptr + index), htol(header_crc))
        index += UInt(2)
    end

    # Add in compressed data
    remaining_out_data = out_len - index + 1 - 8 # tail
    compress_to = WriteableMemory(ptr + index, remaining_out_data % UInt)
    n_compressed = unsafe_compress!(compressor, compress_to, in)
    n_compressed isa LibDeflateError && return n_compressed
    index += n_compressed

    # Add in crc32 of uncompressed data
    crc = unsafe_crc32(in)
    unsafe_store!(Ptr{UInt32}(ptr + index), htol(crc))
    index += 4

    # Add in isize (uncompressed size)
    unsafe_store!(Ptr{UInt32}(ptr + index), htol(sizeof(in) % UInt32))
    return (index + 3) % Int # 4 bytes isize - off-by-one
end
