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
        
        bench1 = @benchmarkable $f1()
        bench2 = @benchmarkable $f2()

        # we tune the first benchmark, and use the same tuned parameters for the second benchmark, to make the comparison fair.
        tune!(bench1)
        bench2.params = bench1.params

        b1 = run(bench1)
        b2 = run(bench2)
        
        mean1 = mean(b1).time
        mean2 = mean(b2).time

        median1 = BenchmarkTools.median(b1).time
        median2 = BenchmarkTools.median(b2).time

        σ1 = BenchmarkTools.std(b1).time
        σ2 = BenchmarkTools.std(b2).time

        tdiff = mean1 - mean2
        σdiff = sqrt(σ1^2 + σ2^2)

        ratio_mean = mean1 / mean2
        ratio_median = median1 / median2
        
        @info "Expr $i" mean1 mean2 ratio_mean ratio_median diff=Text("$round(Int64, tdiff) ± $round(Int64, σdiff))") b1 b2
        
        if TEST_BENCHMARK
            # we should be faster, i.e.
            # @test tdiff < 0

            # and we have an admissible error of 2.5%
            @test tdiff < 2*σdiff

            # NO because the samples are not normally distributed
            # so let's just do a percentage again
            @test ratio_median < 1.2
        end
    end
    
    m.stop(w)
    Distributed.rmprocs(p; waitfor=30)
end



@testset "Benchmark launch" begin
    function launch_with_malt()
        w = m.Worker()
        @assert(2 == m.remotecall_fetch(+, w, 1, 1))
        m.stop(w)
    end

    function launch_with_distributed()
        p = Distributed.addprocs(1) |> only
        @assert(2 == Distributed.remotecall_fetch(+, p, 1, 1))
        Distributed.rmprocs(p; waitfor=30)
    end
    
    # run once to precompile
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
