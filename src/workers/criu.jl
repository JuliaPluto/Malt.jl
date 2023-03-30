
"""
    Malt.CriuWorker()

Create a new `CriuWorker`. A `CriuWorker` struct is a handle to a (separate) Julia process
that knows to save memory when it stops working

"""
mutable struct CriuWorker <: AbstractWorker
    worker::Worker
    dir::AbstractString
    frozen::Bool
    function CriuWorker(; env=String[], exeflags=[], dir=mktempdir())
        # Spawn process
        w = Worker(; env, exeflags)
        @info "Limitation: CRIU needs to run as root ☹️"
        return new(w, dir, false)
    end
end

function getpid(w::CriuWorker)
    getpid(w.worker)
end

function workerdump(w::CriuWorker)
    w.frozen && return
    dir = w.dir
    pid = getpid(w)
    run(`criu dump -s --shell-job --tcp-established -t $pid -D $dir`)
    w.frozen = true
end

function workerrestore(w::CriuWorker)
    !w.frozen && return
    dir = w.dir
    run(`criu restore -D $dir`)
    w.frozen = false
end

function _receive_loop(w::CriuWorker)

    # Here we use:
    # `for _i in Iterators.countfrom(1)`
    # instead of
    # `while true`
    # as a workaround for https://github.com/JuliaLang/julia/issues/37154
    @async for _i in Iterators.countfrom(1)
        try
            workerrestore(w)
            io = w.worker.current_socket
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

            c = get(w.worker.expected_replies, msg_id, nothing)
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
                if isrunning(w.worker)
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

"""
Low-level: send a message to a worker. Returns a `msg_id::UInt16`, which can be used to wait for a response with `_wait_for_response`.
"""
function _send_msg(worker::CriuWorker, msg_type::UInt8, msg_data, expect_reply::Bool=true)::MsgID
    workerrestore(worker)
    _assert_is_running(worker)
    # _ensure_connected(worker)

    msg_id = (worker.worker.current_message_id += MsgID(1))::MsgID
    if expect_reply
        worker.worker.expected_replies[msg_id] = Channel{WorkerResult}(1)
    end

    @debug("HOST: sending message", msg_data)

    _serialize_msg(worker.worker.current_socket, msg_type, msg_id, msg_data)

    return msg_id
end

"""
Low-level: wait for a response to a previously sent message. Returns the response. Blocking call.
"""
function _wait_for_response(worker::CriuWorker, msg_id::MsgID)
    workerrestore(worker)
    if haskey(worker.worker.expected_replies, msg_id)
        c = worker.worker.expected_replies[msg_id]
        @debug("HOST: waiting for response of", msg_id)
        response = take!(c)
        delete!(worker.worker.expected_replies, msg_id)
        return unwrap_worker_result(response)
    else
        error("HOST: No response expected for message id $msg_id")
    end
end

"""
`_wait_for_response ∘ _send_msg`
"""
function _send_receive(w::CriuWorker, msg_type::UInt8, msg_data)
    workerrestore(w)
    msg_id = _send_msg(w.worker, msg_type, msg_data, true)
    return _wait_for_response(w.worker, msg_id)
end

"""
`@async(_wait_for_response) ∘ _send_msg`
"""
function _send_receive_async(w::CriuWorker, msg_type::UInt8, msg_data, output_transformation=identity)::Task
    # TODO: Unwrap TaskFailedExceptions
    workerrestore(w)
    msg_id = _send_msg(w.worker, msg_type, msg_data, true)
    return @async output_transformation(_wait_for_response(w.worker, msg_id))
end

function remotecall(f, w::CriuWorker, args...; kwargs...)
    workerrestore(w)
    _send_receive_async(
        w.worker,
        MsgType.from_host_call_with_response,
        _new_call_msg(true, f, args, kwargs),
    )
end

function remotecall_fetch(f, w::CriuWorker, args...; kwargs...)
    workerrestore(w)
    _send_receive(
        w.worker,
        MsgType.from_host_call_with_response,
        _new_call_msg(true, f, args, kwargs)
    )
end

function remotecall_wait(f, w::CriuWorker, args...; kwargs...)
    workerrestore(w)
    _send_receive(
        w.worker,
        MsgType.from_host_call_with_response,
        _new_call_msg(false, f, args, kwargs)
    )
    workerdump(w)
end


function remote_do(f, w::CriuWorker, args...; kwargs...)
    workerrestore(w)
    _send_msg(
        w.worker,
        MsgType.from_host_call_without_response,
        _new_do_msg(f, args, kwargs),
        false
    )
    nothing
end

function worker_channel(w::CriuWorker, expr)
    RemoteChannel(w.worker, expr)
end

isrunning(w::CriuWorker)::Bool = !w.frozen && Base.process_running(w.worker.proc)

_assert_is_running(w::CriuWorker) = isrunning(w) || throw(TerminatedWorkerException())

function stop(w::CriuWorker)
    workerrestore(w)
    if isrunning(w)
        remote_do(Base.exit, w)
        true
    else
        false
    end
end

function kill(w::CriuWorker)
    workerrestore(w)
    Base.kill(w.worker.proc)
end

function _wait_for_exit(w::CriuWorker; timeout_s::Real=20)
    workerrestore(w)
    _wait_for_exit(w; timeout_s=timeout_s)
end

function interrupt(w::CriuWorker)
    if Sys.iswindows()
        # TODO: not yet implemented
        @warn "Malt.interrupt is not yet supported on Windows"
        # _assert_is_running(w)
        # _send_msg(w, MsgType.from_host_fake_interrupt, (), false)
        nothing
    else
        Base.kill(w.worker.proc, Base.SIGINT)
        workerdump(w)
    end
end

function restart(w::CriuWorker)
    workerrestore(w)
end