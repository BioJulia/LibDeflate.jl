data_test_cases = [
    [0x42, 0x43, 0x02, 0x00, 0xa1, 0x4c],
    [0x02, 0x03, 0x00, 0x00],
    [
        0x00, 0x01, 0x04, 0x00, 0x01, 0x02, 0x03, 0x04,
        0xff, 0xf1, 0x01, 0x00, 0xff,
    ],
]

@testset "Is valid data" begin
    test_valid(v) = is_valid_extra_data(v)
    test_unsafe_valid(v) = GC.@preserve v unsafe_is_valid_extra_data(ReadableMemory(v))
    for data in data_test_cases
        @test test_valid(data)
        @test test_unsafe_valid(data)
        # Subfield IDs with SI2 == 0 are reserved, but remain structurally valid.
        data[2] = 0x00
        @test test_valid(data)
        @test test_unsafe_valid(data)
        data[2] = 0xff
        push!(data, 0x00)
        @test !test_valid(data)
        pop!(data)
        @test !test_valid(data[1:(end - 1)])
        data = empty!(copy(data))
        @test test_valid(data)
    end
    @test is_valid_extra_data(CustomReadable(first(data_test_cases)))
    @test !is_valid_extra_data(zeros(UInt8, Int(typemax(UInt16)) + 1))
end

header_data = UInt8[
    # header
    0x1f, 0x8b, 0x08, 0x1e, 0xb3, 0x2c, 0x51, 0x60, 0xff, 0x00,

    # Extra data
    0x0a, 0x00, 0x42, 0x43, 0x02, 0x00, 0xa1, 0x4c,
    0x02, 0x03, 0x00, 0x00,

    # Filename: "filename.fna"
    0x66, 0x69, 0x6c, 0x65, 0x6e, 0x61, 0x6d, 0x65, 0x2e, 0x66, 0x6e, 0x61, 0x00,

    # Complicated unicode comment "αβ学中文"
    0xce, 0xb1, 0xce, 0xb2, 0xe5, 0xad, 0xa6, 0xe4, 0xb8, 0xad, 0xe6, 0x96, 0x87, 0x00,

    # CRC16
    0x78, 0x18,
]

function make_empty_extra_field()
    input = UInt8[
        0x1f, 0x8b, 0x08, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
        0x04, 0x00, 0x01, 0x01, 0x00, 0x00,
    ]
    fields = GzipExtraField[]
    result = parse_gzip_header(input, fields)
    result isa LibDeflateError && error("failed to parse empty gzip extra field")
    return only(fields)
end

function test_header_example(
        data::Vector{UInt8},
        extra_fields::Vector{GzipExtraField},
        header::LibDeflate.GzipHeader,
    )
    @test header.mtime == NonZeroUInt32(0x60512cb3)
    @test length(header.extra) == 2
    extras = extra_fields[header.extra]
    @test first(extras).tag == (0x42, 0x43)
    @test first(extras).data == UInt(17):UInt(18)
    @test data[first(extras).data] == UInt8[0xa1, 0x4c]
    @test last(extras).tag == (0x02, 0x03)
    @test last(extras).data == UInt(23):UInt(22) # empty extra
    @test isempty(data[last(extras).data])
    @test String(data[header.filename]) == "filename.fna"
    @test String(data[header.comment]) == "αβ学中文"
    return true
end

