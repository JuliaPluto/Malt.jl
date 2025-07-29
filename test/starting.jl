

@testset "Starting exceptions" begin
    
    tstart = time()
    @test_throws ["exited before we could connect", "threads"] m.Worker(; exeflags = ["-t invalid"])
    tend = time()
    
    @test tend - tstart < 15.0
    
end