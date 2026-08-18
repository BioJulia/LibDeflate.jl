# Returns index of next zero (or error if none is found)
# pointer must point to first byte where the search begins
# This can be SIMD'd but it's way fast anyway.
function bytes_until_zero(p::Ptr{UInt8}, lastindex::UInt)::Union{UInt, Nothing}
    pos = @ccall gc_safe = true memchr(
        p::Ptr{UInt8}, 0x00::Cint, lastindex::Csize_t
    )::Ptr{Cchar}
    return pos == C_NULL ? nothing : (pos - p) % UInt
end

"Check if there are any 0x00 bytes in a block of memory"
function any_zeros(mem::ReadableMemory)::Bool
    return bytes_until_zero(Ptr{UInt8}(pointer(mem)), mem.len) !== nothing
end

# +---+---+---+---+==================================+
# |SI1|SI2|  LEN  |... LEN bytes of subfield data ...|
# +---+---+---+---+==================================+
"""
    GzipExtraField

Data structure for gzip extra data. Public properties:

* `tag::NTuple{2, UInt8}` two-byte tag
* `data::Union{Nothing, UnitRange{UInt}}` one-based location of subfield data in the
  original input. It is `nothing` precisely when the length of the range would
  otherwise be zero.

# Examples:
```jldoctest
julia> header_bytes = b"\\x1f\\x8b\\x08\\x04\\0\\0\\0\\0\\0\\xff"; # FEXTRA flag set

julia> extra_bytes = b"\\x06\\0\\x41\\x42\\x02\\0\\x01\\x02"; # XLEN, tag, len, data

julia> bytes = vcat(header_bytes, extra_bytes);

julia> fields = GzipExtraField[];

julia> parse_gzip_header(bytes, fields);

julia> fields[1].tag
(0x41, 0x42)

julia> bytes[fields[1].data] == b"\\x01\\x02"
true
```
"""
struct GzipExtraField
    data_start::UInt # one-based
    data_length::UInt16
    tag::Tuple{UInt8, UInt8} # (SI1, SI2)
end

@inline function Base.getproperty(field::GzipExtraField, name::Symbol)
    name === :data || return getfield(field, name)
    data_length = getfield(field, :data_length)
    iszero(data_length) && return nothing
    data_start = getfield(field, :data_start)
    return data_start:(data_start + UInt(data_length) - one(UInt))
end

function Base.propertynames(::GzipExtraField, private::Bool = false)
    return private ? (:data_start, :data_length, :tag, :data) : (:tag, :data)
end

# The pointer points to the first byte of the first field
function parse_fields!(
        fields::Vector{GzipExtraField},
        ptr::Ptr{UInt8},
        index::UInt,
        remaining_bytes::UInt16, # Format supports no more than 0xffff bytes here
    )::Union{Vector{GzipExtraField}, LibDeflateError}
    while !iszero(remaining_bytes)
        field = parse_extra_field(ptr, index, remaining_bytes)
        field isa LibDeflateError && return field
        push!(fields, field)

        total_len = field.data_length + UInt16(4)
        remaining_bytes -= total_len
        ptr += total_len
        index += total_len
    end
    return fields
end

# The pointer points to the first byte of the extra fields
function parse_extra_field(
        ptr::Ptr{UInt8}, index::UInt, remaining_bytes::UInt16
    )::Union{GzipExtraField, LibDeflateError}
    remaining_bytes < 4 && return LibDeflateErrors.gzip_extra_too_long
    s1 = unsafe_load(ptr)
    s2 = unsafe_load(ptr + 1)
    iszero(s2) && return LibDeflateErrors.gzip_bad_extra
    field_len = ltoh(unsafe_load(Ptr{UInt16}(ptr + 2)))
    field_len + 4 > remaining_bytes && return LibDeflateErrors.gzip_extra_too_long

    return GzipExtraField(index + UInt(4), field_len, (s1, s2))
end

"""
    unsafe_is_valid_extra_data(data::ReadableMemory)::Bool

Check whether `data` represents valid gzip metadata for the "extra" field.
Gzip extra data cannot exceed `typemax(UInt16)` bytes.

The memory referenced by `data` must remain valid for the duration of the call.

See also: [`is_valid_extra_data`](@ref)

# Examples:
```jldoctest
julia> data = b"\\x41\\x42\\x02\\0\\x01\\x02"; # tag, 2-byte length, 2 bytes data

julia> GC.@preserve data unsafe_is_valid_extra_data(ReadableMemory(data))
true
```
"""
function unsafe_is_valid_extra_data(data::ReadableMemory)::Bool
    data.len > typemax(UInt16) && return false
    ptr = Ptr{UInt8}(pointer(data))
    rem_bytes = data.len % UInt16
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

# Examples:
```jldoctest
julia> is_valid_extra_data(b"\\x41\\x42\\x02\\0\\x01\\x02")
true

julia> is_valid_extra_data(b"\\x41\\x42\\x02\\0\\x01") # too short for declared length
false
```
"""
function is_valid_extra_data(data)::Bool
    return GC.@preserve data unsafe_is_valid_extra_data(ReadableMemory(data))
end

"""
    GzipHeader