@testset "Parse header" begin
    extra_fields = GzipExtraField[]
    empty_extra = make_empty_extra_field()
    @test empty_extra.data isa UnitRange{UInt}
    @test empty_extra.data == UInt(17):UInt(16)
    @test isempty(empty_extra.data)
    @test propertynames(empty_extra) == (:tag, :data)
    @test hasproperty(empty_extra, :data)
    @test Sys.WORD_SIZE != 64 || sizeof(GzipExtraField) == 16
    @test Sys.WORD_SIZE != 64 || sizeof(GzipHeader) == 56

    result = GC.@preserve header_data unsafe_parse_gzip_header(
        ReadableMemory(header_data), extra_fields
    )
    @test result.read == length(header_data)
    @test result.read isa UInt
    header = result.header
    @test header.mtime isa NonZeroUInt32
    @test header.extra isa UnitRange{UInt}
    @test header.filename isa UnitRange{UInt}
    @test header.comment isa UnitRange{UInt}
    @test propertynames(header) == (:extra, :filename, :comment, :mtime)
    @test first(extra_fields[header.extra]).data isa UnitRange{UInt}
    test_header_example(header_data, extra_fields, header)

    result = parse_gzip_header(header_data, extra_fields)
    @test result.read == length(header_data)
    header = result.header
    test_header_example(header_data, extra_fields, header)

    result = GC.@preserve header_data unsafe_parse_gzip_header(
        ReadableMemory(header_data), extra_fields
    )
    header = result.header
    test_header_example(header_data, extra_fields, header)

    header_data[end - 2] = 0x01
    @test GC.@preserve header_data unsafe_parse_gzip_header(
        ReadableMemory(header_data), extra_fields
    ) == LibDeflateErrors.gzip_string_not_null_terminated
    header_data[end - 2] = 0x00

    minimal_data = UInt8[
        0x1f, 0x8b, 0x08, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xff, 0x06, 0x00, 0x42, 0x43, 0x02, 0x00, 0x10, 0x20,
    ]
    result = parse_gzip_header(minimal_data, extra_fields)
    @test result.read == 18
    header = result.header
    ex = only(extra_fields[header.extra])
    @test ex.tag == (0x42, 0x43)
    @test ex.data == 17:18

    # Reusing extra storage must not retain entries from a previous header.
    header = parse_gzip_header(header_data, extra_fields).header
    @test header.extra isa UnitRange{UInt}
    @test header.extra == UInt(1):UInt(length(extra_fields))
    @test !isempty(extra_fields)

    header_without_extra = UInt8[
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
    ]
    header = parse_gzip_header(header_without_extra, extra_fields).header
    @test header.extra === nothing
    @test isempty(extra_fields)

    # Reused output is cleared before validation and therefore also on early errors.
    sentinel = make_empty_extra_field()
    push!(extra_fields, sentinel)
    @test parse_gzip_header(UInt8[], extra_fields) ==
        LibDeflateErrors.gzip_header_too_short
    @test isempty(extra_fields)
    push!(extra_fields, sentinel)
    short_header = header_without_extra[1:9]
    @test GC.@preserve short_header unsafe_parse_gzip_header(
        ReadableMemory(short_header), extra_fields
    ) == LibDeflateErrors.gzip_header_too_short
    @test isempty(extra_fields)

    @test_throws MethodError parse_gzip_header(header_data)
    @test_throws MethodError unsafe_parse_gzip_header(ReadableMemory(header_data))
end

@testset "Reserved flags" begin
    extra_fields = GzipExtraField[]
    base_header = UInt8[
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
    ]
    for reserved_flags in (0x20, 0x40, 0x80, 0xe0)
        header = copy(base_header)
        header[4] = reserved_flags
        @test parse_gzip_header(header, extra_fields) == LibDeflateErrors.gzip_bad_flags
    end
end

