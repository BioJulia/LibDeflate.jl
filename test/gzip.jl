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
        data[2] = 0x00
        @test !test_valid(data)
        @test !test_unsafe_valid(data)
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

@testset "Parse fields" begin
    test_parse(v) = GC.@preserve v LibDeflate.parse_fields(pointer(v), UInt32(1), UInt16(length(v)))
    for data in data_test_cases
        # We merely test it doesn't fail
        @test test_parse(data) !== nothing
        data[2] = 0x00
        @test test_parse(data) == LibDeflateErrors.gzip_bad_extra
        data[2] = 0xa0
        push!(data, 0x00)
        @test test_parse(data) == LibDeflateErrors.gzip_extra_too_long
        pop!(data)
        @test test_parse(data[1:(end - 1)]) == LibDeflateErrors.gzip_extra_too_long
        data = empty!(copy(data))
        @test test_parse(data) !== nothing
    end
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

function test_header_example(data::Vector{UInt8}, header::LibDeflate.GzipHeader)
    @test header.mtime == 0x60512cb3
    @test length(header.extra) == 2
    @test first(header.extra).tag == (0x42, 0x43)
    @test first(header.extra).data == 0x00000011:0x00000012
    @test last(header.extra).tag == (0x02, 0x03)
    @test last(header.extra).data === nothing # empty field
    @test String(data[header.filename]) == "filename.fna"
    @test String(data[header.comment]) == "αβ学中文"
    return true
end

@testset "Parse header" begin
    result = GC.@preserve header_data unsafe_parse_gzip_header(ReadableMemory(header_data))
    @test result.read == length(header_data)
    header = result.header
    test_header_example(header_data, header)

    result = parse_gzip_header(header_data)
    @test result.read == length(header_data)
    header = result.header
    test_header_example(header_data, header)

    result = GC.@preserve header_data unsafe_parse_gzip_header(
        ReadableMemory(header_data), LibDeflate.GzipExtraField[]
    )
    header = result.header
    test_header_example(header_data, header)

    header_data[end - 2] = 0x01
    @test GC.@preserve header_data unsafe_parse_gzip_header(ReadableMemory(header_data)) ==
        LibDeflateErrors.gzip_string_not_null_terminated
    header_data[end - 2] = 0x00

    minimal_data = UInt8[
        0x1f, 0x8b, 0x08, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xff, 0x06, 0x00, 0x42, 0x43, 0x02, 0x00, 0x10, 0x20,
    ]
    result = parse_gzip_header(minimal_data)
    @test result.read == 18
    header = result.header
    ex = only(header.extra)
    @test ex.tag == (0x42, 0x43)
    @test ex.data == 17:18

    # Reusing extra-field storage must not retain fields from a previous header.
    extra_data = LibDeflate.GzipExtraField[]
    header = parse_gzip_header(header_data; extra_data).header
    @test header.extra === extra_data
    @test !isempty(extra_data)

    header_without_extra = UInt8[
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
    ]
    header = parse_gzip_header(header_without_extra; extra_data).header
    @test header.extra === nothing
    @test isempty(extra_data)
end

@testset "Reserved flags" begin
    base_header = UInt8[
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
    ]
    for reserved_flags in (0x20, 0x40, 0x80, 0xe0)
        header = copy(base_header)
        header[4] = reserved_flags
        @test parse_gzip_header(header) == LibDeflateErrors.gzip_bad_flags
    end
end

