

@testset "Starting exceptions" begin
    # Searching for strings requires Julia 1.8
    needle = VERSION >= v"1.8.0" ? ["exited before we could connect", "threads"] : ErrorException
    
    tstart = time()
    @test_throws needle m.Worker(; exeflags = ["-t invalid"])
    tend = time()
    
    @test tend - tstart < 15.0
end