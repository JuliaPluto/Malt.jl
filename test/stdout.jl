using IOCapture

@testset "Stdout & stderr" begin
    w = m.Worker()
    
    cap(expr) = IOCapture.capture() do
        m.remote_eval_wait(w, expr)
        sleep(0.1)
    end.output
    
    s = cap(:(println("hello")))
    @test occursin("hello", s)
    @test occursin("🔵", s)
    @test !occursin("🔴", s)
    @test occursin(r"worker"i, s)
    
    s = cap(:(println(stderr, "hello")))
    @test occursin("hello", s)
    @test !occursin("🔵", s)
    @test occursin("🔴", s) 
    
    s = cap(:(println("hello\nworld")))
    @test occursin("hello", s)
    @test occursin("world", s)
    @test count("🔵", s) == 2
    @test count("🔴", s) == 0
    @test count("\n", s) >= 4
    
    m.stop(w)
end
