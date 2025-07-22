"""
PodmanWorker implementation for Malt.jl

This module implements a Worker that runs Julia processes inside Podman containers,
providing additional isolation and containerization benefits.
"""

const docker = "podman"

using Sockets: Sockets
using Serialization: serialize, deserialize

"""
    Malt.PodmanWorker(; image="julia:latest", env=String[], exeflags=[])

Create a new `PodmanWorker`. A `PodmanWorker` struct is a handle to a Julia process
running inside a Podman container.

The worker uses the official Julia Docker image and binds the container's internal
port to a host port for communication.

# Arguments
- `image::String`: Docker/Podman image to use (default: "julia:latest")
- `env::Vector{String}`: Environment variables to pass to the container
- `exeflags::Vector{String}`: Additional Julia flags

# Examples

```julia-repl
julia> w = Malt.PodmanWorker()
Malt.PodmanWorker(container_id="abc123...", host_port=9001)
```
"""
mutable struct PodmanWorker <: AbstractWorker
    container_id::String
    host_port::UInt16
    container_port::UInt16  # Always 9000 inside container
    proc::Base.Process      # The podman process

    current_socket::Sockets.TCPSocket
    current_message_id::MsgID
    expected_replies::Dict{MsgID,Channel{WorkerResult}}

    function PodmanWorker(; image="julia:latest", env=String[], exeflags=[])
        # Find an available host port
        host_port = _find_available_port()
        container_port = UInt16(9001)  # Fixed port inside container

        # Create the worker script path inside container
        # Build podman command
        cmd = _build_podman_cmd(image, host_port, container_port, env, exeflags)

        # Start the container
        proc = run(cmd, wait=false)

        # Get container ID from podman ps (with retry logic)
        container_id = _get_container_id_for_port(host_port)

        # Additional verification: wait for actual worker process readiness
        _wait_for_worker_ready(container_id)

        # Wait for the worker to be ready by trying to connect to the host port
        socket = Sockets.connect(host_port)
        _buffer_writes(socket)

        # Create the worker instance
        w = finalizer(w -> @async(stop(w)),
            new(
                container_id,
                host_port,
                container_port,
                proc,
                socket,
                MsgID(0),
                Dict{MsgID,Channel{WorkerResult}}()
            )
        )

        atexit(() -> stop(w))
        sleep(0.1)
        # Start async tasks only after everything is ready
        _receive_loop(w)
        _exit_loop(w)

        return w
    end
end

Base.summary(io::IO, w::PodmanWorker) = write(io, "Malt.PodmanWorker(container_id=\"$(w.container_id[1:min(8, length(w.container_id))])...\", host_port=$(w.host_port))")

function _find_available_port(start_port::UInt16=UInt16(9001))::UInt16
    for port in start_port:UInt16(10000)
        try
            server = Sockets.listen(port)
            close(server)
            return port
        catch
            continue
        end
    end
    error("Could not find available port for PodmanWorker")
end

function _build_podman_cmd(image, host_port, container_port, env, exeflags)
    # Get source files path from main Malt module


    # Build the command to run inside container
    julia_cmd = ["julia", "--startup-file=no"]
    append!(julia_cmd, exeflags)
    push!(julia_cmd, "/opt/worker.jl")

    # Build podman run command
    podman_args = [
        docker, "run",
        "--rm",  # Remove container when it exits
        "--detach",  # Run in background
        "--network", "bridge",
        "-e JULIA_DEBUG=all",
        "-p", "$(host_port):$(container_port)",  # Port binding
        "-v", "$(@__DIR__):/opt/:ro",  # Mount source files read-only
        "-w", "/opt/",  # Working directory
        "--env", "OPENBLAS_NUM_THREADS=1",
        "--env", "UV_USE_IO_URING=0",
        "--env", "MALT_WORKER_PORT=$(container_port)"
    ]

    # Add custom environment variables
    for e in env
        push!(podman_args, "--env")
        push!(podman_args, e)
    end

    push!(podman_args, image)
    append!(podman_args, julia_cmd)

    return Cmd(podman_args)
