import Malt as m
using Test

# NOTE: These tests are just sanity checks.
# They don't try to find edge cases or anything,
# If they fail something is definitely wrong.
# More tests should be added in the future.


@testset "Impl: $W" for W in (m.InProcessWorker, m.Worker)
    @testset "Worker management" begin
        w = W()
        @test m.isrunning(w) === true

        # Terminating workers takes about 0.5s
        m.stop(w)
        @test m.isrunning(w) === false
    end


    @testset "Evaluating functions" begin
        w = W()
        @test m.isrunning(w)
        @test m.remotecall_fetch(&, w, true, true)

        m.stop(w)
    end


    @testset "Evaluating expressions" begin
        w = W()
        @test m.isrunning(w) === true

        m.remote_eval_wait(Main, w, :(module Stub end))

        str = "x is in Stub"

        m.remote_eval_wait(Main, w, quote
            Core.eval(Stub, :(x = $$str))
        end)

        @test m.remote_eval_fetch(Main, w, :(Stub.x)) == str

        m.stop(w)
    end


    @testset "Worker channels" begin
        w = W()

        channel_size = 20
        
        lc = m.worker_channel(w, :(rc = Channel($channel_size)))
        
        @test lc isa AbstractChannel

        @testset for _i in 1:10
            n = rand(Int)

            m.remote_eval(Main, w, quote
                put!(rc, $(n))
            end)

            @test take!(lc) === n
            
            put!(lc, n)
            @test take!(lc) === n
            put!(lc, n)
            put!(lc, n)
            @test take!(lc) === n
            @test take!(lc) === n
            
        end
        
        
        
        t = @async begin
            for i in 1:2*channel_size
                @test take!(lc) == i
            end
            @test !isready(lc)
        end
        
        for i in 1:2*channel_size
            put!(lc, i)
        end
        
        wait(t)
        
        

        m.stop(w)
    end

    @testset "Signals" begin
        w = W()

        m.remote_eval(Main, w, quote
            sleep(1_000_000)
        end)

        m.interrupt(w)
        @test m.isrunning(w) === true

        m.stop(w)
        @test m.isrunning(w) === false
    end

    @testset "Regular Exceptions" begin
        w = W()

        ## Mutually Known errors are not thrown, but returned as values.

        @test isa(
            m.remote_eval_fetch(Main, w, quote
                sqrt(-1)
            end),
            DomainError,
        )
        @test m.remotecall_fetch(&, w, true, true)

        @test isa(
            m.remote_eval_fetch(Main, w, quote
                error("Julia stack traces are bad. GL 😉")
            end),
            ErrorException,
        )
        @test m.remotecall_fetch(&, w, true, true)
    end
end

@testset "Serialization Exceptions" begin
    ## Serializing values of unknown types will cause an exception.
    w = m.Worker() # does not apply to Malt.InProcessWorker

    stub_type_name = gensym(:NonLocalType)

    m.remote_eval_wait(Main, w, quote
        struct $(stub_type_name) end
    end)

    @test_throws(
        Exception,
        m.remote_eval_fetch(Main, w, quote
            $stub_type_name()
        end),
    )
    @test m.remotecall_fetch(&, w, true, true)


    ## Throwing unknown exceptions will definitely cause an exception.

    stub_type_name2 = gensym(:NonLocalException)

    m.remote_eval_wait(Main, w, quote
        struct $stub_type_name2 <: Exception end
    end)

    @test_throws(
        Exception,
        m.remote_eval_fetch(Main, w, quote
            throw($stub_type_name2())
        end),
    )
    @test m.remotecall_fetch(&, w, true, true)


    ## Catching unknown exceptions and returning them as values also causes an exception.

    @test_throws(
        Exception,
        m.remote_eval_fetch(Main, w, quote
            try
                throw($stub_type_name2())
            catch e
                e
            end
        end),
    )
    @test m.remotecall_fetch(&, w, true, true)
    
    
    # TODO
    # @test_throws(
    #     Exception,
    #     m.worker_channel(w, :(123))
    # )
    # @test_throws(
    #     Exception,
    #     m.worker_channel(w, :(sqrt(-1)))
    # )

    # The worker should be able to handle all that throwing
    @test m.isrunning(w)

    m.stop(w)
    @test !m.isrunning(w)
end

include("nesting.jl")
include("benchmark.jl")





#TODO: 
# test that worker.expected_replies is empty after a call
