using LibDeflate
using Test
using CodecZlib

@testset "DEFLATE" begin
    include("deflate.jl")
end

@testset "gzip" begin
    include("gzip.jl")
end

@testset "zlib" begin
    include("zlib.jl")
end
