using Test
import Malt as m

# Check if podman is available before running tests
function podman_available()
    try
        run(`podman --version`)
        return true
    catch
        return false
    end
end

# Check if Julia Docker image is available
function julia_image_available()
    try
        result = read(`podman images --format "{{.Repository}}:{{.Tag}}"`, String)
        return occursin("docker.io/julia:", result) || occursin("julia:", result)
    catch
        return false
    end
end

@testset "PodmanWorker Tests" begin
    if !podman_available()
        @warn "Podman not available, skipping PodmanWorker tests"
        return
    end
    
    if !julia_image_available()
        @info "Pulling Julia Docker image for PodmanWorker tests..."
        try
            run(`podman pull docker.io/julia:latest`)
        catch e
            @warn "Could not pull Julia image, skipping PodmanWorker tests" exception=e
            return
        end
    end
    
    @testset "PodmanWorker Creation and Basic Operations" begin
        @info "Creating PodmanWorker..."
        w = m.PodmanWorker(image="docker.io/julia:latest")
        
        @test w isa m.PodmanWorker
        @test m.isrunning(w)
        @test !isempty(w.container_id)
        @test w.host_port > 0
        @test w.container_port == 9001
        
        # Test basic remote evaluation
        @test m.remote_eval_fetch(w, :(1 + 1)) == 2
        @test m.remote_eval_fetch(w, :(rand())) isa Float64
        
        # Test remote call
        result = m.remote_call_fetch(+, w, 2, 3)
        @test result == 5
        
        # Test variables persist
        m.remote_eval_wait(w, :(x = 42))
        @test m.remote_eval_fetch(w, :x) == 42
        
        # Clean up
        @test m.stop(w) == true
        @test !m.isrunning(w)
    end
    
    @testset "PodmanWorker Remote Calls" begin
        w = m.PodmanWorker(image="docker.io/julia:latest")
        
        try
            # Test async remote call
            task = m.remote_call(sqrt, w, 16)
            @test fetch(task) == 4.0
            
            # Test remote_call_wait
            m.remote_call_wait(println, w, "Hello from container!")
            
            # Test remote_do (fire and forget)
            m.remote_do(x -> x^2, w, 5)  # Should not return anything
            sleep(0.1)  # Give it time to execute
            
            # Test functions with keyword arguments
            result = m.remote_call_fetch(w, 1, 2, 3) do a, b, c
                a + b * c
            end
            @test result == 7
            
        finally
            m.stop(w)
        end
    end
    
    @testset "PodmanWorker Exception Handling" begin
        w = m.PodmanWorker(image="docker.io/julia:latest")
        
        try
            # Test that exceptions are properly propagated
            @test_throws m.RemoteException m.remote_eval_fetch(w, :(error("test error")))
            
            # Test that worker is still functional after exception
            @test m.remote_eval_fetch(w, :(2 + 2)) == 4
            
        finally
            m.stop(w)
        end
    end
    
    @testset "PodmanWorker Interrupts" begin
        w = m.PodmanWorker(image="docker.io/julia:latest")
        
        try
            # Start a long-running task
            task = m.remote_eval(w, :(sleep(10)))
            sleep(0.5)  # Let it start
            
            # Interrupt it
            m.interrupt(w)
            
            # Task should fail with interrupt
            @test_throws TaskFailedException wait(task)
            
            # Worker should still be functional
            @test m.remote_eval_fetch(w, :(1 + 1)) == 2
            
        finally
            m.stop(w)
        end
    end
    
    @testset "PodmanWorker Environment Variables" begin
        w = m.PodmanWorker(image="docker.io/julia:latest", env=["TEST_VAR=podman_test"])
        
        try
            # Test that environment variable is set
            result = m.remote_eval_fetch(w, :(get(ENV, "TEST_VAR", "not_found")))
            @test result == "podman_test"
            
            # Test that OPENBLAS_NUM_THREADS is set to 1
            result = m.remote_eval_fetch(w, :(get(ENV, "OPENBLAS_NUM_THREADS", "not_found")))
            @test result == "1"
            
        finally
            m.stop(w)
        end
    end
    
    @testset "PodmanWorker Multiple Workers" begin
        workers = m.PodmanWorker[]
        
        try
            # Create multiple workers
            for i in 1:3
                push!(workers, m.PodmanWorker(image="docker.io/julia:latest"))
            end
            
            @test all(m.isrunning, workers)
            @test allunique([w.host_port for w in workers])  # Each should have unique port
            @test allunique([w.container_id for w in workers])  # Each should have unique container
            
            # Test they can work independently
            tasks = []
            for (i, w) in enumerate(workers)
                push!(tasks, m.remote_call(*, w, i, 10))
            end
            
            results = fetch.(tasks)
            @test results == [10, 20, 30]
            
        finally
            for w in workers
                m.stop(w)
            end
        end
    end
    
    @testset "PodmanWorker Cleanup" begin
        # Test that containers are properly cleaned up
        initial_containers = try
            read(`podman ps -q`, String) |> strip |> s -> split(s, '\n') |> length
        catch
            0
        end
        
        w = m.PodmanWorker(image="docker.io/julia:latest")
        container_id = w.container_id
        
        # Verify container exists
        @test m.isrunning(w)
        
        # Stop worker
        m.stop(w)
        
        # Verify container is removed (--rm flag should clean it up)
        sleep(1)  # Give podman time to clean up
        @test !m.isrunning(w)
        
        # Check that we don't have extra containers
        final_containers = try
            read(`podman ps -q`, String) |> strip |> s -> split(s, '\n') |> length
        catch
            0
        end
        
        @test final_containers <= initial_containers
    end
    
    @testset "PodmanWorker Stress Test" begin
        w = m.PodmanWorker(image="docker.io/julia:latest")
        
        try
            # Run many operations in parallel
            tasks = []
            for i in 1:20
                push!(tasks, m.remote_call(w) do
                    sum(rand(100))
                end)
            end
            
            results = fetch.(tasks)
            @test length(results) == 20
            @test all(x -> x isa Float64, results)
            
        finally
            m.stop(w)
        end
    end