end

function _get_container_id_for_port(host_port::UInt16, max_retries::Int=30)::String
    for attempt in 1:max_retries
        try
            # Use podman ps to find container by port mapping - search through all containers
            result = read(`$docker ps --format "{{.ID}} {{.Ports}}"`, String)
            lines = split(strip(result), '\n')
            for line in lines
                if isempty(strip(line))
                    continue
                end

                # Check if this line contains our port
                if occursin("$host_port", line)
                    # Extract container ID from the line
                    parts = split(strip(line), ' ', limit=2)
                    return parts[1]
                end
            end
        catch e
            @debug "Attempt $attempt failed to get container ID" exception = e
        end

        if attempt < max_retries
            sleep(0.5)
        end
    end

    error("Could not find container for port $host_port after $max_retries attempts")
end

function _wait_for_worker_connection(host_port::UInt16, timeout::Int=60)::Sockets.TCPSocket
    start_time = time()

    @info "Waiting for container worker to be ready on port $host_port..."

    while time() - start_time < timeout
        try
            @debug "Attempting to connect to localhost:$host_port"
            socket = Sockets.connect("localhost", host_port)

            # Verify the socket is actually ready for communication
            if _verify_socket_ready(socket)
                @info "Successfully connected to PodmanWorker on port $host_port"
                return socket
            else
                @debug "Socket connected but not ready for communication, retrying..."
            end
        catch e
            @debug "Connection attempt failed" exception = e
        end
        sleep(0.5)
    end

    error("Timeout waiting for PodmanWorker to become ready on port $host_port after $(timeout)s")
end

function _verify_socket_ready(socket::Sockets.TCPSocket, timeout::Float64=2.0)::Bool
    # Simple check: if socket is open and connected, assume it's ready
    # We can't easily do non-blocking verification without risk of blocking
    try
        if isopen(socket) && socket.status == Base.StatusOpen
            # Give a small settling time
            sleep(0.1)
            return true
        end
        return false
    catch e
        @debug "Socket verification failed" exception = e
        return false
    end
end

function _wait_for_worker_ready(container_id::String, timeout::Int=30)
    @info "Waiting for worker process to be fully ready..."
    start_time = time()

    while time() - start_time < timeout
        try
            # Check container logs for the worker's ready message
            logs = read(pipeline(`$docker logs $container_id`; stderr=devnull), String)

            # Look for the port output which indicates the worker is listening
            if occursin(r"\d+\s*$", logs)  # Ends with a number (the port)
                @info "Worker process is ready"
                sleep(0.5)  # Small buffer to ensure everything is settled
                return true
            end
        catch e
            @debug "Failed to check worker readiness" exception = e
        end
        sleep(0.2)
    end

    @warn "Worker readiness check timed out, proceeding anyway"
    return false
end

# Implement AbstractWorker interface

function _send_msg(worker::PodmanWorker, msg_type::UInt8, msg_data, expect_reply::Bool=true)::MsgID
    # _assert_is_running(worker)

    msg_id = (worker.current_message_id += MsgID(1))::MsgID
    if expect_reply
        worker.expected_replies[msg_id] = Channel{WorkerResult}(1)
    end

    @debug("HOST: sending message to PodmanWorker", msg_data)

    _serialize_msg(worker.current_socket, msg_type, msg_id, msg_data)
    return msg_id
end

function _wait_for_response(worker::PodmanWorker, msg_id::MsgID)
    if haskey(worker.expected_replies, msg_id)
        c = worker.expected_replies[msg_id]
        @debug("HOST: waiting for response of", msg_id)
        response = take!(c)
        delete!(worker.expected_replies, msg_id)
        return unwrap_worker_result(worker, response)
    else
        error("HOST: No response expected for message id $msg_id")
    end
end

