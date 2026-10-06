

@testset "Starting exceptions" begin
    # Searching for strings requires Julia 1.8
    needle = VERSION >= v"1.8.0" ? ["exited before we could connect", "threads"] : ErrorException

    tstart = time()
    @test_throws needle m.Worker(; exeflags = ["-t invalid"])
    tend = time()

    # The process exits right away on invalid arguments, so this must not wait for the
    # connect timeout.
    @test tend - tstart < 20.0
end