Struct representing a gzip header. It has the following properties:
* `mtime::Union{Nothing, NonZeroUInt32}`: modification time of the file, as expressed by
  a UNIX timestamp mod 2^32. The value zero is not permitted by the gzip format.
* `filename::Union{Nothing, UnitRange{Int}}`: index of the filename in the header.
  `nothing` means that the `FNAME` flag is absent, while an empty range means that the
  flag is present but the filename is empty.
* `comment::Union{Nothing, UnitRange{Int}}`: index of the comment in the header.
  `nothing` means that the `FCOMMENT` flag is absent, while an empty range means that
  the flag is present but the comment is empty.
* `extra::Union{Nothing, UnitRange{Int}}`: the indices of the gzip extra fields
  in the passed-in `Vector{GzipExtraField}` (or `GzipDecompressAllScratch`).
  `nothing` means that the `FEXTRA` flag is absent, while an empty range means that the
  flag is present with `XLEN == 0`.

# Examples:
```jldoctest
julia> header_bytes = b"\\x1f\\x8b\\x08\\x08\\0\\0\\0\\0\\0\\xff";

julia> bytes = vcat(header_bytes, b"hi", b"\\0"); # gzip header, filename "hi"

julia> fields = GzipExtraField[];

julia> header = parse_gzip_header(bytes, fields).header;

julia> String(bytes[header.filename])
"hi"
```
"""
struct GzipHeader
    # The tuples here encode `nothing` as (0, 0)
    extra::Tuple{UInt, UInt}
    filename::Tuple{UInt, UInt}
    comment::Tuple{UInt, UInt}
    # NonZeroUInt32, with the all-zero bitpattern encoding `nothing`
    mtime::UInt32
end

@inline function load_gzip_header_tuple(
        x::Tuple{UInt, UInt}
    )::Union{Nothing, UnitRange{Int}}
    return x === (UInt(0), UInt(0)) ? nothing : reinterpret(UnitRange{Int}, x)
end

@inline function store_gzip_header_range(x::Union{Nothing, UnitRange{Int}})::Tuple{UInt, UInt}
    return isnothing(x) ? (UInt(0), UInt(0)) : (UInt(first(x)), UInt(last(x)))
end

function GzipHeader(
        extra::Union{Nothing, UnitRange{Int}},
        filename::Union{Nothing, UnitRange{Int}},
        comment::Union{Nothing, UnitRange{Int}},
        mtime::Union{NonZeroUInt32, Nothing},
    )
    return GzipHeader(
        store_gzip_header_range(extra),
        store_gzip_header_range(filename),
        store_gzip_header_range(comment),
        isnothing(mtime) ? UInt32(0) : mtime.x,
    )
end

@inline function add_offset_to_range(range::Tuple{UInt, UInt}, offset::UInt)
    range === (UInt(0), UInt(0)) && return (UInt(0), UInt(0))
    return (first(range) + offset, last(range) + offset)
end

function add_offset_to_header(header::GzipHeader, offset::UInt)
    return GzipHeader(
        getfield(header, :extra),
        add_offset_to_range(getfield(header, :filename), offset),
        add_offset_to_range(getfield(header, :comment), offset),
        getfield(header, :mtime)
    )
end

@inline function Base.getproperty(header::GzipHeader, sym::Symbol)
    return if sym === :extra
        load_gzip_header_tuple(getfield(header, :extra))
    elseif sym === :filename
        load_gzip_header_tuple(getfield(header, :filename))
    elseif sym === :comment
        load_gzip_header_tuple(getfield(header, :comment))
    elseif sym === :mtime
        return try_nonzero_uint32(getfield(header, :mtime))
    end
end

function Base.propertynames(::GzipHeader, private::Bool = false)
    return (:extra, :filename, :comment, :mtime)
end

"""
    parse_gzip_header(
        input,
        extra_fields::Vector{GzipExtraField}
    )::Union{
        LibDeflateError, @NamedTuple{read::UInt, header::GzipHeader}
    }

Parse the input data, returning the number of bytes read and a `GzipHeader`, or a
`LibDeflateError`.
The parser empties `extra_fields` before validation, then appends every parsed gzip
extra field to it. The returned header's `extra` range contains the indices of those
fields in `extra_fields`.

# Examples:
```jldoctest
julia> header_bytes = b"\\x1f\\x8b\\x08\\x08\\0\\0\\0\\0\\0\\xff";

julia> bytes = vcat(header_bytes, b"hi", b"\\0"); # gzip header, filename "hi"

julia> fields = GzipExtraField[];

julia> result = parse_gzip_header(bytes, fields);

julia> result.read === UInt(13)
true

julia> String(bytes[result.header.filename])
"hi"
```
"""
function parse_gzip_header(
        in, extra_fields::Vector{GzipExtraField}
    )::Union{LibDeflateError, @NamedTuple{read::UInt, header::GzipHeader}}
    empty!(extra_fields)
    return GC.@preserve in _unsafe_parse_gzip_header(ReadableMemory(in), extra_fields)
end

"""
    unsafe_parse_gzip_header(
        input::ReadableMemory, extra_fields::Vector{GzipExtraField}
    )

