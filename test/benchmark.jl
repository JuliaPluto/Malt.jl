using BenchmarkTools
using Test
import Malt as m
import Distributed

# Set to true to fail tests if benchmark is too slow
const TEST_BENCHMARK = false


@testset "Benchmark" begin
    
    
    w = m.Worker()
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
            1+1
        end
    ]
    
    @testset "Expr $i" for i in eachindex(exprs)
        ex = exprs[i]
        
        f1() = m.remote_eval_fetch(Main, w, ex)
        f2() = Distributed.remotecall_eval(Main, p, ex)
        
        @test f1() == f2() || f1() ≈ f2()
        
        t1 = @belapsed $f1()
        t2 = @belapsed $f2()
        
        ratio = t1 / t2
        
        @info "Expr $i" ratio t1 t2 
        
        if TEST_BENCHMARK
            @test (
                # one of these should pass:
                ratio < 1.1 || # < 10% slower, or
                t1 - t2 < 0.001 # < 1ms slower
            )
        end
    end
    
    m.stop(w)
end