function _receive_loop(worker::PodmanWorker)
    io = worker.current_socket

    @async begin
        for _i in Iterators.countfrom(1)
            try
                # Check socket health before attempting to read
                if !isopen(io)
                    @debug("HOST: PodmanWorker socket closed.")
                    break
                end

                @debug "HOST: PodmanWorker waiting for message"
                msg_type = try
                    read(io, UInt8)
                catch e
                    if e isa InterruptException
                        @debug("HOST: PodmanWorker caught interrupt while waiting for incoming data, rethrowing to REPL...")
                        _rethrow_to_repl(e; rethrow_regular=false)
                        continue
                    elseif e isa EOFError
                        @debug("HOST: PodmanWorker EOF error, connection closed by worker")
                        break
                    else
                        @debug("HOST: PodmanWorker caught exception while waiting for incoming data, breaking", exception = (e, backtrace()))
                        break
                    end
                end

                msg_id = read(io, MsgID)

                msg_data, success = try
                    deserialize(io), true
                catch err
                    err, false
                finally
                    _discard_until_boundary(io)
                end

                if !success
                    msg_type = MsgType.special_serialization_failure
                end

                c = get(worker.expected_replies, msg_id, nothing)
                if c isa Channel{WorkerResult}
                    put!(c, WorkerResult(msg_type, msg_data))
                else
                    @error "HOST: PodmanWorker received a response, but I didn't ask for anything" msg_type msg_id msg_data
                end

                @debug("HOST: PodmanWorker received message", msg_data)
            catch e
                if e isa InterruptException
                    @debug "HOST: PodmanWorker interrupted during receive loop."
                    _rethrow_to_repl(e)
                elseif e isa Union{Base.IOError,EOFError}
                    @debug "HOST: PodmanWorker connection lost" exception = e
                    if isrunning(worker)
                        @warn "HOST: PodmanWorker connection lost, but container still running. This may indicate a worker crash."
                        # Don't kill immediately, give it a chance to recover
                        sleep(1)
                        if isrunning(worker) && !isopen(io)
                            @info "Stopping unresponsive container"
                            kill(worker, Base.SIGKILL)
                        end
                    end
                    break
                else
                    @error "HOST: PodmanWorker unknown error" exception = (e, catch_backtrace()) isopen(io)
                    break
                end
            end
        end
        @debug("[worker $(worker.host_port)] _receive_loop: exiting")
        stop(w)
    end


end

function _exit_loop(worker::PodmanWorker)
    @async for _i in Iterators.countfrom(1)
        try
            if !isrunning(worker)
                # Container stopped, notify all waiting calls
                for c in values(worker.expected_replies)
                    isready(c) || put!(c, WorkerResult(MsgType.special_worker_terminated, nothing))
                end
                break
            end
            sleep(1)
        catch e
            @warn("Unexpected error in PodmanWorker exit loop", worker = worker, exception = (e, catch_backtrace()))
            _rethrow_to_repl(e; rethrow_regular=false)
        end
    end
end

# Worker lifecycle management

"""
    Malt.isrunning(w::PodmanWorker)::Bool

Check whether the PodmanWorker container is running.
"""
function isrunning(w::PodmanWorker)::Bool
    try
        result = read(`$docker inspect $(w.container_id)`, String)
        return true
    catch
        return false
    end
end

_assert_is_running(w::PodmanWorker) = isrunning(w) || throw(TerminatedWorkerException())

"""
    Malt.stop(w::PodmanWorker; timeout::Real=15.0)::Bool

Stop the PodmanWorker container gracefully, then forcefully if needed.
"""
function stop(w::PodmanWorker; timeout::Real=15.0)
    if !isrunning(w)
        return false
    end

    try
        # Try graceful shutdown first
        run(`$docker stop --time $(Int(timeout)) $(w.container_id)`)
        return true
    catch e
        @warn "Failed to stop PodmanWorker container gracefully" exception = e
        # Force kill if graceful stop failed
        try
            run(`$docker kill $(w.container_id)`)
            return true
        catch e2
            @error "Failed to kill PodmanWorker container" exception = e2
            return false
        end
    end
end

