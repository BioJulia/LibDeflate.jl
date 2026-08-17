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