end

# Run validation that existing tests work with PodmanWorker
@testset "PodmanWorker Compatibility with Existing Tests" begin
    if !podman_available() || !julia_image_available()
        @warn "Skipping compatibility tests - podman or Julia image not available"
        return
    end
    
    # Create a test worker factory function
    create_test_worker() = m.PodmanWorker(image="docker.io/julia:latest")
    
    @testset "Basic functionality with PodmanWorker" begin
        worker = create_test_worker()
        
        try
            # Test basic arithmetic
            @test m.remote_eval_fetch(worker, :(1 + 1)) == 2
            @test m.remote_eval_fetch(worker, :(2 * 3)) == 6
            
            # Test variable assignment and retrieval
            m.remote_eval_wait(worker, :(test_var = 42))
            @test m.remote_eval_fetch(worker, :test_var) == 42
            
            # Test function calls
            @test m.remote_call_fetch(abs, worker, -5) == 5
            @test m.remote_call_fetch(length, worker, "hello") == 5
            
            # Test arrays
            result = m.remote_eval_fetch(worker, :([1, 2, 3, 4]))
            @test result == [1, 2, 3, 4]
            
        finally
            m.stop(worker)
        end
    end
    
    @testset "Exception handling with PodmanWorker" begin
        worker = create_test_worker()
        
        try
            # Test error propagation
            @test_throws m.RemoteException m.remote_eval_fetch(worker, :(error("test")))
            
            # Test that worker recovers
            @test m.remote_eval_fetch(worker, :(1 + 1)) == 2
            
            # Test undefined variable error
            @test_throws m.RemoteException m.remote_eval_fetch(worker, :undefined_var)
            
        finally
            m.stop(worker)
        end
    end
end