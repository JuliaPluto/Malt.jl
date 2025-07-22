import Malt as m
using Test


v() = @assert isempty(m.__iNtErNaL_get_running_procs())

v()
# include("interrupt.jl")
# v()
# include("basic.jl")
# v()
# include("exceptions.jl")
# v()
# include("nesting.jl")
v()
include("benchmark.jl")
v()
include("podman.jl")
v()
include("checkpoint.jl")
v()


#TODO: 
# test that worker.expected_replies is empty after a call
