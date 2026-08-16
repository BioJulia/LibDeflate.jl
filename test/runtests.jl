using LibDeflate
using Test
using CodecZlib

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
