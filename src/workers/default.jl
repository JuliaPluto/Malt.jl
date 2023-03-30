
"""
    Malt.Worker()

Create a new `Worker`. A `Worker` struct is a handle to a (separate) Julia process.

# Examples

```julia-repl
julia> w = Malt.worker()
Malt.Worker(0x0000, Process(`…`, ProcessRunning))
```
"""
mutable struct Worker <: AbstractWorker
    port::UInt16
    proc::Base.Process

    current_socket::Sockets.TCPSocket
    # socket_lock::ReentrantLock

    current_message_id::MsgID
    expected_replies::Dict{MsgID,Channel{WorkerResult}}

    function Worker(; env=String[], exeflags=[])
        # Spawn process
        cmd = _get_worker_cmd(; env, exeflags)
        proc = open(cmd, "w+")

        # Block until reading the port number of the process (from its stdout)
        port_str = readline(proc)
        port = parse(UInt16, port_str)

        # Connect
        socket = Sockets.connect(port)
        _buffer_writes(socket)


        # There's no reason to keep the worker process alive after the manager loses its handle.
        w = finalizer(w -> @async(stop(w)),
            new(port, proc, socket, MsgID(0), Dict{MsgID,Channel{WorkerResult}}())
        )
        atexit(() -> stop(w))

        _receive_loop(w)

        return w
    end
end

function _receive_loop(worker::Worker)
    io = worker.current_socket
    # Here we use:
    # `for _i in Iterators.countfrom(1)`
    # instead of
    # `while true`
    # as a workaround for https://github.com/JuliaLang/julia/issues/37154
    @async for _i in Iterators.countfrom(1)
        try
            if !isopen(io)
                @debug("HOST: io closed.")
                break
            end

            @debug "HOST: Waiting for message"
            msg_type = try
                if eof(io)
                    @debug("HOST: io closed.")
                    break
                end
                read(io, UInt8)
            catch e
                if e isa InterruptException
                    @debug("HOST: Caught interrupt while waiting for incoming data, rethrowing to REPL...")
                    _rethrow_to_repl(e; rethrow_regular=false)
                    continue # and go back to waiting for incoming data
                else
                    @debug("HOST: Caught exception while waiting for incoming data, breaking", exception = (e, backtrace()))
                    break
                end
            end
            # this next line can't fail
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

            # msg_type will be one of:
            #  MsgType.from_worker_call_result
            #  MsgType.from_worker_call_failure
            #  MsgType.special_serialization_failure

            c = get(worker.expected_replies, msg_id, nothing)
            if c isa Channel{WorkerResult}
                put!(c, WorkerResult(
                    msg_type == MsgType.special_serialization_failure,
                    msg_data
                ))
            else
                @error "HOST: Received a response, but I didn't ask for anything" msg_type msg_id msg_data
            end

            @debug("HOST: Received message", msg_data)
        catch e
            if e isa InterruptException
                @debug "HOST: Interrupted during receive loop."
                _rethrow_to_repl(e)
            elseif e isa Base.IOError && !isopen(io)
                sleep(3)
                if isrunning(worker)
                    @error "HOST: Connection lost with worker, but the process is still running. Killing process..." exception = (e, catch_backtrace())
                    kill(worker)
                else
                    # This is a clean exit
                end
                break
            else
                @error "HOST: Unknown error" exception = (e, catch_backtrace()) isopen(io)

                break
            end
        end
    end
end

# function _ensure_connected(w::Worker)
#     # TODO: check if process running?
#     # TODO: `while` instead of `if`?
#     if w.current_socket === nothing || !isopen(w.current_socket)
#         w.current_socket = connect(w.port)
#         @async _receive_loop(w)
#     end
#     return w
# end


# GENERIC COMMUNICATION PROTOCOL

"""
Low-level: send a message to a worker. Returns a `msg_id::UInt16`, which can be used to wait for a response with `_wait_for_response`.
"""
function _send_msg(worker::Worker, msg_type::UInt8, msg_data, expect_reply::Bool=true)::MsgID
    _assert_is_running(worker)
    # _ensure_connected(worker)

    msg_id = (worker.current_message_id += MsgID(1))::MsgID
    if expect_reply
        worker.expected_replies[msg_id] = Channel{WorkerResult}(1)
    end

    @debug("HOST: sending message", msg_data)

    _serialize_msg(worker.current_socket, msg_type, msg_id, msg_data)

    return msg_id
end

"""
Low-level: wait for a response to a previously sent message. Returns the response. Blocking call.
"""
function _wait_for_response(worker::Worker, msg_id::MsgID)
    if haskey(worker.expected_replies, msg_id)
        c = worker.expected_replies[msg_id]
        @debug("HOST: waiting for response of", msg_id)
        response = take!(c)
        delete!(worker.expected_replies, msg_id)
        return unwrap_worker_result(response)
    else
        error("HOST: No response expected for message id $msg_id")
    end
end

"""
`_wait_for_response ∘ _send_msg`
"""
function _send_receive(w::Worker, msg_type::UInt8, msg_data)
    msg_id = _send_msg(w, msg_type, msg_data, true)
    return _wait_for_response(w, msg_id)
end

"""
`@async(_wait_for_response) ∘ _send_msg`
"""
function _send_receive_async(w::Worker, msg_type::UInt8, msg_data, output_transformation=identity)::Task
    # TODO: Unwrap TaskFailedExceptions
    msg_id = _send_msg(w, msg_type, msg_data, true)
    return @async output_transformation(_wait_for_response(w, msg_id))
end

function remotecall(f, w::Worker, args...; kwargs...)
    _send_receive_async(
        w,
        MsgType.from_host_call_with_response,
        _new_call_msg(true, f, args, kwargs),
    )
end

function remotecall_fetch(f, w::Worker, args...; kwargs...)
    _send_receive(
        w,
        MsgType.from_host_call_with_response,
        _new_call_msg(true, f, args, kwargs)
    )
end

function remotecall_wait(f, w::Worker, args...; kwargs...)
    _send_receive(
        w,
        MsgType.from_host_call_with_response,
        _new_call_msg(false, f, args, kwargs)
    )
end


function remote_do(f, w::Worker, args...; kwargs...)
    _send_msg(
        w,
        MsgType.from_host_call_without_response,
        _new_do_msg(f, args, kwargs),
        false
    )
    nothing
end

function worker_channel(w::Worker, expr)
    RemoteChannel(w, expr)
end

isrunning(w::Worker)::Bool = Base.process_running(w.proc)

_assert_is_running(w::Worker) = isrunning(w) || throw(TerminatedWorkerException())

function stop(w::Worker)
    if isrunning(w)
        remote_do(Base.exit, w)
        true
    else
        false
    end
end

kill(w::Worker) = Base.kill(w.proc)

function _wait_for_exit(w::Worker; timeout_s::Real=20)
    t0 = time()
    while isrunning(w)
        sleep(0.01)
        if time() - t0 > timeout_s
            error("HOST: Worker did not exit after $timeout_s seconds")
        end
    end
end

function interrupt(w::Worker)
    if Sys.iswindows()
        # TODO: not yet implemented
        @warn "Malt.interrupt is not yet supported on Windows"
        # _assert_is_running(w)
        # _send_msg(w, MsgType.from_host_fake_interrupt, (), false)
        nothing
    else
        Base.kill(w.proc, Base.SIGINT)
    end
end
