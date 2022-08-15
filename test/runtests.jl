import Malt as m
using Test

# NOTE: These tests are just sanity checks.
# They don't try to find edge cases or anything,
# If they fail something is definitely wrong.
# More tests should be added in the future.


@testset "Worker management" begin
    w = m.Worker()
    @test m.isrunning(w) === true

    # Terminating workers takes about 0.5s
    m.stop(w)
    sleep(1)
    @test m.isrunning(w) === false
end


@testset "Evaluating functions" begin
    w = m.Worker()
    @test m.isrunning(w)
    @test m.remotecall_fetch(&, w, true, true)

    m.stop(w)
end


@testset "Evaluating expressions" begin
    w = m.Worker()
    @test m.isrunning(w) === true

    m.remote_eval_wait(w, :(module Stub end))

    str= "x is in Stub"

    m.remote_eval_wait(w, quote
        Core.eval(Stub, :(x = $$str))
    end)

    @test m.remote_eval_fetch(w, :(Stub.x)) == str

    m.stop(w)
end


@testset "Worker channels" begin
    w = m.Worker()

    lc = m.worker_channel(w, :(rc = Channel()))

    @testset for _i in 1:100
        n = rand(Int)

        m.remote_eval(w, quote
            put!(rc, $(n))
        end)

        @test take!(lc) === n
    end

    m.stop(w)
end

@testset "Signals" begin
    w = m.Worker()

    m.remote_eval(w, quote
        sleep(1_000_000)
    end)

    m.interrupt(w)
    @test m.isrunning(w) === true

    m.stop(w)
    sleep(1)
    @test m.isrunning(w) === false
end