Parse the input data, returning the number of bytes read and a `GzipHeader`, or a
`LibDeflateError`.
The parser will not read more than `sizeof(input)` bytes. It empties `extra_fields`
before validation and appends every parsed gzip extra field to it.

# Examples:
```jldoctest
julia> header_bytes = b"\\x1f\\x8b\\x08\\x08\\0\\0\\0\\0\\0\\xff";

julia> bytes = vcat(header_bytes, b"hi", b"\\0"); # gzip header, filename "hi"

julia> fields = GzipExtraField[];

julia> GC.@preserve bytes unsafe_parse_gzip_header(ReadableMemory(bytes), fields).read === UInt(13)
true
```
"""
function unsafe_parse_gzip_header(
        input::ReadableMemory, extra_fields::Vector{GzipExtraField}
    )::Union{LibDeflateError, @NamedTuple{read::UInt, header::GzipHeader}}
    empty!(extra_fields)
    return _unsafe_parse_gzip_header(input, extra_fields)
end

# This function assumes `extra_fields` has been emptied (as it has by all its callers)
function _unsafe_parse_gzip_header(
        input::ReadableMemory, extra_fields::Vector{GzipExtraField}
    )::Union{LibDeflateError, @NamedTuple{read::UInt, header::GzipHeader}}
    first_extra = length(extra_fields) + 1

    # header is at least 10 bytes
    max_len = input.len
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
    mtime = try_nonzero_uint32(ltoh(unsafe_load(Ptr{UInt32}(ptr + 5))))

    # Skip MTIME, XFL, and OS; they are not otherwise useful here.
    index = UInt(11)

    extra = nothing
    if FLAG_EXTRA
        # +---+---+=================================+
        # | XLEN  |...XLEN bytes of "extra field"...| (more-->)
        # +---+---+=================================+
        index + UInt(1) <= max_len ||
            return LibDeflateErrors.gzip_header_too_short
        extra_len = ltoh(unsafe_load(Ptr{UInt16}(ptr + index)))
        UInt(extra_len) <= max_len - index - UInt(1) ||
            return LibDeflateErrors.gzip_extra_too_long
        fields_result = parse_fields!(
            extra_fields, ptr + index + 2, index + UInt(2), extra_len
        )
        fields_result isa LibDeflateError && return fields_result
        extra = first_extra:length(extra_fields)
        index += UInt(extra_len) + UInt(2)
    end

    filename = nothing
    if FLAG_NAME
        # +=========================================+
        # |...original file name, zero-terminated...| (more-->)
        # +=========================================+
        index <= max_len ||
            return LibDeflateErrors.gzip_string_not_null_terminated
        remaining = max_len - index + UInt(1)
        until_zero = bytes_until_zero(ptr + index, remaining)
        until_zero === nothing && return LibDeflateErrors.gzip_string_not_null_terminated
        zero_pos = index + until_zero
        filename = Int(index):Int(zero_pos - one(UInt))
        index = zero_pos + one(UInt)
    end

    # Skip comment
    comment = nothing
    if FLAG_COMMENT
        index <= max_len ||
            return LibDeflateErrors.gzip_string_not_null_terminated
        remaining = max_len - index + UInt(1)
        until_zero = bytes_until_zero(ptr + index, remaining)
        until_zero === nothing && return LibDeflateErrors.gzip_string_not_null_terminated
        zero_pos = index + until_zero
        comment = Int(index):Int(zero_pos - one(UInt))
        index = zero_pos + one(UInt)
    end

    # Verify header CRC16, if present
    if FLAG_HCRC
        # Lower 16 bits of crc32 up to, not including, this index
        # +---+---+
        # | CRC16 |
        # +---+---+
        index + UInt(1) <= max_len ||
            return LibDeflateErrors.gzip_header_too_short
        crc_input = ReadableMemory(ptr + one(UInt), index - one(UInt))
        crc_obs_16 = unsafe_crc32(crc_input) % UInt16
        crc_exp_16 = ltoh(unsafe_load(Ptr{UInt16}(ptr + index)))
        crc_obs_16 == crc_exp_16 || return LibDeflateErrors.gzip_bad_header_crc16
        index += UInt(2)
    end

    return (; read = index - one(UInt), header = GzipHeader(extra, filename, comment, mtime))
end

"""
    GzipDecompressResult

Result of `LibDeflate`'s gzip decompression.

It has the following fields:
* `written::UInt` number of decompressed bytes written
* `read::UInt` number of bytes read from input
* `header::GzipHeader` metadata