@testset "Truncated headers" begin
    extra_fields = GzipExtraField[]
    base_header = UInt8[
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
    ]

    for len in 0:9
        @test parse_gzip_header(base_header[1:len], extra_fields) ==
            LibDeflateErrors.gzip_header_too_short
    end

    extra_header = copy(base_header)
    extra_header[4] = 0x04
    @test parse_gzip_header(extra_header, extra_fields) ==
        LibDeflateErrors.gzip_header_too_short
    @test parse_gzip_header(vcat(extra_header, 0x00), extra_fields) ==
        LibDeflateErrors.gzip_header_too_short

    # XLEN may be zero, including when it ends exactly at the input boundary.
    empty_extra = vcat(extra_header, 0x00, 0x00)
    result = parse_gzip_header(empty_extra, extra_fields)
    @test result.read == 12
    header = result.header
    @test header.extra !== nothing
    @test isempty(header.extra)

    truncated_extra = vcat(extra_header, 0x04, 0x00, 0x42, 0x43, 0x00)
    @test parse_gzip_header(truncated_extra, extra_fields) ==
        LibDeflateErrors.gzip_extra_too_long

    for flag in (0x08, 0x10)
        string_header = copy(base_header)
        string_header[4] = flag
        @test parse_gzip_header(string_header, extra_fields) ==
            LibDeflateErrors.gzip_string_not_null_terminated
        @test parse_gzip_header(
            vcat(string_header, codeunits("unterminated")), extra_fields
        ) ==
            LibDeflateErrors.gzip_string_not_null_terminated
    end

    crc_header = copy(base_header)
    crc_header[4] = 0x02
    @test parse_gzip_header(crc_header, extra_fields) ==
        LibDeflateErrors.gzip_header_too_short
    @test parse_gzip_header(vcat(crc_header, 0x00), extra_fields) ==
        LibDeflateErrors.gzip_header_too_short

    name_crc_header = copy(base_header)
    name_crc_header[4] = 0x0a
    @test parse_gzip_header(vcat(name_crc_header, 0x00), extra_fields) ==
        LibDeflateErrors.gzip_header_too_short
    @test parse_gzip_header(vcat(name_crc_header, 0x00, 0x00), extra_fields) ==
        LibDeflateErrors.gzip_header_too_short
end


test_data = [
    "",
    "Abracadabra!",
    "En af dem der red med fane",
    rand(UInt8, 1000),
]

test_comment = "This is a comment"
test_filename = "testfile.foo"

