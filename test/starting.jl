

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

@testset "Connect timeout" begin
    needle = VERSION >= v"1.8.0" ? ["did not report its port within 2.0 seconds", "JULIA_WORKER_TIMEOUT"] : ErrorException
    # `-e` runs instead of the worker script, so the process stays alive without printing a port.
    silent = ["-e", "sleep(120)"]

    tstart = time()
    @test_throws needle m.Worker(; exeflags = silent, connect_timeout = 2.0)
    @test time() - tstart < 15.0

    withenv("JULIA_WORKER_TIMEOUT" => "2") do
        @test m._default_connect_timeout() == 2.0
        @test_throws needle m.Worker(; exeflags = silent)
    end
    @test m._poll(() -> isempty(m.__iNtErNaL_get_running_procs()); timeout_s = 10)

    w = m.Worker(; connect_timeout = 60)
    @test m.remote_call_fetch(+, w, 1, 2) == 3
    m.stop(w)
end
