function exercise_libdeflate_api()
    compressor = Compressor()
    decompressor = Decompressor()

    input_bytes = b"Hello, world!"
    input_vector = collect(input_bytes)
    input_string = String(input_bytes)
    compressed_substring = SubString("")

    deflate_output = zeros(UInt8, 64)
    unsafe_deflate_output = zeros(UInt8, 64)
    gzip_output = Memory{UInt8}(undef, 64)
    unsafe_gzip_output = zeros(UInt8, 64)
    zlib_output = zeros(UInt8, 64)
    unsafe_zlib_output = zeros(UInt8, 64)
    decompressed_output = zeros(UInt8, 64)
    unsafe_decompressed_output = zeros(UInt8, 64)

    deflate_compressed = compress!(compressor, deflate_output, input_bytes)
    gzip_compressed = gzip_compress!(compressor, gzip_output, input_string)
    zlib_compressed = zlib_compress!(compressor, zlib_output, input_vector)
    decompressed = decompress!(decompressor, decompressed_output, compressed_substring)

    unsafe_deflate_compressed = GC.@preserve input_vector unsafe_deflate_output begin
        output = WriteableMemory(unsafe_deflate_output)
        input = ReadableMemory(input_vector)
        unsafe_compress!(compressor, output, input)
    end
    unsafe_gzip_compressed = GC.@preserve input_vector unsafe_gzip_output begin
        output = WriteableMemory(unsafe_gzip_output)
        input = ReadableMemory(input_vector)
        unsafe_gzip_compress!(compressor, output, input)
    end
    unsafe_zlib_compressed = GC.@preserve input_vector unsafe_zlib_output begin
        output = WriteableMemory(unsafe_zlib_output)
        input = ReadableMemory(input_vector)
        unsafe_zlib_compress!(compressor, output, input)
    end
    unsafe_decompressed = GC.@preserve input_vector unsafe_decompressed_output begin
        output = WriteableMemory(unsafe_decompressed_output)
        input = ReadableMemory(input_vector)
        unsafe_decompress!(decompressor, output, input)
    end

    return (;
        deflate_compressed,
        unsafe_deflate_compressed,
        gzip_compressed,
        unsafe_gzip_compressed,
        zlib_compressed,
        unsafe_zlib_compressed,
        decompressed,
        unsafe_decompressed,
    )
end