@testset "Compression" begin
    compressor = Compressor()
    extra_fields = GzipExtraField[]
    for data in test_data
        bound = gzip_compress_bound(
            compressor,
            UInt(sizeof(data));
            comment_len = UInt(sizeof(test_comment)),
            filename_len = UInt(sizeof(test_filename)),
            extra_len = UInt16(sizeof(data_test_cases[1])),
            header_crc = true,
        )
        outdata = zeros(UInt8, bound)
        n_bytes = GC.@preserve data outdata unsafe_gzip_compress!(
            compressor, WriteableMemory(outdata), ReadableMemory(data);
            comment = LibDeflate.ReadableMemory(test_comment),
            filename = LibDeflate.ReadableMemory(test_filename),
            extra = LibDeflate.ReadableMemory(data_test_cases[1]),
            header_crc = true,
        )
        @test n_bytes isa UInt
        @test n_bytes <= bound
        @test length(outdata) == bound
        decompressed = transcode(GzipDecompressor, outdata[1:n_bytes])
        @test decompressed == Vector{UInt8}(data)

        fill!(outdata, 0x00)
        n_bytes = gzip_compress!(
            compressor, outdata, data;
            comment = test_comment,
            filename = test_filename,
            extra = data_test_cases[1],
            header_crc = true,
        )
        @test n_bytes isa UInt
        @test n_bytes <= bound
        @test length(outdata) == bound
        decompressed = transcode(GzipDecompressor, outdata[1:n_bytes])
        @test decompressed == Vector{UInt8}(data)
    end

    data = UInt8.(0:99)
    input = CustomReadable(data)
    @test sizeof(input) < sizeof(ReadableMemory(input))

    bound = gzip_compress_bound(compressor, UInt(sizeof(input.data)))
    output = CustomWriteable(zeros(UInt8, bound))
    n_bytes = gzip_compress!(compressor, output, input)
    @test n_bytes isa UInt
    @test transcode(GzipDecompressor, output.data[1:n_bytes]) == data

    mtime_output = zeros(UInt8, gzip_compress_bound(compressor, UInt(sizeof(data))))
    n_bytes = gzip_compress!(compressor, mtime_output, data)
    @test parse_gzip_header(mtime_output[1:n_bytes], extra_fields).header.mtime === nothing

    explicit_mtime = NonZeroUInt32(0x12345678)
    n_bytes = GC.@preserve data mtime_output unsafe_gzip_compress!(
        compressor, WriteableMemory(mtime_output), ReadableMemory(data); mtime = explicit_mtime
    )
    @test parse_gzip_header(mtime_output[1:n_bytes], extra_fields).header.mtime ==
        explicit_mtime

    base_bound = gzip_compress_bound(compressor, UInt(0))
    @test base_bound isa UInt
    @test gzip_compress_bound(compressor, UInt(0); comment_len = UInt(0)) ==
        base_bound + UInt(1)
    @test gzip_compress_bound(compressor, UInt(0); filename_len = UInt(0)) ==
        base_bound + UInt(1)
    @test gzip_compress_bound(compressor, UInt(0); extra_len = UInt16(0)) ==
        base_bound + UInt(2)
    @test gzip_compress_bound(compressor, UInt(0); header_crc = true) ==
        base_bound + UInt(2)
    @test gzip_compress_bound(compressor, UInt(0); comment_len = typemax(UInt)) ==
        LibDeflateErrors.overflow
    @test gzip_compress_bound(compressor, typemax(UInt)) == LibDeflateErrors.overflow
    for (bound_options, compress_options) in (
            ((; comment_len = UInt(0)), (; comment = "")),
            ((; filename_len = UInt(0)), (; filename = "")),
            ((; extra_len = UInt16(0)), (; extra = UInt8[])),
        )
        bound = gzip_compress_bound(compressor, UInt(0); bound_options...)
        output = zeros(UInt8, bound)
        n_bytes = gzip_compress!(compressor, output, ""; compress_options...)
        @test transcode(GzipDecompressor, output[1:n_bytes]) == UInt8[]
    end

    @test gzip_compress!(compressor, zeros(UInt8, 17), "") ==
        LibDeflateErrors.deflate_insufficient_space
    fixed_output = zeros(UInt8, 18)
    @test gzip_compress!(compressor, fixed_output, "") ==
        LibDeflateErrors.deflate_insufficient_space
    @test length(fixed_output) == 18
    oversized_extra_len = Int(typemax(UInt16)) + 1
    @test_throws TypeError gzip_compress_bound(
        compressor, UInt(0); extra_len = oversized_extra_len
    )
    @test_throws InexactError UInt16(oversized_extra_len)
    oversized_extra = zeros(UInt8, oversized_extra_len)
    @test_throws InexactError gzip_compress!(compressor, UInt8[], ""; extra = oversized_extra)
    @test_throws MethodError gzip_compress_bound(compressor, 0)
    @test_throws TypeError gzip_compress_bound(
        compressor, UInt(0); comment_len = 0
    )
    @test_throws TypeError gzip_compress!(compressor, UInt8[], ""; mtime = 0)
end


complex_test_case = vcat(
    header_data, UInt8[
        # Data: compressed "Abracadabra"
        0x01, 0x0b, 0x00, 0xf4, 0xff, 0x41, 0x62, 0x72, 0x61, 0x63, 0x61, 0x64, 0x61, 0x62, 0x72, 0x61,

        # CRC32
        0x60, 0x76, 0x76, 0x91,

        # isize
        0x0b, 0x00, 0x00, 0x00,
    ]
)

