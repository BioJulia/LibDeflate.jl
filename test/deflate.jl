@testset "Compressor/Decompressor" begin
    address(x) = UInt(Base.unsafe_convert(Ptr{Nothing}, x))

    for T in [Decompressor, Compressor]
        a = T()
        b = T()
        c = T()

        @test pointer_from_objref(a) != pointer_from_objref(c)
        @test pointer_from_objref(a) != pointer_from_objref(b)
        @test pointer_from_objref(b) != pointer_from_objref(c)
        @test address(a) != address(c)
        @test address(a) != address(b)
        @test address(b) != address(c)
    end

    c = Compressor()
    @test c.level == Compressor(UInt8(6)).level
    @test c.level isa UInt8
    @test Compressor(UInt8(0)).level === UInt8(0)
    @test LibDeflate.DEFAULT_COMPRESSION_LEVEL isa UInt8
    @test_throws MethodError Compressor(6)
    @test_throws ArgumentError Compressor(UInt8(13))
end

@testset "Errors" begin
    @test Set(string.(instances(LibDeflateError))) == Set(
        [
            "overflow",
            "input_too_short",
            "not_deflate",
            "insufficient_output_space",
            "decompressed_size_too_small",
            "decompressed_size_too_large",
            "deflate_bad_payload",
            "gzip_bad_magic_bytes",
            "gzip_reserved_flags_set",
            "gzip_extra_too_long",
            "gzip_bad_extra_length",
            "gzip_filename_not_null_terminated",
            "gzip_comment_not_null_terminated",
            "gzip_filename_contains_null",
            "gzip_comment_contains_null",
            "gzip_bad_header_crc16",
            "gzip_bad_crc32",
            "gzip_bad_isize",
            "zlib_bad_window_size",
            "zlib_dictionary_required",
            "zlib_trailing_data",
            "zlib_bad_header_checksum",
            "zlib_bad_adler32",
        ]
    )

    # No space for compression
    v = Vector{UInt8}("Hello, there!")
    c = Compressor()
    d = Decompressor()
    @test compress!(c, zeros(UInt8, 16), v) ==
        LibDeflateErrors.insufficient_output_space
    compressed_output = zeros(UInt8, 16)
    @test GC.@preserve v compressed_output unsafe_compress!(
        c, WriteableMemory(compressed_output), ReadableMemory(v)
    ) == LibDeflateErrors.insufficient_output_space

    # BTYPE=3 is reserved, so this is deterministically invalid DEFLATE data.
    bad_payload = UInt8[0x07]
    output = zeros(UInt8, 512)
    @test decompress!(d, output, bad_payload) ==
        LibDeflateErrors.deflate_bad_payload
    @test GC.@preserve output bad_payload unsafe_decompress!(
        d, WriteableMemory(output), ReadableMemory(bad_payload)
    ) == LibDeflateErrors.deflate_bad_payload

    # Decompressed data larger than the declared exact size
    v = zeros(UInt8, 256)
    bytes = compress!(c, v, Vector{UInt8}("ABC"^51))
    compressed = v[1:bytes]
    @test decompress!(d, zeros(UInt8, 1024), compressed, UInt(150)) ==
        LibDeflateErrors.decompressed_size_too_large
    exact_output = zeros(UInt8, 1024)
    @test GC.@preserve exact_output compressed unsafe_decompress!(
        d, WriteableMemory(exact_output), ReadableMemory(compressed), UInt(150)
    ) == LibDeflateErrors.decompressed_size_too_large

    # Unknown-size output does not fit the buffer.
    @test decompress!(d, zeros(UInt8, 32), compressed) ==
        LibDeflateErrors.insufficient_output_space

    # Decompressed data smaller than the declared exact size
    @test decompress!(d, zeros(UInt8, 1024), compressed, UInt(160)) ==
        LibDeflateErrors.decompressed_size_too_small

    # The backing output buffer cannot hold the declared exact size.
    @test decompress!(d, zeros(UInt8, 100), compressed, UInt(153)) ==
        LibDeflateErrors.insufficient_output_space
    @test_throws MethodError decompress!(d, zeros(UInt8, 1024), compressed, 160)
end

@testset "Compression" begin
    COMPRESSIBLE = [
        vcat(rand(UInt8, 412), zeros(UInt8, 100)),
        rand(1:1000, 100),
        join(rand((['A', 'C', 'G', 'T']), 500)),
        ("Na " * "na "^15 * "Batman! ")^2,
    ]
    outbuffer = zeros(UInt8, 512)
    for i in COMPRESSIBLE
        GC.@preserve i v = unsafe_wrap(Array, Ptr{UInt8}(pointer(i)), sizeof(i))
        compressor = Compressor()
        bound = deflate_compress_bound(compressor, UInt(sizeof(v)))
        @test bound >= sizeof(v)
        @test bound isa UInt
        @test compress!(compressor, zeros(UInt8, bound), v) isa UInt
        bytes = compress!(compressor, outbuffer, v)
        @test bytes < length(v)
    end

    input = CustomReadable(Vector{UInt8}("custom bound input"))
    compressor = Compressor()
    @test deflate_compress_bound(compressor, typemax(UInt)) == LibDeflateErrors.overflow
    bound = deflate_compress_bound(compressor, UInt(sizeof(input.data)))
    @test compress!(compressor, zeros(UInt8, bound), input) isa UInt
    @test_throws MethodError deflate_compress_bound(compressor, 1)

    if Sys.WORD_SIZE > 32
        large_input_size = UInt(typemax(UInt32)) + one(UInt)
        @test deflate_compress_bound(compressor, large_input_size) > typemax(UInt32)
    end
