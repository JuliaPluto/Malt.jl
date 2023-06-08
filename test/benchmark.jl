using BenchmarkTools
using Test
import Malt as m
import Distributed

# Set to true to fail tests if benchmark is too slow
const TEST_BENCHMARK = true


@testset "Benchmark: $W" for W in (m.InProcessWorker, m.Worker)
    
    
    w = W()
    @test m.isrunning(w) === true
    
    
    
    p = Distributed.addprocs(1)[1]
    
    
    
    exprs = [
        quote
            sum(1:100) do i
                sum(sin.(sqrt.(1:i))) / i
            end
        end
    
        quote
            sleep(.01)
        end
        
        quote
            zeros(UInt8, 50_000_000)
        end
        
        quote
            Dict(Symbol("x", i) => (x=i,) for i in 1:1000)
        end
    
        quote
            1+1
        end
    ]
    
    @testset "Expr $i" for i in eachindex(exprs)
        ex = exprs[i]
        
        f1() = m.remote_eval_fetch(Main, w, ex)
        f2() = Distributed.remotecall_eval(Main, p, ex)
        
        @test f1() == f2() || f1() ≈ f2()
        
        b1 = @benchmark $f1()
        b2 = @benchmark $f2()
        
        t1 = mean(b1).time
        t2 = mean(b2).time

        σ1 = BenchmarkTools.std(b1).time
        σ2 = BenchmarkTools.std(b2).time

        tdiff = t1 - t2
        σdiff = sqrt(σ1^2 + σ2^2)

        ratio = t1 / t2
        
        @info "Expr $i" ratio diff=Text("$tdiff ± $σdiff)") b1 b2
        
        if TEST_BENCHMARK
            # we should be faster, i.e.
            # @test tdiff < 0

            # and we have an admissible error of 2.5%
            @test tdiff < 2*σdiff
        end
    end
    
    m.stop(w)
    Distributed.rmprocs(p) |> wait
end



@testset "Benchmark launch" begin
    function launch_with_malt()
        w = m.Worker()
        @assert(2 == m.remotecall_fetch(+, w, 1, 1))
        m.stop(w)
        isdefined(m, :_wait_for_exit) || return
        m._wait_for_exit(w)
    end

    function launch_with_distributed()
        p = Distributed.addprocs(1) |> only
        @assert(2 == Distributed.remotecall_fetch(+, p, 1, 1))
        Distributed.rmprocs(p) |> wait
    end
    
    launch_with_malt()
    launch_with_distributed()
    
    t1 = @belapsed $launch_with_malt()
    t2 = @belapsed $launch_with_distributed()
    ratio = t1 / t2
    
    @info "Launch benchmark" ratio t1 t2 

    if TEST_BENCHMARK
        @test ratio < 1.1
    end
end
