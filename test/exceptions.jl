
@testset "Serialization Exceptions" begin
    ## Serializing values of unknown types will cause an exception.
    w = m.Worker() # does not apply to Malt.InProcessWorker

    stub_type_name = gensym(:NonLocalType)

    m.remote_eval_wait(w, quote
        struct $(stub_type_name) end
    end)

    @test_throws(
        Exception,
        m.remote_eval_fetch(w, quote
            $stub_type_name()
        end),
    )
    @test m.remotecall_fetch(&, w, true, true)


    ## Throwing unknown exceptions will definitely cause an exception.

    stub_type_name2 = gensym(:NonLocalException)

    m.remote_eval_wait(w, quote
        struct $stub_type_name2 <: Exception end
    end)

    @test_throws(
        Exception,
        m.remote_eval_fetch(w, quote
            throw($stub_type_name2())
        end),
    )
    @test m.remotecall_fetch(&, w, true, true)


    ## Catching unknown exceptions and returning them as values also causes an exception.

    @test_throws(
        Exception,
        m.remote_eval_fetch(w, quote
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