end

@testset "Memory" begin
    v1 = zeros(UInt8, 1024)
    compressor = Compressor()

    input_view = ImmutableMemoryView(MemoryView(Vector{UInt8}("memory-view input")))
    compressed_storage = fill(0xff, 130)
    compressed_view = MemoryView(view(compressed_storage, 2:129))
    n_compressed = compress!(compressor, compressed_view, input_view)
    @test n_compressed isa UInt
    @test compressed_storage[1] == compressed_storage[130] == 0xff

    output_storage = fill(0xff, length(input_view) + 2)
    output_view = MemoryView(view(output_storage, 2:(lastindex(output_storage) - 1)))
    result = decompress!(
        Decompressor(),
        output_view,
        ImmutableMemoryView(compressed_view[1:n_compressed]),
        UInt(length(input_view)),
    )
    @test result.written == length(input_view)
    @test output_view == input_view
    @test output_storage[1] == output_storage[end] == 0xff

    @test_throws MethodError compress!(
        compressor, "xxxxxxxxxxxxxxxxxxxxxxxxxx", UInt8[0x01, 0x02]
    )
    @test_throws MethodError compress!(compressor, v1, view(v1, 5:-1:1))

    input = CustomReadable(Vector{UInt8}("custom memory"))
    compressed = CustomWriteable(zeros(UInt8, 128))
    n_compressed = compress!(compressor, compressed, input)
    @test n_compressed isa UInt

    output = CustomWriteable(zeros(UInt8, 128))
    result = decompress!(
        Decompressor(),
        output,
        CustomReadable(compressed.data[1:n_compressed]),
    )
    @test result == (; read = n_compressed, written = UInt(sizeof(input.data)))
    @test output.data[1:result.written] == input.data
end

# Unsafe CRC is implicitly tested by decompressing gzip with
# codeczlib. So we can just compare it to the unsafe one
@testset "Safe CRC" begin
    for testdata in ["", "foo", "abracadabra!"]
        GC.@preserve testdata @test crc32(collect(codeunits(testdata))) ==
            crc32(collect(codeunits(testdata))) ==
            unsafe_crc32(ReadableMemory(testdata))
    end
end

@testset "Round trip" begin
    INPUT_DATA = [
        "",
        "Abracadabra!",
        "A man, a plan, a canal, Panama!",
        "No, no, no, no, no, no, no, no, no, no, no!",
        "sXXbYltTe]EDP`kRNUoEPVRnkq]gS^cquEv^BVTwAhtjFGGQBC",
        rand(UInt8, 2048),
    ]
    outbuffer = Vector{UInt8}(undef, 4096)
    unsafe_outbuffer = similar(outbuffer)
    backbuffer1 = similar(outbuffer)
    backbuffer2 = similar(outbuffer)
    unsafe_backbuffer1 = similar(outbuffer)
    unsafe_backbuffer2 = similar(outbuffer)

    compressor = Compressor()
    decompressor = Decompressor()

    for i in INPUT_DATA
        v = Vector{UInt8}(i)

        GC.@preserve unsafe_outbuffer v unsafe_backbuffer1 unsafe_backbuffer2 begin
            c_bytes_unsafe = unsafe_compress!(
                compressor, WriteableMemory(unsafe_outbuffer), ReadableMemory(v)
            )
            c_bytes_safe = compress!(compressor, outbuffer, v)

            @test c_bytes_unsafe == c_bytes_safe
            @test unsafe_outbuffer[1:c_bytes_unsafe] == outbuffer[1:c_bytes_safe]

            d_bytes_unsafe1 = unsafe_decompress!(
                decompressor,
                WriteableMemory(unsafe_backbuffer1),
                ReadableMemory(pointer(unsafe_outbuffer), c_bytes_unsafe),
                UInt(length(v)),
            )

            d_bytes_unsafe2 = unsafe_decompress!(
                decompressor,
                WriteableMemory(unsafe_backbuffer2),
                ReadableMemory(pointer(unsafe_outbuffer), c_bytes_unsafe),
            )
        end

        d_bytes_safe1 = decompress!(decompressor, backbuffer1, outbuffer, UInt(length(v)))
        d_bytes_safe2 = decompress!(decompressor, backbuffer2, outbuffer)

        expected = (; read = c_bytes_unsafe, written = UInt(length(v)))
        @test d_bytes_safe1 == d_bytes_safe2 == d_bytes_unsafe1 == d_bytes_unsafe2 == expected

        @test v ==
            backbuffer1[1:d_bytes_safe1.written] ==
            backbuffer2[1:d_bytes_safe1.written] ==
            unsafe_backbuffer1[1:d_bytes_safe1.written] ==
            unsafe_backbuffer2[1:d_bytes_safe1.written]
    end
end