# Examples:
```jldoctest
julia> compressed = vcat(
           b"\\x1f\\x8b\\x08\\0\\0\\0\\0\\0\\xff\\0\\x01\\x0d\\0\\xf2\\xff\\x48\\x65\\x6c",
           b"\\x6c\\x6f\\x2c\\x20\\x77\\x6f\\x72\\x6c\\x64\\x21\\xe6\\xc6\\xe6\\xeb\\x0d\\0\\0\\0",
       ); # gzip "Hello, world!"

julia> out = zeros(UInt8, 13);

julia> fields = GzipExtraField[];

julia> result = gzip_decompress!(decompressor, out, compressed, fields);

julia> result.written === UInt(13)
true

julia> String(out)
"Hello, world!"
```
"""
struct GzipDecompressResult
    written::UInt # number of decompressed bytes written
    read::UInt # number of bytes read of the stream
    header::GzipHeader
end

"""
    GzipDecompressAllScratch()
    GzipDecompressAllScratch(extra_fields, member_results)

Storage  used by [`gzip_decompress_all!`](@ref) and
[`unsafe_gzip_decompress_all!`](@ref).

It has the following properties:
* `extra_fields::Vector{GzipExtraField}`: extra fields accumulated from every completed
  member.
* `member_results::Vector{GzipDecompressResult}`: one result for every completed member.

When a `GzipDecompressAllScratch` is passed to a function, the function may
overwrite or empty the scratch. After the function is done, the scratch contains
exactly the `GzipExtraField`s and `GzipDecompressResult`s of the decompress gzip.
"""
struct GzipDecompressAllScratch
    extra_fields::Vector{GzipExtraField}
    member_results::Vector{GzipDecompressResult}
end

function GzipDecompressAllScratch()
    return GzipDecompressAllScratch(GzipExtraField[], GzipDecompressResult[])
end

"""
    GzipDecompressAllResult

Result of successfully decompressing one or more complete gzip members, i.e.
a gzip file composed of multiple, concatenated gzip data.

`GzipDecompressAllResult` is currently a `NamedTuple`, but may be changed to a named
struct in a future release. The type name and properties are part of the public API; users
should refer to the result type as `GzipDecompressAllResult`.

It has the following properties:
* `read::UInt`: total input bytes occupied by the completed members
* `written::UInt`: total decompressed bytes written by the completed members
* `members::UInt`: number of completed members

