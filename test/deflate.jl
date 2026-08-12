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
    @test c.level == Compressor(6).level
end

@testset "Errors" begin
    # No space for decompression
    v = Vector{UInt8}("Hello, there!")
    c = Compressor()
    d = Decompressor()
    @test compress!(c, zeros(UInt8, 16), v) == LibDeflateErrors.deflate_insufficient_space

    # Not compressed data
    @test decompress!(d, zeros(UInt8, 512), rand(UInt8, 32)) ==
        LibDeflateErrors.deflate_bad_payload

    # Decompressed data too short
    v = zeros(UInt8, 256)
    bytes = compress!(c, v, Vector{UInt8}("ABC"^51))
    compressed = v[1:bytes]
    @test decompress!(d, zeros(UInt8, 1024), compressed, 150) ==
        LibDeflateErrors.deflate_insufficient_space

    # Decompressed data too long
    @test decompress!(d, zeros(UInt8, 32), compressed) ==
        LibDeflateErrors.deflate_insufficient_space
    @test decompress!(d, zeros(UInt8, 1024), compressed, 160) ==
        LibDeflateErrors.deflate_output_too_short
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
        bytes = compress!(Compressor(), outbuffer, v)
        @test bytes < length(v)
    end
end

@testset "Memory" begin
    v1 = zeros(UInt8, 1024)
    compressor = Compressor()
    mem = WriteableMemory([1.0])
    write_mem = WriteableMemory(view([1.0f0], 1:1))
    mem = ReadableMemory("foo")
    mem = ReadableMemory(SubString("foo", 1:2))
    mem = ReadableMemory(write_mem)
    @test_throws MethodError WriteableMemory(mem)

    # A rectangular view that does not span every row has gaps between columns,
    # so its logical elements are not contiguous in memory.
    noncontiguous = view(reshape(UInt8.(1:9), 3, 3), 1:2, 1:2)
    @test_throws MethodError ReadableMemory(noncontiguous)
    @test_throws MethodError WriteableMemory(noncontiguous)

    @test_throws MethodError compress!(
        compressor, "xxxxxxxxxxxxxxxxxxxxxxxxxx", UInt8[0x01, 0x02]
    )
    @test_throws MethodError compress!(compressor, v1, view(v1, 5:-1:1))
end

# Unsafe CRC is implicitly tested by decompressing gzip with
# codeczlib. So we can just compare it to the unsafe one
@testset "Safe CRC" begin
    for testdata in ["", "foo", "abracadabra!"]
        GC.@preserve testdata @test crc32(collect(codeunits(testdata))) ==
            crc32(collect(codeunits(testdata))) ==
            unsafe_crc32(pointer(testdata), ncodeunits(testdata))
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
                compressor, pointer(unsafe_outbuffer), length(outbuffer), pointer(v), length(v)
            )
            c_bytes_safe = compress!(compressor, outbuffer, v)

            @test c_bytes_unsafe == c_bytes_safe
            @test unsafe_outbuffer[1:c_bytes_unsafe] == outbuffer[1:c_bytes_safe]

            d_bytes_unsafe1 = unsafe_decompress!(
                Base.HasLength(),
                decompressor,
                pointer(unsafe_backbuffer1),
                length(v),
                pointer(unsafe_outbuffer),
                c_bytes_unsafe,
            )

            d_bytes_unsafe2 = unsafe_decompress!(
                Base.SizeUnknown(),
                decompressor,
                pointer(unsafe_backbuffer2),
                length(unsafe_backbuffer2),
                pointer(unsafe_outbuffer),
                c_bytes_unsafe,
            )
        end

        d_bytes_safe1 = decompress!(decompressor, backbuffer1, outbuffer, length(v))
        d_bytes_safe2 = decompress!(decompressor, backbuffer2, outbuffer)

        @test d_bytes_safe1 == d_bytes_safe2 == d_bytes_unsafe1 == d_bytes_unsafe2

        @test v ==
            backbuffer1[1:d_bytes_safe1] ==
            backbuffer2[1:d_bytes_safe1] ==
            unsafe_backbuffer1[1:d_bytes_safe1] ==
            unsafe_backbuffer2[1:d_bytes_safe1]
    end
end
