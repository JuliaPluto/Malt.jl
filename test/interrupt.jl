# @testset "Interrupt: $W" for W in (m.DistributedStdlibWorker, m.InProcessWorker, m.Worker)
@testset "Interrupt: $W" for W in (m.Worker,)


    w = W()

    # m.interrupt(w)
    @test m.isrunning(w)
    @test m.remote_call_fetch(&, w, true, true)
    
    
    ex1 = quote
        local x = 0.0
        for i in 1:20_000_000
            x += sqrt(abs(sin(cos(tan(x)))))^(1/i)
        end
        x
    end
    
    exs = [
        ex1,
        quote
            sleep(3)
        end,
        ex1, # second time because interrupts should be reliable
    ]

    @testset "single interrupt $ex" for ex in exs
        
        f() = m.remote_eval(w, ex)
        
        t1 = @elapsed wait(f())
        t2 = @elapsed wait(f())
        @info "first run" t1 t2
        
        t3 = @elapsed begin
            t = f()
            @test !istaskdone(t)
            m.interrupt(w)
            @test try
                wait(t)
                nothing
            catch e
                e
            end isa TaskFailedException
            # @test t.exception isa InterruptException
        end
        
        @info "test run" t1 t2 t3
        @test t3 < min(t1,t2) * 0.8
        
        # still running and responsive
        @test m.isrunning(w)
        @test m.remote_call_fetch(&, w, true, true)
        
    end
    
    @testset "hard interrupt" begin
        t = m.remote_eval(w, :(while true end))
        
        @test !istaskdone(t)
        @test m.isrunning(w)
        m.interrupt_auto(w)
        @info "xx" istaskdone(t) m.isrunning(w)
        
        @test try
            wait(t)
            nothing
        catch e
            e
        end isa TaskFailedException
        
        # hello
        @test true
        
        if Sys.iswindows()
            @info "Interrupt done" m.isrunning(w)
        else
            # still running and responsive
            @test m.isrunning(w)
            @test m.remote_call_fetch(&, w, true, true)
        end
    end
    
    
    m.stop(w)
    @test !m.isrunning(w)
end