@testset "Decompression" begin
    decompressor = Decompressor()
    outdata = zeros(UInt8, 1001)

    sentinel = make_empty_extra_field()
    extra_fields = [sentinel]
    @test gzip_decompress!(decompressor, outdata, UInt8[], extra_fields) ==
        LibDeflateErrors.gzip_header_too_short
    @test isempty(extra_fields)
    push!(extra_fields, sentinel)
    empty_input = UInt8[]
    @test GC.@preserve outdata empty_input unsafe_gzip_decompress!(
        decompressor, WriteableMemory(outdata), ReadableMemory(empty_input), extra_fields
    ) == LibDeflateErrors.gzip_header_too_short
    @test isempty(extra_fields)
    push!(extra_fields, sentinel)
    @test gzip_decompress!(
        decompressor, UInt8[], UInt8[], UInt(1), extra_fields
    ) == LibDeflateErrors.deflate_insufficient_space
    @test isempty(extra_fields)
    push!(extra_fields, sentinel)
    empty_output = UInt8[]
    @test GC.@preserve empty_output empty_input unsafe_gzip_decompress!(
        decompressor,
        WriteableMemory(empty_output),
        ReadableMemory(empty_input),
        UInt(1),
        extra_fields,
    ) == LibDeflateErrors.deflate_insufficient_space
    @test isempty(extra_fields)

    for len in 0:19
        @test gzip_decompress!(decompressor, outdata, zeros(UInt8, len), extra_fields) ==
            LibDeflateErrors.gzip_header_too_short
    end

    for data in test_data
        compressed = transcode(GzipCompressor, data)
        expected = Vector{UInt8}(data)

        result = GC.@preserve compressed unsafe_gzip_decompress!(
            decompressor, WriteableMemory(outdata), ReadableMemory(compressed), extra_fields
        )
        @test outdata[1:result.written] == expected
        @test result.read == length(compressed)

        result = GC.@preserve compressed unsafe_gzip_decompress!(
            decompressor,
            WriteableMemory(outdata),
            ReadableMemory(compressed),
            UInt(length(expected)),
            extra_fields,
        )
        @test outdata[1:result.written] == expected
        @test result.read == length(compressed)

        fill!(outdata, 0x00)
        result = gzip_decompress!(decompressor, outdata, compressed, extra_fields)
        @test outdata[1:result.written] == expected
        @test result.read == length(compressed)
        @test length(outdata) == 1001

        fill!(outdata, 0x00)
        result = gzip_decompress!(
            decompressor, outdata, compressed, UInt(length(expected)), extra_fields
        )
        @test result.written isa UInt
        @test result.read isa UInt
        @test outdata[1:result.written] == expected
        @test result.written == length(expected)
        @test result.read == length(compressed)

        @test gzip_decompress!(
            decompressor, outdata, compressed, UInt(length(expected) + 1), extra_fields
        ) == LibDeflateErrors.deflate_output_too_short
        @test_throws MethodError gzip_decompress!(
            decompressor, outdata, compressed, length(expected), extra_fields
        )
        if !isempty(expected)
            @test gzip_decompress!(
                decompressor,
                outdata,
                compressed,
                UInt(length(expected) - 1),
                extra_fields,
            ) == LibDeflateErrors.deflate_insufficient_space
            @test gzip_decompress!(
                decompressor,
                view(outdata, 1:(length(expected) - 1)),
                compressed,
                UInt(length(expected)),
                extra_fields,
            ) == LibDeflateErrors.deflate_insufficient_space
        end

        if !isempty(expected)
            small_output = zeros(UInt8, length(expected) - 1)
            @test gzip_decompress!(decompressor, small_output, compressed, extra_fields) ==
                LibDeflateErrors.deflate_insufficient_space
        end
    end

    custom_output = CustomWriteable(zeros(UInt8, 32))
    compressed = transcode(GzipCompressor, "custom output")
    result = gzip_decompress!(
        decompressor,
        custom_output,
        CustomReadable(compressed),
        UInt(sizeof("custom output")),
        extra_fields,
    )
    @test String(custom_output.data[1:result.written]) == "custom output"

    extra_fields = [make_empty_extra_field()]
    result = gzip_decompress!(decompressor, outdata, compressed, extra_fields)
    @test result isa GzipDecompressResult
    @test isempty(extra_fields)

    compressed = transcode(GzipCompressor, "five bytes")
    small_output = zeros(UInt8, 5)
    original_length = length(small_output)
    @test gzip_decompress!(decompressor, small_output, compressed, extra_fields) ==
        LibDeflateErrors.deflate_insufficient_space
    @test length(small_output) == original_length

    # RFC 1952 permits concatenated members.  This API deliberately returns
    # only the first member, leaving the remainder unread.
    first_member = transcode(GzipCompressor, "first member")
    second_member = transcode(GzipCompressor, "second member is longer")
    concatenated = vcat(first_member, second_member)
    result = gzip_decompress!(decompressor, outdata, concatenated, extra_fields)
    @test result.written == sizeof("first member")
    @test result.read == length(first_member)
    @test outdata[1:result.written] == Vector{UInt8}(codeunits("first member"))

    # Hard test case
    res = gzip_decompress!(decompressor, outdata, complex_test_case, extra_fields)
    test_header_example(complex_test_case, extra_fields, res.header)
    @test res.written == 11
    @test res.read == length(complex_test_case)

    compressed = transcode(GzipCompressor, "trailing payload")
    trailing_payload = vcat(
        compressed[1:(end - 8)], 0xaa, 0xbb, compressed[(end - 7):end]
    )
    @test gzip_decompress!(decompressor, outdata, trailing_payload, extra_fields) ==
        LibDeflateErrors.deflate_bad_payload

    compressed[4] |= 0xe0
    @test gzip_decompress!(decompressor, outdata, compressed, extra_fields) ==
        LibDeflateErrors.gzip_bad_flags

    @test_throws MethodError gzip_decompress!(decompressor, outdata, compressed)
