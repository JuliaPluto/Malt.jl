using Test
import Malt as m

# Check if CRIU (checkpoint/restore) is available
function criu_available()
    try
        # Check if podman supports checkpoints
        result = read(`podman info --format json`, String)
        return occursin("checkpoints", result)
    catch
        return false
    end
end

@testset "PodmanWorker Checkpoint/Restore Tests" begin
    if !m.PodmanWorker isa Type
        @warn "PodmanWorker not available, skipping checkpoint tests"
        return
    end
    
    if !criu_available()
        @warn "CRIU/checkpoint support not available, skipping checkpoint tests"
        return
    end
    
    @testset "Basic Checkpoint/Restore Functionality" begin
        # Create a worker and set up some state
        w = m.PodmanWorker(image="docker.io/julia:latest")
        
        try
            # Set up some state in the worker
            m.remote_eval_wait(w, :(test_variable = 42))
            m.remote_eval_wait(w, :(test_array = [1, 2, 3, 4, 5]))
            
            # Verify state is set
            @test m.remote_eval_fetch(w, :test_variable) == 42
            @test m.remote_eval_fetch(w, :test_array) == [1, 2, 3, 4, 5]
            
            checkpoint_name = "test_checkpoint_$(time_ns())"
            
            # Create checkpoint
            @info "Creating checkpoint..."
            success = m.checkpoint(w, checkpoint_name)
            @test success == true
            
            # Verify checkpoint exists
            checkpoints = m.list_checkpoints()
            @test checkpoint_name in checkpoints
            
            # Stop the original worker
            m.stop(w)
            @test !m.isrunning(w)
            
            # Restore from checkpoint
            @info "Restoring from checkpoint..."
            w_restored = m.restore(checkpoint_name)
            @test w_restored !== nothing
            @test w_restored isa m.PodmanWorker
            @test m.isrunning(w_restored)
            
            # Verify state is preserved
            @test m.remote_eval_fetch(w_restored, :test_variable) == 42
            @test m.remote_eval_fetch(w_restored, :test_array) == [1, 2, 3, 4, 5]
            
            # Test that we can continue working with restored worker
            result = m.remote_eval_fetch(w_restored, :(test_variable * 2))
            @test result == 84
            
            # Clean up
            m.stop(w_restored)
            m.remove_checkpoint(checkpoint_name)
            
        finally
            # Ensure cleanup
            if m.isrunning(w)
                m.stop(w)
            end
        end
    end
    
    @testset "Checkpoint Export/Import" begin
        w = m.PodmanWorker(image="docker.io/julia:latest")
        
        try
            # Set up state
            m.remote_eval_wait(w, :(exported_data = "checkpoint_test_data"))
            
            checkpoint_name = "export_test_$(time_ns())"
            export_dir = mktempdir()
            
            # Create checkpoint with export
            @info "Creating checkpoint with export..."
            success = m.checkpoint(w, checkpoint_name; export_path=export_dir)
            @test success == true
            
            # Verify export file exists
            export_file = joinpath(export_dir, "$checkpoint_name.tar")
            @test isfile(export_file)
            
            # Stop worker
            m.stop(w)
            
            # Remove the checkpoint from podman storage
            m.remove_checkpoint(checkpoint_name)
            
            # Restore from exported file
            @info "Restoring from exported checkpoint..."
            w_restored = m.restore(checkpoint_name; import_path=export_dir)
            @test w_restored !== nothing
            @test m.isrunning(w_restored)
            
            # Verify state
            @test m.remote_eval_fetch(w_restored, :exported_data) == "checkpoint_test_data"
            
            # Clean up
            m.stop(w_restored)
            rm(export_dir; recursive=true)
            
        finally
            if m.isrunning(w)
                m.stop(w)
            end
        end
    end
    
    @testset "Checkpoint Error Handling" begin
        # Test checkpointing a stopped worker
        w = m.PodmanWorker(image="docker.io/julia:latest")
        m.stop(w)
        
        @test m.checkpoint(w, "should_fail") == false
        
        # Test restoring non-existent checkpoint
        restored = m.restore("non_existent_checkpoint")
        @test restored === nothing
        
        # Test with invalid export path for import
        restored = m.restore("test"; import_path="/invalid/path/that/does/not/exist")
        @test restored === nothing
    end
    
    @testset "Checkpoint Management" begin
        w = m.PodmanWorker(image="docker.io/julia:latest")
        
        try
            checkpoint_name = "mgmt_test_$(time_ns())"
            
            # Create checkpoint
            @test m.checkpoint(w, checkpoint_name) == true
            
            # List checkpoints
            checkpoints = m.list_checkpoints()
            @test checkpoint_name in checkpoints
            
            # Remove checkpoint
            @test m.remove_checkpoint(checkpoint_name) == true
            
            # Verify it's removed
            checkpoints_after = m.list_checkpoints()
            @test !(checkpoint_name in checkpoints_after)
            
        finally
            m.stop(w)
        end
    end
    
    @testset "Multiple Checkpoints" begin
        w = m.PodmanWorker(image="docker.io/julia:latest")
        
        try
            checkpoint_names = []
            
            # Create multiple checkpoints with different states
            for i in 1:3
                m.remote_eval_wait(w, :(checkpoint_state = $i * 10))
                checkpoint_name = "multi_test_$(i)_$(time_ns())"
                push!(checkpoint_names, checkpoint_name)
                
                @test m.checkpoint(w, checkpoint_name) == true
                
                # Verify state
                @test m.remote_eval_fetch(w, :checkpoint_state) == i * 10
            end
            
            # List all checkpoints
            all_checkpoints = m.list_checkpoints()
            for name in checkpoint_names
                @test name in all_checkpoints
            end
            
            # Clean up checkpoints
            for name in checkpoint_names
                @test m.remove_checkpoint(name) == true
            end
            
        finally
            m.stop(w)
        end
    end
    
    @testset "Checkpoint State Consistency" begin
        w = m.PodmanWorker(image="docker.io/julia:latest")
        
        try
            # Set up complex state
            m.remote_eval_wait(w, quote
                struct TestStruct
                    x::Int
                    y::String
                end
                
                global test_struct = TestStruct(123, "hello")
                global test_dict = Dict("a" => 1, "b" => 2, "c" => 3)
                global test_function_result = map(x -> x^2, [1, 2, 3, 4])
            end)
            
            checkpoint_name = "consistency_test_$(time_ns())"
            @test m.checkpoint(w, checkpoint_name) == true
            
            # Stop and restore
            m.stop(w)
            w_restored = m.restore(checkpoint_name)
            @test w_restored !== nothing
            
            # Verify complex state is preserved
            struct_result = m.remote_eval_fetch(w_restored, :(test_struct.x, test_struct.y))
            @test struct_result == (123, "hello")
            
            dict_result = m.remote_eval_fetch(w_restored, :test_dict)
            @test dict_result == Dict("a" => 1, "b" => 2, "c" => 3)
            
            function_result = m.remote_eval_fetch(w_restored, :test_function_result)
            @test function_result == [1, 4, 9, 16]
            
            # Clean up
            m.stop(w_restored)
            m.remove_checkpoint(checkpoint_name)
            
        finally
            if m.isrunning(w)
                m.stop(w)
            end
        end
    end
end