import Malt as m
using Test

include("basic.jl")
include("exceptions.jl")
include("nesting.jl")
include("benchmark.jl")



#TODO: 
# test that worker.expected_replies is empty after a call