# Examples:
```jldoctest
julia> combined = vcat(
           b"\\x1f\\x8b\\x08\\0\\0\\0\\0\\0\\xff\\0\\x01\\x05\\0\\xfa",
           b"\\xff\\x48\\x65\\x6c\\x6c\\x6f\\x82\\x89\\xd1\\xf7\\x05\\0\\0\\0",
           b"\\x1f\\x8b\\x08\\0\\0\\0\\0\\0\\xff\\0\\x01\\x05\\0\\xfa",
           b"\\xff\\x57\\x6f\\x72\\x6c\\x64\\x47\\x3e\\xb6\\xfb\\x05\\0\\0\\0",
       ); # gzip "Hello", then gzip "World"

julia> out = zeros(UInt8, 10);

julia> scratch = GzipDecompressAllScratch();

julia> result = gzip_decompress_all!(decompressor, out, combined, scratch);

julia> result.members === UInt(2)
true

julia> String(out)
"HelloWorld"
```
"""
const GzipDecompressAllResult = @NamedTuple{
    read::UInt,
    written::UInt,
    members::UInt,
}

"""
    gzip_decompress!(
        ::Decompressor, output, input,
        extra_fields::Vector{GzipExtraField}
    )::Union{GzipDecompressResult, LibDeflateError}
    
    gzip_decompress!(
        ::Decompressor, output, input, n_out::UInt,
        extra_fields::Vector{GzipExtraField}
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

The function empties `extra_fields` before validation and appends the member's parsed
extra fields to it. The returned header's `extra` range contains the indices of those
fields in `extra_fields`.

# Examples:
```jldoctest
julia> compressed = vcat(
           b"\\x1f\\x8b\\x08\\0\\0\\0\\0\\0\\xff\\0\\x01\\x0d\\0\\xf2\\xff\\x48\\x65\\x6c",
           b"\\x6c\\x6f\\x2c\\x20\\x77\\x6f\\x72\\x6c\\x64\\x21\\xe6\\xc6\\xe6\\xeb\\x0d\\0\\0\\0",
       ); # gzip "Hello, world!"

julia> out = zeros(UInt8, 13);

julia> fields = GzipExtraField[];

julia> gzip_decompress!(decompressor, out, compressed, fields);

julia> String(out)
"Hello, world!"
```
"""
function gzip_decompress!(
        decompressor::Decompressor,
        output,
        input,
        extra_fields::Vector{GzipExtraField},
    )::Union{LibDeflateError, GzipDecompressResult}
    empty!(extra_fields)
    return GC.@preserve input output begin
        _unsafe_gzip_decompress!(
            Base.SizeUnknown(),
            decompressor,
            WriteableMemory(output),
            ReadableMemory(input),
            extra_fields,
        )
    end
end

function gzip_decompress!(
        decompressor::Decompressor,
        output,
        input,
        n_out::UInt,
        extra_fields::Vector{GzipExtraField},
    )::Union{LibDeflateError, GzipDecompressResult}
    empty!(extra_fields)
    return GC.@preserve input output begin
        writable = WriteableMemory(output)
        writable.len < n_out && return LibDeflateErrors.deflate_insufficient_space
        exact_output = WriteableMemory(pointer(writable), n_out)
        _unsafe_gzip_decompress!(
            Base.HasLength(), decompressor, exact_output, ReadableMemory(input), extra_fields
        )
    end
end

"""
    unsafe_gzip_decompress!(
        ::Decompressor, output::WriteableMemory, input::ReadableMemory,
        extra_fields::Vector{GzipExtraField}
    )::Union{LibDeflateError, GzipDecompressResult}
    unsafe_gzip_decompress!(
        ::Decompressor, output::WriteableMemory, input::ReadableMemory, n_out::UInt,
        extra_fields::Vector{GzipExtraField}
    )::Union{LibDeflateError, GzipDecompressResult}

Use the `Decompressor` to decompress the first gzip member in `input` into `output`.
Without `n_out`, `sizeof(output)` is the available capacity. If the exact decompressed
size is known, pass it as `n_out` to use the faster known-size path. Return an error if
the output size is insufficient or incorrect.

Empty `extra_fields` before validation and append the parsed extra fields to it.
Only the first gzip member is decompressed; any following members or trailing
data are left unread.

Return a `GzipDecompressResult` on success.

See also: [`gzip_decompress!`](@ref)

# Examples:
```jldoctest
julia> compressed = vcat(
           b"\\x1f\\x8b\\x08\\0\\0\\0\\0\\0\\xff\\0\\x01\\x0d\\0\\xf2\\xff\\x48\\x65\\x6c",
           b"\\x6c\\x6f\\x2c\\x20\\x77\\x6f\\x72\\x6c\\x64\\x21\\xe6\\xc6\\xe6\\xeb\\x0d\\0\\0\\0",
       ); # gzip "Hello, world!"

julia> out = zeros(UInt8, 13);

julia> fields = GzipExtraField[];

julia> result = GC.@preserve compressed out begin
           unsafe_gzip_decompress!(
               decompressor, WriteableMemory(out), ReadableMemory(compressed), fields
           )
       end;

julia> result.written === UInt(13)
true

julia> String(out)
"Hello, world!"
```
"""
function unsafe_gzip_decompress!(
        decompressor::Decompressor,
        output::WriteableMemory,
        input::ReadableMemory,
        extra_fields::Vector{GzipExtraField},
    )::Union{LibDeflateError, GzipDecompressResult}
    empty!(extra_fields)
    return _unsafe_gzip_decompress!(
        Base.SizeUnknown(), decompressor, output, input, extra_fields
    )
end

function unsafe_gzip_decompress!(
        decompressor::Decompressor,
        output::WriteableMemory,
        in::ReadableMemory,
        n_out::UInt,
        extra_fields::Vector{GzipExtraField},
    )::Union{LibDeflateError, GzipDecompressResult}
    empty!(extra_fields)
    output.len < n_out && return LibDeflateErrors.deflate_insufficient_space
    exact_output = WriteableMemory(pointer(output), n_out)
    return _unsafe_gzip_decompress!(
        Base.HasLength(), decompressor, exact_output, in, extra_fields
    )
end

function _unsafe_gzip_decompress!(
        size::Union{Base.SizeUnknown, Base.HasLength},
        decompressor::Decompressor,
        output::WriteableMemory,
        in::ReadableMemory,
        extra_fields::Vector{GzipExtraField},
    )::Union{LibDeflateError, GzipDecompressResult}
    # We need to have at least 2 + 4 + 4 bytes left after header
    nonheader_min_len = UInt(10)
    len = in.len
    len < nonheader_min_len && return LibDeflateErrors.gzip_header_too_short

    # First decompress header
    header_input = ReadableMemory(pointer(in), len - nonheader_min_len)
    hdr_result = _unsafe_parse_gzip_header(header_input, extra_fields)
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
    trailer_offset = header_len + consumed
    len - trailer_offset >= UInt(8) || return LibDeflateErrors.gzip_header_too_short
    trailer_ptr = Ptr{UInt8}(pointer(in)) + trailer_offset
    size_exp = ltoh(unsafe_load(Ptr{UInt32}(trailer_ptr + 4)))
    size_exp == uncompressed_size % UInt32 ||
        return LibDeflateErrors.deflate_bad_payload

    # Check for CRC checksum and validate it
    crc_exp = ltoh(unsafe_load(Ptr{UInt32}(trailer_ptr)))
    crc_input = ReadableMemory(pointer(output), uncompressed_size)
    crc_obs = unsafe_crc32(crc_input)
    crc_exp == crc_obs || return LibDeflateErrors.gzip_bad_crc32

    total_read = trailer_offset + UInt(8)
    return GzipDecompressResult(uncompressed_size, total_read, header)
end

"""
    gzip_decompress_all!(
        ::Decompressor, output, input, scratch::GzipDecompressAllScratch
    )::Union{
        GzipDecompressAllResult,
        Tuple{GzipDecompressAllResult, LibDeflateError},
    }

Decompress every member of a gzip file in `input` into the fixed-size buffer `output`.
The input must contain at least one complete member and no trailing data.

On success, return `GzipDecompressAllResult` with statistics of the decompression result.
If an error is encountered, return a tuple containing the same statistics for all
members completed before the error, followed by the `LibDeflateError`.

Empty both vectors in `scratch` before validation. On return, `scratch.extra_fields`
contains fields from every completed member and `scratch.member_results` contains one
result per completed member. A failing member contributes to neither vector.
Custom input and output types can opt in by implementing `ReadableMemory(input)`
and `WriteableMemory(output)`, respectively.

See also: [`gzip_decompress!`](@ref), [`unsafe_gzip_decompress_all!`](@ref)

# Examples:
```jldoctest
julia> combined = vcat(
           b"\\x1f\\x8b\\x08\\0\\0\\0\\0\\0\\xff\\0\\x01\\x05\\0\\xfa",
           b"\\xff\\x48\\x65\\x6c\\x6c\\x6f\\x82\\x89\\xd1\\xf7\\x05\\0\\0\\0",
           b"\\x1f\\x8b\\x08\\0\\0\\0\\0\\0\\xff\\0\\x01\\x05\\0\\xfa",
           b"\\xff\\x57\\x6f\\x72\\x6c\\x64\\x47\\x3e\\xb6\\xfb\\x05\\0\\0\\0",
       ); # gzip "Hello", then gzip "World"

julia> out = zeros(UInt8, 10);

julia> scratch = GzipDecompressAllScratch();

julia> result = gzip_decompress_all!(decompressor, out, combined, scratch);

julia> result.members === UInt(2)
true

julia> String(out)
"HelloWorld"
```
"""
function gzip_decompress_all!(
        decompressor::Decompressor,
        output,
        input,
        scratch::GzipDecompressAllScratch,
    )::Union{
        GzipDecompressAllResult,
        Tuple{GzipDecompressAllResult, LibDeflateError},
    }
    empty!(scratch.extra_fields)
    empty!(scratch.member_results)
    return GC.@preserve input output begin
        _unsafe_gzip_decompress_all!(
            decompressor,
            WriteableMemory(output),
            ReadableMemory(input),
            scratch,
        )
    end
end

"""
    unsafe_gzip_decompress_all!(
        ::Decompressor, output::WriteableMemory, input::ReadableMemory,
        scratch::GzipDecompressAllScratch
    )::Union{
        GzipDecompressAllResult,
        Tuple{GzipDecompressAllResult, LibDeflateError},
    }

Unsafe variant of [`gzip_decompress_all!`](@ref). Decompress every member of a gzip file
in `input` into `output`. The input must contain at least one complete member and no
trailing data.

On success, return `GzipDecompressAllResult` with statistics of the decompression result.
If an error is encountered, return a tuple containing the same statistics for all
members completed before the error, followed by the `LibDeflateError`.

Empty both vectors in `scratch` before validation. On return, `scratch.extra_fields`
contains fields from every completed member and `scratch.member_results` contains one
result per completed member. A failing member contributes to neither vector.

See also: [`gzip_decompress_all!`](@ref).

# Examples:
```jldoctest
julia> combined = vcat(
           b"\\x1f\\x8b\\x08\\0\\0\\0\\0\\0\\xff\\0\\x01\\x05\\0\\xfa",
           b"\\xff\\x48\\x65\\x6c\\x6c\\x6f\\x82\\x89\\xd1\\xf7\\x05\\0\\0\\0",
           b"\\x1f\\x8b\\x08\\0\\0\\0\\0\\0\\xff\\0\\x01\\x05\\0\\xfa",
           b"\\xff\\x57\\x6f\\x72\\x6c\\x64\\x47\\x3e\\xb6\\xfb\\x05\\0\\0\\0",
       ); # gzip "Hello", then gzip "World"

julia> out = zeros(UInt8, 10);

julia> scratch = GzipDecompressAllScratch();

julia> result = GC.@preserve combined out begin
           w = WriteableMemory(out)
           r = ReadableMemory(combined)
           unsafe_gzip_decompress_all!(decompressor, w, r, scratch)
       end;

julia> result.members === UInt(2)
true

julia> String(out)
"HelloWorld"
```
"""
function unsafe_gzip_decompress_all!(
        decompressor::Decompressor,
        output::WriteableMemory,
        input::ReadableMemory,
        scratch::GzipDecompressAllScratch,
    )::Union{
        GzipDecompressAllResult,
        Tuple{GzipDecompressAllResult, LibDeflateError},
    }
    empty!(scratch.extra_fields)
    empty!(scratch.member_results)
    return _unsafe_gzip_decompress_all!(decompressor, output, input, scratch)
end

function _unsafe_gzip_decompress_all!(
        decompressor::Decompressor,
        output::WriteableMemory,
        input::ReadableMemory,
        scratch::GzipDecompressAllScratch,
    )::Union{
        GzipDecompressAllResult,
        Tuple{GzipDecompressAllResult, LibDeflateError},
    }
    extra_fields = scratch.extra_fields
    member_results = scratch.member_results
    input_size = input.len
    output_size = output.len
    read = zero(UInt)
    written = zero(UInt)
    members = zero(UInt)

    while read < input_size || iszero(members)
        # A malformed member may increase the length of `extra_fields`;
        # we keep track of the length here to reset it upon an error
        previous_extra_count = length(extra_fields)
        member_input = ReadableMemory(
            pointer(input) + read, input_size - read
        )
        member_output = WriteableMemory(
            pointer(output) + written, output_size - written
        )
        result = _unsafe_gzip_decompress!(
            Base.SizeUnknown(), decompressor, member_output, member_input, extra_fields
        )
        if result isa LibDeflateError
            resize!(extra_fields, previous_extra_count)
            completed = GzipDecompressAllResult((; read, written, members))
            return (completed, result)
        end

        # The added extra fields now have the wrong offsets, so we need to update them
        if !iszero(read)
            @inbounds for index in (previous_extra_count + 1):length(extra_fields)
                field = extra_fields[index]
                extra_fields[index] = GzipExtraField(
                    field.data_start + read, field.data_length, field.tag
                )
            end
        end

        header = result.header
        member_header = add_offset_to_header(header, read)
        push!(
            member_results,
            GzipDecompressResult(result.written, result.read, member_header),
        )

        read += result.read
        written += result.written
        members += one(UInt)
    end

    return GzipDecompressAllResult((; read, written, members))
end

function gzip_wrapper_size(
        comment_len::Union{Nothing, UInt},
        filename_len::Union{Nothing, UInt},
        extra_len::Union{Nothing, UInt16},
        header_crc::Bool,
    )::UInt
    size = UInt(18)
    comment_len === nothing || (size += comment_len + one(UInt))
    filename_len === nothing || (size += filename_len + one(UInt))
    extra_len === nothing || (size += UInt(extra_len) + UInt(2))
    size += ifelse(header_crc, UInt(2), zero(UInt))
    return size
end

"""
    gzip_compress_bound(
        compressor::Compressor, input_size::UInt;
        comment_len=nothing, filename_len=nothing, extra_len=nothing, header_crc=false
    )::UInt

Return a worst-case upper bound on the number of bytes produced by
[`gzip_compress!`](@ref) with the given input and metadata sizes. A metadata length of
`nothing` means that the corresponding optional field will not be present, while `0`
represents a present but empty field. Pass `UInt(0)` or `UInt16(0)`, as appropriate.

The bound may overestimate the required space, but an output buffer of this size is
guaranteed to be sufficient. This calculation does not inspect any input or metadata
and is constant-time with respect to all supplied sizes.

# Examples:
```jldoctest
julia> bound = gzip_compress_bound(compressor, UInt(100));

julia> bound_with_name = gzip_compress_bound(compressor, UInt(100); filename_len=UInt(8));

julia> bound_with_name > bound
true
```
"""
function gzip_compress_bound(
        compressor::Compressor,
        input_size::UInt;
        comment_len::Union{Nothing, UInt} = nothing,
        filename_len::Union{Nothing, UInt} = nothing,
        extra_len::Union{Nothing, UInt16} = nothing,
        header_crc::Bool = false,
    )::UInt
    wrapper_size = gzip_wrapper_size(comment_len, filename_len, extra_len, header_crc)
    return deflate_compress_bound(compressor, input_size) + wrapper_size
end

"""
    gzip_compress!(
        compressor::Compressor,
        output,
        input;
        comment=nothing,
        filename=nothing,
        extra=nothing,
        mtime::Union{NonZeroUInt32, Nothing} = nothing,
        header_crc::Bool=false
    )::Union{LibDeflateError, UInt}

Compress `input` as gzip data into the fixed-size buffer `output`, returning the
number of bytes written or `LibDeflate.deflate_insufficient_space` if it does not fit.
The output is never resized.

Use [`gzip_compress_bound`](@ref) to determine an output size that is guaranteed to
be sufficient. Custom input, output, and metadata types can opt in by implementing
`ReadableMemory` and `WriteableMemory`.

`mtime` is the modification time in seconds since the Unix epoch, or `nothing` if
not available.

# Examples:
```jldoctest
julia> data = b"Hello, world!";

julia> out = zeros(UInt8, gzip_compress_bound(compressor, UInt(sizeof(data))));

julia> n = gzip_compress!(compressor, out, data);

julia> out[1:3] == b"\\x1f\\x8b\\x08" # gzip magic bytes and DEFLATE method
true

julia> out[(n - 3):n] == b"\\x0d\\0\\0\\0" # ISIZE trailer: length of "Hello, world!"
true
```
"""
function gzip_compress!(
        compressor::Compressor,
        output,
        input;
        comment = nothing,
        filename = nothing,
        extra = nothing,
        mtime::Union{NonZeroUInt32, Nothing} = nothing,
        header_crc::Bool = false,
    )::Union{LibDeflateError, UInt}
    return GC.@preserve output input comment filename extra begin
        _gzip_compress!(
            compressor,
            WriteableMemory(output),
            ReadableMemory(input),
            comment === nothing ? nothing : ReadableMemory(comment),
            filename === nothing ? nothing : ReadableMemory(filename),
            extra === nothing ? nothing : ReadableMemory(extra),
            mtime,
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
        mtime::Union{NonZeroUInt32, Nothing} = nothing,
        header_crc::Bool = false,
    )::Union{LibDeflateError, UInt}
    return unsafe_gzip_compress!(
        compressor, output, input;
        comment, filename, extra, mtime, header_crc,
    )
end

"""
    unsafe_gzip_compress!(
        compressor::Compressor,
        out::WriteableMemory,
        in::ReadableMemory;
        comment::Union{Nothing, ReadableMemory} = nothing,
        filename::Union{Nothing, ReadableMemory} = nothing,
        extra::Union{Nothing, ReadableMemory} = nothing,
        mtime::Union{NonZeroUInt32, Nothing} = nothing,
        header_crc::Bool=false,
    )::Union{LibDeflateError, UInt}

Use the `Compressor` to gzip compress input at `pointer(in)` and `sizeof(in)` bytes onwards
to, `pointer(out)`.
If the resulting gzip data does not fit in `sizeof(out)`, return
`LibDeflate.deflate_insufficient_space`.
Optionally, include gzip comment, filename or extra data. All these are omitted if left
at their default of `nothing`.

Adds optional data `comment`, `filename`, `extra`.
* `comment` and `filename` must not include the byte `0x00`.
* `extra` must be at most `typemax(UInt16)` bytes long.

`mtime` is the modification time in seconds since the Unix epoch, or `nothing`
if not available.

Returns the number of bytes written to `pointer(out)`.

See also: [`gzip_compress!`](@ref)

# Examples:
```jldoctest
julia> data = b"Hello, world!";

julia> out = zeros(UInt8, gzip_compress_bound(compressor, UInt(sizeof(data))));

julia> n = GC.@preserve data out begin
           unsafe_gzip_compress!(compressor, WriteableMemory(out), ReadableMemory(data))
       end;

julia> out[1:3] == b"\\x1f\\x8b\\x08" # gzip magic bytes and DEFLATE method
true

julia> out[(n - 3):n] == b"\\x0d\\0\\0\\0" # ISIZE trailer: length of "Hello, world!"
true
```
"""
function unsafe_gzip_compress!(
        compressor::Compressor,
        out::WriteableMemory,
        in::ReadableMemory;
        comment::Union{Nothing, ReadableMemory} = nothing,
        filename::Union{Nothing, ReadableMemory} = nothing,
        extra::Union{Nothing, ReadableMemory} = nothing,
        mtime::Union{Nothing, NonZeroUInt32} = nothing,
        header_crc::Bool = false,
    )::Union{LibDeflateError, UInt}
    out_len = out.len
    extra_len = extra === nothing ? nothing : UInt16(extra.len)
    wrapper_size = gzip_wrapper_size(
        comment === nothing ? nothing : comment.len,
        filename === nothing ? nothing : filename.len,
        extra_len,
        header_crc,
    )
    out.len < wrapper_size && return LibDeflateErrors.deflate_insufficient_space

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

    # Add modification time
    u_mtime = isnothing(mtime) ? UInt32(0) : mtime.x
    unsafe_store!(Ptr{UInt32}(ptr + 5), htol(u_mtime))

    # Add system (unknown) and XFL (zero)
    unsafe_store!(Ptr{UInt16}(ptr + 9), htol(0x00ff))

    index = UInt(11)

    # Add in extra data
    if extra !== nothing
        unsafe_store!(Ptr{UInt16}(ptr + index), htol(something(extra_len)))
        unsafe_copyto!(ptr + index + 2, Ptr{UInt8}(pointer(extra)), extra.len)
        index += UInt(2) + extra.len
    end

    # Add in filename
    if filename !== nothing
        unsafe_copyto!(ptr + index, Ptr{UInt8}(pointer(filename)), filename.len)
        index += filename.len + one(UInt) # null byte
        unsafe_store!(ptr + index - 1, 0x00)
    end

    # Add in comment
    if comment !== nothing
        unsafe_copyto!(ptr + index, Ptr{UInt8}(pointer(comment)), comment.len)
        index += comment.len + one(UInt) # null byte
        unsafe_store!(ptr + index - 1, 0x00)
    end

    # Add in CRC16
    if header_crc
        crc_input = ReadableMemory(ptr + one(UInt), index - one(UInt))
        header_crc16 = unsafe_crc32(crc_input) % UInt16
        unsafe_store!(Ptr{UInt16}(ptr + index), htol(header_crc16))
        index += UInt(2)
    end

    # Add in compressed data
    remaining_out_data = out_len - index + one(UInt) - UInt(8) # tail
    compress_to = WriteableMemory(ptr + index, remaining_out_data)
    n_compressed = unsafe_compress!(compressor, compress_to, in)
    n_compressed isa LibDeflateError && return n_compressed
    index += n_compressed

    # Add in crc32 of uncompressed data
    crc = unsafe_crc32(in)
    unsafe_store!(Ptr{UInt32}(ptr + index), htol(crc))
    index += UInt(4)

    # Add in isize (uncompressed size)
    unsafe_store!(Ptr{UInt32}(ptr + index), htol(in.len % UInt32))
    return index + UInt(3) # 4 bytes isize - off-by-one
end