@testset "Truncated headers" begin
    base_header = UInt8[
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
    ]

    for len in 0:9
        @test parse_gzip_header(base_header[1:len]) ==
            LibDeflateErrors.gzip_header_too_short
    end

    extra_header = copy(base_header)
    extra_header[4] = 0x04
    @test parse_gzip_header(extra_header) == LibDeflateErrors.gzip_header_too_short
    @test parse_gzip_header(vcat(extra_header, 0x00)) ==
        LibDeflateErrors.gzip_header_too_short

    # XLEN may be zero, including when it ends exactly at the input boundary.
    empty_extra = vcat(extra_header, 0x00, 0x00)
    result = parse_gzip_header(empty_extra)
    @test result.read == 12
    header = result.header
    @test isempty(header.extra)

    truncated_extra = vcat(extra_header, 0x04, 0x00, 0x42, 0x43, 0x00)
    @test parse_gzip_header(truncated_extra) == LibDeflateErrors.gzip_extra_too_long

    for flag in (0x08, 0x10)
        string_header = copy(base_header)
        string_header[4] = flag
        @test parse_gzip_header(string_header) ==
            LibDeflateErrors.gzip_string_not_null_terminated
        @test parse_gzip_header(vcat(string_header, codeunits("unterminated"))) ==
            LibDeflateErrors.gzip_string_not_null_terminated
    end

    crc_header = copy(base_header)
    crc_header[4] = 0x02
    @test parse_gzip_header(crc_header) == LibDeflateErrors.gzip_header_too_short
    @test parse_gzip_header(vcat(crc_header, 0x00)) ==
        LibDeflateErrors.gzip_header_too_short

    name_crc_header = copy(base_header)
    name_crc_header[4] = 0x0a
    @test parse_gzip_header(vcat(name_crc_header, 0x00)) ==
        LibDeflateErrors.gzip_header_too_short
    @test parse_gzip_header(vcat(name_crc_header, 0x00, 0x00)) ==
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
    for data in test_data
        bound = gzip_compress_bound(
            compressor,
            sizeof(data);
            comment_len = sizeof(test_comment),
            filename_len = sizeof(test_filename),
            extra_len = sizeof(data_test_cases[1]),
            header_crc = true,
        )
        outdata = zeros(UInt8, bound)
        n_bytes = GC.@preserve data outdata unsafe_gzip_compress!(
            compressor, WriteableMemory(outdata), ReadableMemory(data),
            LibDeflate.ReadableMemory(test_comment), LibDeflate.ReadableMemory(test_filename),
            LibDeflate.ReadableMemory(data_test_cases[1]), true
        )
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
        @test n_bytes <= bound
        @test length(outdata) == bound
        decompressed = transcode(GzipDecompressor, outdata[1:n_bytes])
        @test decompressed == Vector{UInt8}(data)
    end

    data = UInt8.(0:99)
    input = CustomReadable(data)
    @test sizeof(input) < sizeof(ReadableMemory(input))

    bound = gzip_compress_bound(compressor, sizeof(input.data))
    output = CustomWriteable(zeros(UInt8, bound))
    n_bytes = gzip_compress!(compressor, output, input)
    @test n_bytes isa Int
    @test transcode(GzipDecompressor, output.data[1:n_bytes]) == data

    base_bound = gzip_compress_bound(compressor, 0)
    @test gzip_compress_bound(compressor, 0; comment_len = 0) == base_bound + 1
    @test gzip_compress_bound(compressor, 0; filename_len = 0) == base_bound + 1
    @test gzip_compress_bound(compressor, 0; extra_len = 0) == base_bound + 2
    @test gzip_compress_bound(compressor, 0; header_crc = true) == base_bound + 2
    for (bound_options, compress_options) in (
            ((; comment_len = 0), (; comment = "")),
            ((; filename_len = 0), (; filename = "")),
            ((; extra_len = 0), (; extra = UInt8[])),
        )
        bound = gzip_compress_bound(compressor, 0; bound_options...)
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
    @test gzip_compress_bound(compressor, 0; extra_len = oversized_extra_len) ==
        LibDeflateErrors.gzip_extra_too_long
    oversized_extra = zeros(UInt8, oversized_extra_len)
    @test gzip_compress!(compressor, UInt8[], ""; extra = oversized_extra) ==
        LibDeflateErrors.gzip_extra_too_long
    @test_throws ArgumentError gzip_compress_bound(compressor, -1)
    @test_throws ArgumentError gzip_compress_bound(compressor, 0; comment_len = -1)
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

    for len in 0:19
        @test gzip_decompress!(decompressor, outdata, zeros(UInt8, len)) ==
            LibDeflateErrors.gzip_header_too_short
    end

    for data in test_data
        compressed = transcode(GzipCompressor, data)
        expected = Vector{UInt8}(data)

        result = GC.@preserve compressed unsafe_gzip_decompress!(
            decompressor, WriteableMemory(outdata), ReadableMemory(compressed)
        )
        @test outdata[1:result.len] == expected
        @test result.read == length(compressed)

        result = GC.@preserve compressed unsafe_gzip_decompress!(
            decompressor,
            WriteableMemory(outdata),
            ReadableMemory(compressed),
            length(expected),
        )
        @test outdata[1:result.len] == expected
        @test result.read == length(compressed)

        fill!(outdata, 0x00)
        result = gzip_decompress!(decompressor, outdata, compressed)
        @test outdata[1:result.len] == expected
        @test result.read == length(compressed)
        @test length(outdata) == 1001

        fill!(outdata, 0x00)
        result = gzip_decompress!(decompressor, outdata, compressed, length(expected))
        @test outdata[1:result.len] == expected
        @test result.len == length(expected)
        @test result.read == length(compressed)

        @test gzip_decompress!(
            decompressor, outdata, compressed, length(expected) + 1
        ) == LibDeflateErrors.deflate_output_too_short
        if !isempty(expected)
            @test gzip_decompress!(
                decompressor, outdata, compressed, length(expected) - 1
            ) == LibDeflateErrors.deflate_insufficient_space
            @test gzip_decompress!(
                decompressor,
                view(outdata, 1:(length(expected) - 1)),
                compressed,
                length(expected),
            ) == LibDeflateErrors.deflate_insufficient_space
        end

        if !isempty(expected)
            small_output = zeros(UInt8, length(expected) - 1)
            @test gzip_decompress!(decompressor, small_output, compressed) ==
                LibDeflateErrors.deflate_insufficient_space
        end
    end

    custom_output = CustomWriteable(zeros(UInt8, 32))
    compressed = transcode(GzipCompressor, "custom output")
    result = gzip_decompress!(
        decompressor,
        custom_output,
        CustomReadable(compressed),
        sizeof("custom output"),
    )
    @test String(custom_output.data[1:result.len]) == "custom output"

    compressed = transcode(GzipCompressor, "five bytes")
    small_output = zeros(UInt8, 5)
    original_length = length(small_output)
    @test gzip_decompress!(decompressor, small_output, compressed) ==
        LibDeflateErrors.deflate_insufficient_space
    @test length(small_output) == original_length

    # RFC 1952 permits concatenated members.  This API deliberately returns
    # only the first member, leaving the remainder unread.
    first_member = transcode(GzipCompressor, "first member")
    second_member = transcode(GzipCompressor, "second member is longer")
    concatenated = vcat(first_member, second_member)
    result = gzip_decompress!(decompressor, outdata, concatenated)
    @test result.len == sizeof("first member")
    @test result.read == length(first_member)
    @test outdata[1:result.len] == Vector{UInt8}(codeunits("first member"))

    # Hard test case
    res = gzip_decompress!(decompressor, outdata, complex_test_case)
    test_header_example(complex_test_case, res.header)
    @test res.len == 11
    @test res.read == length(complex_test_case)

    compressed = transcode(GzipCompressor, "trailing payload")
    trailing_payload = vcat(
        compressed[1:(end - 8)], 0xaa, 0xbb, compressed[(end - 7):end]
    )
    @test gzip_decompress!(decompressor, outdata, trailing_payload) ==
        LibDeflateErrors.deflate_bad_payload

    compressed[4] |= 0xe0
    @test gzip_decompress!(decompressor, outdata, compressed) ==
        LibDeflateErrors.gzip_bad_flags
end
