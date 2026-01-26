using IOCapture

@testset "Stdout & stderr" begin
    w = m.Worker()
    
    cap(expr) = IOCapture.capture(color=true) do
        m.remote_eval_wait(w, expr)
        sleep(0.1)
    end.output
    
    blue = "\e[34m"
    yellow = "\e[33m"
    reset = "\e[39m"
    
    s = cap(:(println("hello")))
    @test occursin("hello", s)
    @test occursin(blue, s)
    @test !occursin(yellow, s)
    @test occursin(r"worker"i, s)
    @test 1 <= count("\n", s) <= 2
    
    s = cap(:(println(stderr, "hello")))
    @test occursin("hello", s)
    @test !occursin(blue, s)
    @test occursin(yellow, s)
    @test 1 <= count("\n", s) <= 2
    
    s = cap(:(println("hello\nworld")))
    @test occursin("hello", s)
    @test occursin("world", s)
    @test count(blue, s) == 2
    @test count(yellow, s) == 0
    @test 2 <= count("\n", s) <= 3
    
    m.stop(w)
end

@testset "Stdout & stderr custom pipe" begin
    w = m.Worker(; monitor_stdout=false, monitor_stderr=true)
    
    cap(expr) = IOCapture.capture(color=true) do
        m.remote_eval_wait(w, expr)
        sleep(0.1)
    end.output
    
    blue = "\e[34m"
    yellow = "\e[33m"
    reset = "\e[39m"
    
    s = cap(:(println("hallootjes")))
    @test s == ""
    
    s = cap(:(println(stderr, "hello")))
    @test occursin("hello", s)
    @test !occursin(blue, s)
    @test occursin(yellow, s)
    @test 1 <= count("\n", s) <= 2
    
    # Now I should be able to read the `stdout` pipe manually
    pipe_contents = Base.readavailable(w.stdout) |> String
    @test occursin("hallootjes", pipe_contents)
    @test !occursin(blue, pipe_contents)
    @test !occursin(yellow, pipe_contents)
    
    m.stop(w)
end
