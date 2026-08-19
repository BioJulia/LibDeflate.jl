using LibDeflate
using Test
using CodecZlib
using Aqua
using MemoryViews: ImmutableMemoryView, MemoryView, MutableMemoryView

# Persistent tasks is slow to test and we don't use tasks at all, so skip it
@testset "Aqua" begin
    Aqua.test_all(LibDeflate; persistent_tasks = false)
end

# This is not the actual commit this functionality was added but just some
# aribitrary commit afterwards where is certainly is present
if VERSION > v"1.14.0-DEV.2851"
    @testset "Closure boxes" begin
        @test isempty(Test.detect_closure_boxes(LibDeflate))
    end
end

struct CustomReadable
    data::Vector{UInt8}
end

struct CustomWriteable
    data::Vector{UInt8}
end

struct PaddedBits
    small::UInt8
    large::UInt64
end

LibDeflate.ReadableMemory(input::CustomReadable) = ReadableMemory(input.data)
LibDeflate.WriteableMemory(output::CustomWriteable) = WriteableMemory(output.data)

@testset "ReadableMemory and WriteableMemory construction" begin
    bytes = UInt8[0x01, 0x02, 0x03, 0x04]
    byte_memory = Memory{UInt8}(bytes)

    for storage in (bytes, byte_memory)
        readable = ReadableMemory(storage)
        writeable = WriteableMemory(storage)
        @test pointer(readable) == pointer(storage)
        @test pointer(writeable) == pointer(storage)
        @test sizeof(readable) == sizeof(writeable) == length(storage)
    end

    byte_matrix = reshape(bytes, 2, 2)
    readable_matrix = ReadableMemory(byte_matrix)
    writeable_matrix = WriteableMemory(byte_matrix)
    @test pointer(readable_matrix) == pointer(byte_matrix)
    @test pointer(writeable_matrix) == pointer(byte_matrix)
    @test sizeof(readable_matrix) == sizeof(writeable_matrix) == length(byte_matrix)

    byte_slice = view(bytes, 2:3)
    readable_slice = ReadableMemory(byte_slice)
    writeable_slice = WriteableMemory(byte_slice)
    @test pointer(readable_slice) == pointer(bytes, 2)
    @test pointer(writeable_slice) == pointer(bytes, 2)
    @test sizeof(readable_slice) == sizeof(writeable_slice) == length(byte_slice)

    mutable_view = MemoryView(bytes)
    immutable_view = ImmutableMemoryView(mutable_view)
    @test mutable_view isa MutableMemoryView{UInt8}
    @test immutable_view isa ImmutableMemoryView{UInt8}
    for storage in (mutable_view, immutable_view)
        readable = ReadableMemory(storage)
        @test pointer(readable) == pointer(storage)
        @test sizeof(readable) == length(storage)
    end
    writeable_view = WriteableMemory(mutable_view)
    @test pointer(writeable_view) == pointer(mutable_view)
    @test sizeof(writeable_view) == length(mutable_view)

    string = "føo"
    substring = SubString(string, 2:4)
    @test codeunits(substring) isa Base.CodeUnits{UInt8, SubString{String}}
    for storage in (string, substring, codeunits(string), codeunits(substring))
        readable = ReadableMemory(storage)
        @test pointer(readable) == pointer(storage)
        expected_length = storage isa AbstractString ? ncodeunits(storage) : length(storage)
        @test sizeof(readable) == expected_length
        @test_throws MethodError WriteableMemory(storage)
    end

    pointer_readable = ReadableMemory(pointer(bytes), length(bytes))
    pointer_writeable = WriteableMemory(pointer(bytes), UInt(length(bytes)))
    @test pointer(pointer_readable) == pointer(bytes)
    @test pointer(pointer_writeable) == pointer(bytes)
    @test sizeof(pointer_readable) == sizeof(pointer_writeable) == length(bytes)
    @test ReadableMemory(pointer_readable) === pointer_readable
    @test WriteableMemory(pointer_writeable) === pointer_writeable
    readable_writeable = ReadableMemory(pointer_writeable)
    @test pointer(readable_writeable) == pointer(pointer_writeable)
    @test sizeof(readable_writeable) == sizeof(pointer_writeable)
    @test_throws MethodError WriteableMemory(pointer_readable)

    @test pointer(pointer_readable) isa Ptr{Nothing}
    @test pointer_readable.len isa UInt
    @test sizeof(pointer_readable) isa Int

    @test_throws InexactError ReadableMemory(C_NULL, -1)
    @test_throws InexactError WriteableMemory(C_NULL, -1)
    @test_throws DomainError ReadableMemory(C_NULL, UInt(typemax(Int)) + one(UInt))
    @test_throws DomainError WriteableMemory(C_NULL, UInt(typemax(Int)) + one(UInt))

    if Sys.WORD_SIZE > 32
        large_len = UInt(typemax(UInt32)) + one(UInt)
        large_readable = ReadableMemory(C_NULL, large_len)
        large_writeable = WriteableMemory(C_NULL, large_len)
        @test large_readable.len == large_len
        @test large_writeable.len == large_len
        @test sizeof(large_readable) == sizeof(large_writeable) == Int(large_len)
    end

    # A rectangular view that does not span every row has gaps between columns,
    # so its logical elements are not contiguous in memory.
    noncontiguous = view(reshape(UInt8.(1:9), 3, 3), 1:2, 1:2)
    @test_throws MethodError ReadableMemory(noncontiguous)
    @test_throws MethodError WriteableMemory(noncontiguous)

    reversed = view(bytes, lastindex(bytes):-1:firstindex(bytes))
    @test_throws MethodError ReadableMemory(reversed)
    @test_throws MethodError WriteableMemory(reversed)

    padded = [PaddedBits(0x01, 0x02)]
    @test isbitstype(PaddedBits)
    @test_throws MethodError ReadableMemory(padded)
    @test_throws MethodError WriteableMemory(padded)
    @test_throws MethodError ReadableMemory(MemoryView([1.0]))
    @test_throws MethodError WriteableMemory(MemoryView([1.0]))
    @test_throws MethodError WriteableMemory(immutable_view)

    custom_readable = CustomReadable(bytes)
    custom_writeable = CustomWriteable(bytes)
    @test pointer(ReadableMemory(custom_readable)) == pointer(bytes)
    @test pointer(WriteableMemory(custom_writeable)) == pointer(bytes)
end

@testset "DEFLATE" begin
    include("deflate.jl")
end

@testset "gzip" begin
    include("gzip.jl")
end

@testset "zlib" begin
    include("zlib.jl")
end

# These tests scan buffers larger than 4 GiB and are intentionally excluded from the
# default suite. Run them with `LIBDEFLATE_TEST_LARGE_BUFFERS=true julia --project -e
# 'using Pkg; Pkg.test()'` on a 64-bit system with sufficient address space.
if get(ENV, "LIBDEFLATE_TEST_LARGE_BUFFERS", "false") == "true"
    include("large_buffers.jl")
end