"""
    kill(w::Malt.PodmanWorker, signum=Base.SIGTERM)

Forcefully terminate the PodmanWorker container.
"""
function Base.kill(w::PodmanWorker, signum=Base.SIGTERM)
    try
        if signum == Base.SIGKILL
            run(`$docker kill $(w.container_id)`)
        else
            run(`$docker kill --signal $(signum) $(w.container_id)`)
        end
    catch e
        @warn "Failed to kill PodmanWorker container" exception = e
    end
    nothing
end

"""
    Malt.interrupt(w::PodmanWorker)

Send an interrupt signal to the PodmanWorker container.
"""
function interrupt(w::PodmanWorker)
    if !isrunning(w)
        @warn "Tried to interrupt a PodmanWorker that has already shut down." summary(w)
        return
    end

    try
        run(`$docker kill --signal SIGINT $(w.container_id)`)
    catch e
        @warn "Failed to interrupt PodmanWorker container" exception = e
    end
    nothing
end

# Checkpoint and Restore functionality

"""
    checkpoint(w::PodmanWorker, checkpoint_name::String; export_path::String="")::Bool

Create a checkpoint of the PodmanWorker container state. This allows saving the
current state of the worker process for later restoration.

# Arguments
- `w`: The PodmanWorker to checkpoint
- `checkpoint_name`: Name for the checkpoint
- `export_path`: Optional path to export checkpoint to (for persistence across restarts)

# Returns
- `true` if checkpoint was successful, `false` otherwise

# Examples
```julia
w = Malt.PodmanWorker()
success = Malt.checkpoint(w, "my_checkpoint")
```

# Requirements
- Podman must be built with CRIU support
- Container must be running
- Sufficient disk space for checkpoint data
"""
function checkpoint(w::PodmanWorker; checkpoint_name::String="", export_path::String="")::Bool
    if !isrunning(w)
        @error "Cannot checkpoint a stopped PodmanWorker"
        return false
    end

    try
        @info "Creating checkpoint '$checkpoint_name' for container $(w.container_id)"

        cmd = `$docker container checkpoint $(w.container_id)`

        # If export path is provided, add export option
        if !isempty(export_path)
            # Ensure export directory exists
            mkpath(export_path)
            cmd = `$docker container checkpoint --tcp-established --export=$(export_path)/$checkpoint_name.tar $(w.container_id)`
        end

        # Create the checkpoint
        result = run(cmd)

        if result.exitcode == 0
            @info "Checkpoint '$checkpoint_name' created successfully"
            return true
        else
            @error "Checkpoint creation failed" exitcode = result.exitcode
            return false
        end

    catch e
        @error "Failed to create checkpoint" exception = e
        return false
    end
end

"""
    restore(checkpoint_name::String; import_path::String="", image::String="julia:latest", 
            env::Vector{String}=String[], exeflags::Vector{String}=String[])::Union{PodmanWorker, Nothing}

Restore a PodmanWorker from a previously created checkpoint.

# Arguments
- `checkpoint_name`: Name of the checkpoint to restore
- `import_path`: Path to import checkpoint from (if exported)
- `image`: Docker image to use (should match original)
- `env`: Environment variables to set
- `exeflags`: Julia execution flags

# Returns
- `PodmanWorker` instance if successful, `nothing` if failed

# Examples
```julia
w_restored = Malt.restore("my_checkpoint")
```

# Notes
- The restored container will have a new container ID
- Network port mapping will be reassigned
- Socket connections will need to be re-established
"""
function restore(checkpoint_name::String)::Union{PodmanWorker,Nothing}
    try
        @info "Restoring checkpoint '$checkpoint_name'"

        # Find available port for restored container
        host_port = _find_available_port()
        container_port = UInt16(9001)

        # Restore the container
        restore_cmd = [
            docker, "container", "restore",
            "--publish", "$(host_port):$(container_port)",
            "--name", "restored_$(checkpoint_name)_$(time_ns())",
            checkpoint_name
        ]

        @info "Restoring container with port mapping $host_port:$container_port"
        result = run(Cmd(restore_cmd))

        if result.exitcode != 0
            @error "Container restore failed" exitcode = result.exitcode
            return nothing
        end

        # Get the restored container ID
        container_id = _get_container_id_for_port(host_port)

        # Wait for the restored worker to be ready
        _wait_for_worker_ready(container_id)

        # Connect to the restored worker
        socket = Sockets.connect(host_port)
        _buffer_writes(socket)

        # Create new PodmanWorker instance
        # Note: We can't get the original process since it's a restored container
        restored_worker = new(
            container_id,
            host_port,
            container_port,
            Base.Process(Base.Cmd(`true`), Base.ProcessRunning),  # Dummy process
            socket,
            MsgID(0),
            Dict{MsgID,Channel{WorkerResult}}()
        )

        # Set up finalizer and cleanup
        w = finalizer(w -> @async(stop(w)), restored_worker)
        atexit(() -> stop(w))

        # Start async tasks
        _receive_loop(w)
        _exit_loop(w)

        @info "Successfully restored PodmanWorker from checkpoint '$checkpoint_name'"
        return w

    catch e
        @error "Failed to restore from checkpoint" checkpoint_name exception = e
        return nothing
    end
