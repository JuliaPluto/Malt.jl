@testset "Starting exceptions" begin
    needle = VERSION >= v"1.8.0" ? ["Could not start worker", "threads"] : ErrorException
    @test_throws needle m.Worker(; exeflags = ["-t invalid"], connect_timeout = 10)
end

@testset "Failed startup leaves no running worker" begin
    for (announcement, timeout, diagnostic, error_type) in (
        ("not-a-port", 10, "did not announce a valid port", ErrorException),
        ("0", 10, "connect", Base.IOError),
        (nothing, 1, "port announcement timed out", ErrorException),
    )
        before = copy(m.__iNtErNaL_get_running_procs())
        try
            code = announcement === nothing ? "sleep(30)" :
                "println(" * repr(announcement) * "); flush(stdout); sleep(30)"
            failure = try
                m.Worker(; exeflags = ["-e", code], connect_timeout = timeout)
                nothing
            catch err
                err
            end
            @test failure isa error_type
            @test occursin(diagnostic, sprint(showerror, failure))
            @test isempty(setdiff(m.__iNtErNaL_get_running_procs(), before))
        finally
            for proc in setdiff(m.__iNtErNaL_get_running_procs(), before)
                kill(proc, Base.SIGKILL)
                wait(proc)
            end
        end
    end
end
