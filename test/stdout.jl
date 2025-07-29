using IOCapture

@testset "Stdout & stderr" begin
    w = m.Worker()
    
    cap(expr) = IOCapture.capture(color=true) do
        m.remote_eval_wait(w, expr)
        sleep(0.1)
    end.output
    
    blue = "\e[34m"
    red = "\e[31m"
    reset = "\e[39m"
    
    s = cap(:(println("hello")))
    @test occursin("hello", s)
    @test occursin(blue, s)
    @test !occursin(red, s)
    @test occursin(r"worker"i, s)
    
    s = cap(:(println(stderr, "hello")))
    @test occursin("hello", s)
    @test !occursin(blue, s)
    @test occursin(red, s) 
    
    s = cap(:(println("hello\nworld")))
    @test occursin("hello", s)
    @test occursin("world", s)
    @test count(blue, s) == 2
    @test count(red, s) == 0
    @test count("\n", s) >= 4
    
    m.stop(w)
end