end

@testset "All-member decompression" begin
    decompressor = Decompressor()
    parts = ["first member", "", "third member"]
    members = transcode.(GzipCompressor, parts)
    concatenated = reduce(vcat, members)
    expected = Vector{UInt8}(join(parts))
    output = zeros(UInt8, length(expected) + 16)

    sentinel = make_empty_extra_field()
    scratch = GzipDecompressAllScratch(
        [sentinel],
        GzipDecompressResult[
            gzip_decompress!(
                decompressor, output, first(members), GzipExtraField[]
            ),
        ],
    )
    no_members = GzipDecompressAllResult(
        (;
            read = UInt(0), written = UInt(0), members = UInt(0),
        )
    )
    @test gzip_decompress_all!(
        decompressor, output, UInt8[], scratch
    ) == (no_members, LibDeflateErrors.gzip_header_too_short)
    @test isempty(scratch.extra_fields)
    @test isempty(scratch.member_results)
    push!(scratch.extra_fields, sentinel)
    push!(
        scratch.member_results,
        gzip_decompress!(decompressor, output, first(members), GzipExtraField[]),
    )
    empty_input = UInt8[]
    @test GC.@preserve output empty_input unsafe_gzip_decompress_all!(
        decompressor,
        WriteableMemory(output),
        ReadableMemory(empty_input),
        scratch,
    ) == (no_members, LibDeflateErrors.gzip_header_too_short)
    @test isempty(scratch.extra_fields)
    @test isempty(scratch.member_results)

    result = gzip_decompress_all!(decompressor, output, concatenated, scratch)
    @test result.read isa UInt
    @test result.written isa UInt
    @test result.members isa UInt
    @test result isa GzipDecompressAllResult
    @test result == (;
        read = UInt(length(concatenated)),
        written = UInt(length(expected)),
        members = UInt(3),
    )
    @test output[1:result.written] == expected
    @test length(output) == length(expected) + 16
    @test isempty(scratch.extra_fields)
    @test length(scratch.member_results) == 3
    @test getproperty.(scratch.member_results, :read) == UInt.(length.(members))
    @test getproperty.(scratch.member_results, :written) == UInt.(sizeof.(parts))
    @test all(member -> member.header.extra === nothing, scratch.member_results)

    single_result = gzip_decompress_all!(decompressor, output, first(members), scratch)
    @test single_result.members == 1
    @test single_result.written == sizeof(first(parts))
    @test length(scratch.member_results) == 1
    empty_result = gzip_decompress_all!(decompressor, UInt8[], members[2], scratch)
    @test empty_result == (;
        read = UInt(length(members[2])),
        written = UInt(0),
        members = UInt(1),
    )
    @test only(scratch.member_results).written == 0

    fill!(output, 0x00)
    result = GC.@preserve output concatenated unsafe_gzip_decompress_all!(
        decompressor, WriteableMemory(output), ReadableMemory(concatenated), scratch
    )
    @test result.members == 3
    @test output[1:result.written] == expected
    @test length(scratch.member_results) == 3

    custom_output = CustomWriteable(zeros(UInt8, length(expected)))
    result = gzip_decompress_all!(
        decompressor, custom_output, CustomReadable(concatenated), scratch
    )
    @test result.written == length(expected)
    @test custom_output.data == expected

    @test gzip_decompress_all!(decompressor, UInt8[], UInt8[], scratch) ==
        (no_members, LibDeflateErrors.gzip_header_too_short)
    insufficient = gzip_decompress_all!(
        decompressor, zeros(UInt8, length(expected) - 1), concatenated, scratch
    )
    @test insufficient == (
        GzipDecompressAllResult(
            (;
                read = UInt(length(members[1]) + length(members[2])),
                written = UInt(length(parts[1]) + length(parts[2])),
                members = UInt(2),
            )
        ),
        LibDeflateErrors.deflate_insufficient_space,
    )
    @test length(scratch.member_results) == 2
    @test isempty(scratch.extra_fields)
    trailing = vcat(concatenated, 0xaa)
    completed_all = GzipDecompressAllResult(
        (;
            read = UInt(length(concatenated)),
            written = UInt(length(expected)),
            members = UInt(3),
        )
    )
    @test gzip_decompress_all!(decompressor, output, trailing, scratch) ==
        (completed_all, LibDeflateErrors.gzip_header_too_short)
    @test length(scratch.member_results) == 3
    trailing_header = vcat(concatenated, zeros(UInt8, 20))
    @test gzip_decompress_all!(decompressor, output, trailing_header, scratch) ==
        (completed_all, LibDeflateErrors.gzip_bad_magic_bytes)
    @test length(scratch.member_results) == 3

    corrupted = copy(concatenated)
    second_end = length(first(members)) + length(members[2])
    corrupted[second_end - 7] ⊻= 0x01
    partial_failure = (
        GzipDecompressAllResult(
            (;
                read = UInt(length(members[1])),
                written = UInt(length(parts[1])),
                members = UInt(1),
            )
        ),
        LibDeflateErrors.gzip_bad_crc32,
    )
    @test gzip_decompress_all!(decompressor, output, corrupted, scratch) == partial_failure
    @test output[1:partial_failure[1].written] == codeunits(parts[1])
    @test length(scratch.member_results) == 1
    @test only(scratch.member_results).read == length(members[1])
    unsafe_partial = GC.@preserve output corrupted unsafe_gzip_decompress_all!(
        decompressor, WriteableMemory(output), ReadableMemory(corrupted), scratch
    )
    @test unsafe_partial == partial_failure
    @test length(scratch.member_results) == 1

    corrupted_first = copy(concatenated)
    corrupted_first[length(members[1]) - 7] ⊻= 0x01
    @test gzip_decompress_all!(decompressor, output, corrupted_first, scratch) ==
        (no_members, LibDeflateErrors.gzip_bad_crc32)
    @test isempty(scratch.extra_fields)
    @test isempty(scratch.member_results)

    # Metadata from all members is retained, and member ranges index the full input.
    prefix_member = transcode(GzipCompressor, "prefix")
    with_metadata = vcat(complex_test_case, prefix_member, complex_test_case)
    metadata_output = zeros(UInt8, 2 * sizeof("Abracadabra") + sizeof("prefix"))
    result = gzip_decompress_all!(
        decompressor, metadata_output, with_metadata, scratch
    )
    @test result.members == 3
    @test length(scratch.extra_fields) == 4
    @test length(scratch.member_results) == 3
    first_result, middle_result, last_result = scratch.member_results
    @test first_result.read == length(complex_test_case)
    @test first_result.written == sizeof("Abracadabra")
    @test length(first_result.header.extra) == 2
    @test first_result.header.extra == 1:2
    @test first(scratch.extra_fields[first_result.header.extra]).data ==
        UInt(17):UInt(18)
    @test String(with_metadata[first_result.header.filename]) == "filename.fna"
    @test String(with_metadata[first_result.header.comment]) == "αβ学中文"
    @test middle_result.header.extra === nothing
    @test middle_result.header.filename === nothing
    @test middle_result.header.comment === nothing
    @test middle_result.read == length(prefix_member)
    @test middle_result.written == sizeof("prefix")
    last_offset = UInt(length(complex_test_case) + length(prefix_member))
    @test length(last_result.header.extra) == 2
    @test last_result.header.extra == 3:4
    @test first(scratch.extra_fields[last_result.header.extra]).data ==
        (last_offset + UInt(17)):(last_offset + UInt(18))
    @test first(last_result.header.filename) == last_offset + UInt(23)
    @test first(last_result.header.comment) == last_offset + UInt(36)
    @test last_result.read == length(complex_test_case)
    @test last_result.written == sizeof("Abracadabra")
    scratch.extra_fields[1] = sentinel
    @test scratch.extra_fields[first(first(scratch.member_results).header.extra)] == sentinel

    compressor = Compressor()
    empty_metadata_bound = gzip_compress_bound(
        compressor,
        UInt(0);
        extra_len = UInt16(0),
        filename_len = UInt(0),
        comment_len = UInt(0),
    )
    empty_metadata_member = zeros(UInt8, empty_metadata_bound)
    empty_metadata_length = gzip_compress!(
        compressor,
        empty_metadata_member,
        "";
        extra = UInt8[],
        filename = "",
        comment = "",
    )
    resize!(empty_metadata_member, Int(empty_metadata_length))
    empty_metadata_input = vcat(prefix_member, empty_metadata_member)
    result = gzip_decompress_all!(
        decompressor,
        zeros(UInt8, sizeof("prefix")),
        empty_metadata_input,
        scratch,
    )
    @test result.members == 2
    empty_header = last(scratch.member_results).header
    @test empty_header.extra !== nothing
    @test isempty(empty_header.extra)
    @test isempty(empty_header.filename)
    @test isempty(empty_header.comment)
    @test first(empty_header.filename) == UInt(length(prefix_member) + 13)
    @test first(empty_header.comment) == UInt(length(prefix_member) + 14)

    # A failing member's parsed entries are rolled back.
    corrupted_metadata = copy(with_metadata)
    corrupted_metadata[end - 7] ⊻= 0x01
    @test gzip_decompress_all!(
        decompressor, metadata_output, corrupted_metadata, scratch
    ) == (
        GzipDecompressAllResult(
            (;
                read = UInt(length(complex_test_case) + length(prefix_member)),
                written = UInt(sizeof("Abracadabra") + sizeof("prefix")),
                members = UInt(2),
            )
        ),
        LibDeflateErrors.gzip_bad_crc32,
    )
    @test length(scratch.extra_fields) == 2
    @test length(scratch.member_results) == 2

    default_scratch = GzipDecompressAllScratch()
    @test isempty(default_scratch.extra_fields)
    @test isempty(default_scratch.member_results)
    @test_throws MethodError gzip_decompress_all!(decompressor, output, concatenated)
end
