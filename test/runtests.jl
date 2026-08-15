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