end

"""
    list_checkpoints(container_id::String="")::Vector{String}

List available checkpoints for a container or all checkpoints if no container specified.

# Arguments
- `container_id`: Optional container ID to filter checkpoints

# Returns
- Vector of checkpoint names
"""
function list_checkpoints(container_id::String="")::Vector{String}
    try
        cmd = if isempty(container_id)
            `$docker checkpoint ls --format="{{.Name}}"`
        else
            `$docker checkpoint ls $container_id --format="{{.Name}}"`
        end

        result = read(cmd, String)
        checkpoints = filter(!isempty, split(strip(result), '\n'))
        return checkpoints

    catch e
        @warn "Failed to list checkpoints" exception = e
        return String[]
    end
end

"""
    remove_checkpoint(checkpoint_name::String, container_id::String="")::Bool

Remove a checkpoint.

# Arguments
- `checkpoint_name`: Name of checkpoint to remove
- `container_id`: Optional container ID

# Returns
- `true` if successful, `false` otherwise
"""
function remove_checkpoint(checkpoint_name::String, container_id::String="")::Bool
    try
        cmd = if isempty(container_id)
            `$docker checkpoint rm $checkpoint_name`
        else
            `$docker checkpoint rm $container_id $checkpoint_name`
        end

        result = run(cmd)
        return result.exitcode == 0

    catch e
        @error "Failed to remove checkpoint" checkpoint_name exception = e
        return false
    end
end

# Remote call implementations - delegate to existing infrastructure

function remote_call(f, w::PodmanWorker, args...; kwargs...)
    _send_receive_async(
        w,
        MsgType.from_host_call_with_response,
        _new_call_msg(true, f, args, kwargs),
    )
end

function remote_call_fetch(f, w::PodmanWorker, args...; kwargs...)
    _send_receive(
        w,
        MsgType.from_host_call_with_response,
        _new_call_msg(true, f, args, kwargs)
    )
end

function remote_call_wait(f, w::PodmanWorker, args...; kwargs...)
    _send_receive(
        w,
        MsgType.from_host_call_with_response,
        _new_call_msg(false, f, args, kwargs)
    )
end

function remote_do(f, w::PodmanWorker, args...; kwargs...)
    _send_msg(
        w,
        MsgType.from_host_call_without_response,
        _new_do_msg(f, args, kwargs),
        false
    )
    nothing
end

# Helper functions that need to be available

function _send_receive(w::PodmanWorker, msg_type::UInt8, msg_data)
    msg_id = _send_msg(w, msg_type, msg_data, true)
    return _wait_for_response(w, msg_id)
end

function _send_receive_async(w::PodmanWorker, msg_type::UInt8, msg_data, output_transformation=identity)::Task
    msg_id = _send_msg(w, msg_type, msg_data, true)
    return @async output_transformation(_wait_for_response(w, msg_id))
end