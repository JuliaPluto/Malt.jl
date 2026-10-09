

@testset "Starting exceptions" begin
    # Searching for strings requires Julia 1.8
    needle = VERSION >= v"1.8.0" ? ["exited before we could connect", "threads"] : ErrorException

    tstart = time()
    @test_throws needle m.Worker(; exeflags = ["-t invalid"])
    tend = time()

    # When we create a worker we start a timedwait (currently of 30 seconds), trying to
    # connect to it.  When the Julia process is launched with invalid arguments, the poll
    # will time out because it'll fail to connect to it.  Here we check that the whole
    # process took a reasonable time around 30 seconds.
    @test 25.0 < tend - tstart < 40.0
end
