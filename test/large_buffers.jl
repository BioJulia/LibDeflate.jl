using Mmap

Sys.WORD_SIZE == 64 || error("large-buffer tests require a 64-bit system")

# Stay close to the historical 2^32-byte boundary. Anonymous mappings are initially
# zero-filled and do not require committing their full size as physical memory.
const LARGE_BUFFER_SIZE = (UInt(1) << 32) + UInt(64 << 10)
const MAX_LARGE_BUFFER_SIZE = UInt(6_000_000_000)

@testset "Buffers larger than 4 GiB" begin
    @test UInt(typemax(UInt32)) < LARGE_BUFFER_SIZE <= MAX_LARGE_BUFFER_SIZE

    input = Mmap.mmap(Vector{UInt8}, Int(LARGE_BUFFER_SIZE))
    @test UInt(sizeof(input)) == LARGE_BUFFER_SIZE

    @testset "Checksums consume the full native-width length" begin
        # Independently calculated for LARGE_BUFFER_SIZE zero bytes. Both values differ
        # from the checksums of the low 32 bits of LARGE_BUFFER_SIZE zero bytes.
        @test crc32(input) == UInt32(0xe50d43f3)
        @test adler32(input) == UInt32(0x00f00001)
    end

    @testset "DEFLATE and gzip compression" begin
        compressor = Compressor(UInt8(1))
        output_size = gzip_compress_bound(compressor, LARGE_BUFFER_SIZE)
        @test LARGE_BUFFER_SIZE < output_size <= MAX_LARGE_BUFFER_SIZE
        output = Mmap.mmap(Vector{UInt8}, Int(output_size))

        raw_written = compress!(compressor, output, input)
        @test raw_written isa UInt
        @test zero(UInt) < raw_written < LARGE_BUFFER_SIZE

        gzip_written = gzip_compress!(compressor, output, input)
        @test gzip_written isa UInt
        @test zero(UInt) < gzip_written < LARGE_BUFFER_SIZE

        # The gzip trailer independently confirms that the checksum covered the full
        # input and that ISIZE intentionally contains the length modulo 2^32.
        trailer = output[(gzip_written - UInt(7)):gzip_written]
        trailer_crc32 = ltoh(only(reinterpret(UInt32, trailer[1:4])))
        trailer_isize = ltoh(only(reinterpret(UInt32, trailer[5:8])))
        @test trailer_crc32 == UInt32(0xe50d43f3)
        @test trailer_isize == LARGE_BUFFER_SIZE % UInt32
    end
end
