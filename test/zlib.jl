zlib_test_data = [
    UInt8[
        0x78, 0x5e,
        0x01, 0x03, 0x00, 0xfc, 0xff, 0x66, 0x6f, 0x6f,
        0x02, 0x82, 0x01, 0x45,
    ],
]

@testset "Decompression" begin
    indata = zlib_test_data[1]
    decompressor = Decompressor()
    output = zeros(UInt8, 128)

    result = zlib_decompress!(decompressor, output, indata)
    @test result == 3
    @test result isa UInt
    @test String(output[1:3]) == "foo"
    @test zlib_decompress!(decompressor, output, indata, UInt(3)) == 3
    @test String(output[1:3]) == "foo"
    @test GC.@preserve output indata unsafe_zlib_decompress!(
        decompressor, WriteableMemory(output), ReadableMemory(indata)
    ) == 3
    @test GC.@preserve output indata unsafe_zlib_decompress!(
        decompressor, WriteableMemory(output), ReadableMemory(indata), UInt(3)
    ) == 3

    # The same payload with CINFO=0 declares a valid 256-byte window.
    small_window = copy(indata)
    small_window[1:2] = UInt8[0x08, 0x1d]
    @test zlib_decompress!(decompressor, output, small_window) == 3
    @test String(output[1:3]) == "foo"
    @test zlib_decompress!(decompressor, output, small_window, UInt(3)) == 3

    @test zlib_decompress!(decompressor, output, indata, UInt(2)) ==
        LibDeflateErrors.decompressed_size_too_large
    @test zlib_decompress!(decompressor, output, indata, UInt(4)) ==
        LibDeflateErrors.decompressed_size_too_small
    @test_throws MethodError zlib_decompress!(decompressor, output, indata, 3)

    @test zlib_decompress!(decompressor, output[1:2], indata, UInt(3)) ==
        LibDeflateErrors.insufficient_output_space
    @test zlib_decompress!(decompressor, output[1:2], indata) ==
        LibDeflateErrors.insufficient_output_space

    @test zlib_decompress!(decompressor, output, UInt8[]) ==
        LibDeflateErrors.input_too_short
    truncated_trailer = indata[1:(end - 1)]
    @test zlib_decompress!(decompressor, output, truncated_trailer) ==
        LibDeflateErrors.input_too_short
    @test GC.@preserve output truncated_trailer unsafe_zlib_decompress!(
        decompressor, WriteableMemory(output), ReadableMemory(truncated_trailer)
    ) == LibDeflateErrors.input_too_short

    cp = copy(indata)

    cp[1:2] = UInt8[0x79, 0x18]
    @test zlib_decompress!(decompressor, output, cp) == LibDeflateErrors.not_deflate

    cp[1:2] = UInt8[0x88, 0x1c]
    @test zlib_decompress!(decompressor, output, cp) ==
        LibDeflateErrors.zlib_bad_window_size

    cp[1:2] = UInt8[0x78, 0x20]
    @test zlib_decompress!(decompressor, output, cp) ==
        LibDeflateErrors.zlib_dictionary_required

    cp[1:2] = UInt8[0x78, 0x5f]
    @test zlib_decompress!(decompressor, output, cp) ==
        LibDeflateErrors.zlib_bad_header_checksum

    cp[1] = 0x78
    cp[2] = 0x01
    @test zlib_decompress!(decompressor, output, cp, UInt(3)) == 3
    cp[2] = 0xda
    @test zlib_decompress!(decompressor, output, cp, UInt(3)) == 3
    cp[2] = 0x9c
    @test zlib_decompress!(decompressor, output, cp, UInt(3)) == 3

    cp[end] = 0x46
    @test zlib_decompress!(decompressor, output, cp) == LibDeflateErrors.zlib_bad_adler32

    bad_payload = UInt8[0x78, 0x01, 0x07, 0x00, 0x00, 0x00, 0x01]
    @test zlib_decompress!(decompressor, output, bad_payload) ==
        LibDeflateErrors.deflate_bad_payload

    trailing_data = vcat(indata, 0xaa, 0xbb)
    @test zlib_decompress!(decompressor, output, trailing_data) ==
        LibDeflateErrors.zlib_trailing_data
    @test zlib_decompress!(decompressor, output, trailing_data, UInt(3)) ==
        LibDeflateErrors.zlib_trailing_data

    concatenated = vcat(indata, indata)
    @test zlib_decompress!(decompressor, output, concatenated) ==
        LibDeflateErrors.zlib_trailing_data
end

@testset "Compression" begin
    output = zeros(UInt8, 128)
    compressor = Compressor()

    bound = zlib_compress_bound(compressor, UInt(sizeof("foo")))
    @test bound == deflate_compress_bound(compressor, UInt(sizeof("foo"))) + UInt(6)
    @test bound isa UInt
    @test zlib_compress_bound(compressor, typemax(UInt)) == LibDeflateErrors.overflow
    @test zlib_compress!(compressor, zeros(UInt8, bound), "foo") isa UInt
    n_compressed = zlib_compress!(compressor, output, "foo")
    @test n_compressed isa UInt
    @test transcode(ZlibDecompressor, output[1:n_compressed]) == Vector{UInt8}("foo")

    output_32 = zeros(UInt8, 32)
    n_compressed = zlib_compress!(compressor, output_32, "foo")
    @test n_compressed isa UInt
    @test transcode(ZlibDecompressor, output_32[1:n_compressed]) == Vector{UInt8}("foo")
    @test zlib_compress!(compressor, zeros(UInt8, 0), "foo") ==
        LibDeflateErrors.insufficient_output_space
    @test zlib_compress!(compressor, zeros(UInt8, 8), "foo") ==
        LibDeflateErrors.insufficient_output_space

    input = CustomReadable(Vector{UInt8}("custom bound input"))
    bound = zlib_compress_bound(compressor, UInt(sizeof(input.data)))
    @test zlib_compress!(compressor, zeros(UInt8, bound), input) isa UInt

    for (compresslevel, header) in [
            (UInt8(1), 0x0178),
            (UInt8(4), 0x5e78),
            (LibDeflate.DEFAULT_COMPRESSION_LEVEL, 0x9c78),
            (UInt8(12), 0xda78),
        ]
        compressor = Compressor(compresslevel)
        @test zlib_compress!(compressor, output, "foo") > 6
        @test UInt16(output[1]) | (UInt16(output[2]) << 8) == header
    end
end

@testset "Adler32" begin
    @test adler32("") == UInt32(1)
    @test adler32("", 0x98765432) == 0x98765432
    @test adler32("foo") == 0x02820145
end

@testset "Round trip" begin
    compressed = zeros(UInt8, 128)
    decompressed = zeros(UInt8, 128)
    compressor = Compressor()
    decompressor = Decompressor()
    for input in ("Abracadabra", "", collect(codeunits("Power overwhelming")))
        v = Vector{UInt8}(input)
        n_compressed_bytes = zlib_compress!(
            compressor, CustomWriteable(compressed), CustomReadable(v)
        )
        @test n_compressed_bytes > 6
        @test zlib_decompress!(
            decompressor,
            decompressed,
            compressed[1:n_compressed_bytes],
            UInt(sizeof(input)),
        ) isa UInt
        @test transcode(ZlibDecompressor, compressed[1:n_compressed_bytes]) == v

        # Can decompress zlib
        zlib_compressed = transcode(ZlibCompressor, v)
        @test zlib_decompress!(
            decompressor, CustomWriteable(decompressed), CustomReadable(zlib_compressed)
        ) == sizeof(input)
        @test decompressed[1:sizeof(input)] == v
    end
end
