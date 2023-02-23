"""
The Malt module doesn't export anything, use qualified names instead.
Internal functions are marked with a leading underscore,
these functions are not stable.
"""
module Malt

# using Logging: Logging, @debug
using Serialization: serialize, deserialize, Serializer
using Sockets: Sockets

using RelocatableFolders: RelocatableFolders

include("./shared.jl")

# ENV["JULIA_DEBUG"] = @__MODULE__




"""
Malt will raise a `TerminatedWorkerException` when a `remotecall` is made to a `Worker`
that has already been terminated.
"""
struct TerminatedWorkerException <: Exception end


struct WorkerResult
    should_throw::Bool
    value::Any
end

unwrap_worker_result(result::WorkerResult) = result.should_throw ? throw(result.value) : result.value


"""
    Malt.Worker()

Create a new `Worker`. A `Worker` struct is a handle to a (separate) Julia process.

# Examples

```julia-repl
julia> w = Malt.worker()
Malt.Worker(0x0000, Process(`…`, ProcessRunning))
```
"""
mutable struct Worker
    port::UInt16
    proc::Base.Process

    current_socket::Sockets.TCPSocket
    serializer::Serializer
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
            new(port, proc, socket, Serializer(socket), MsgID(0), Dict{MsgID,Channel{WorkerResult}}())
        )
        atexit(() -> stop(w))

        _receive_loop(w)

        return w
    end
end



function _receive_loop(worker::Worker)
    io = worker.current_socket
    serializer = worker.serializer
    @async while true
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
                deserialize(serializer), true
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
                    @error "Connection lost with worker, but the process is still running. Killing proces..." exception = (e, catch_backtrace())
                    
                    kill(worker)
                else
                    # This is a clean exit
                end
                break
            else
                @error "Unknown error" exception = (e, catch_backtrace()) isopen(io)

                break
            end
        end
    end
end



# The entire `src` dir should be relocatable, so that worker.jl can include("MsgType.jl").
const src_path = RelocatableFolders.@path @__DIR__

function _get_worker_cmd(exe=Base.julia_cmd()[1]; env, exeflags)
    return addenv(`$exe --startup-file=no $exeflags $(joinpath(src_path, "worker.jl"))`, Base.byteenv(env))
end





## We use tuples instead of structs for messaging so the worker doesn't need to load additional modules.

_new_call_msg(send_result::Bool, f::Function, args, kwargs) = (
    f,
    args,
    kwargs,
    !send_result,
)

_new_do_msg(f::Function, args, kwargs) = (
    f,
    args,
    kwargs,
    true,
)




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

    _serialize_msg(worker.serializer, msg_type, msg_id, msg_data)

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
        error("No response expected for message id $msg_id")
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





"""
    Malt.remotecall(f, w::Worker, args...; kwargs...)

Evaluate `f(args...; kwargs...)` in worker `w` asynchronously.
Returns a task that acts as a promise; the result value of the task is the
result of the computation.

The function `f` must already be defined in the namespace of `w`.

# Examples

```julia-repl
julia> promise = Malt.remotecall(uppercase ∘ *, w, "I ", "declare ", "bankruptcy!");

julia> fetch(promise)
"I DECLARE BANKRUPTCY!"
```
"""
function remotecall(f, w::Worker, args...; kwargs...)
    _send_receive_async(
        w,
        MsgType.from_host_call_with_response,
        _new_call_msg(true, f, args, kwargs),
    )
end

"""
    Malt.remotecall_fetch(f, w::Worker, args...; kwargs...)

Shorthand for `fetch(Malt.remotecall(…))`. Blocks and then returns the result of the remote call.
"""
function remotecall_fetch(f, w::Worker, args...; kwargs...)
    _send_receive(
        w,
        MsgType.from_host_call_with_response,
        _new_call_msg(true, f, args, kwargs)
    )
end


"""
    Malt.remotecall_wait(f, w::Worker, args...; kwargs...)

Shorthand for `wait(Malt.remotecall(…))`. Blocks and discards the resulting value.
"""
function remotecall_wait(f, w::Worker, args...; kwargs...)
    _send_receive(
        w,
        MsgType.from_host_call_with_response,
        _new_call_msg(false, f, args, kwargs)
    )
end



"""
    Malt.remote_do(f, w::Worker, args...; kwargs...)

Evaluate `f(args...; kwargs...)` in worker `w` asynchronously.
Unlike `remotecall`, it discards the result of the computation,
meaning there's no way to check if the computation was completed.
"""
function remote_do(f, w::Worker, args...; kwargs...)
    _send_msg(
        w,
        MsgType.from_host_call_without_response,
        _new_do_msg(f, args, kwargs),
        false
    )
    nothing
end



## Eval variants

"""
    Malt.remote_eval(m, w::Worker, expr)

Evaluate expression `expr` under module `m` on the worker `w`.
`Malt.remote_eval` is asynchronous, like `Malt.remotecall`.

The module `m` and the type of the result of `expr` must be defined in both the
main process and the worker.

# Examples

```julia-repl
julia> Malt.remote_eval(w, quote
    x = "x is a global variable"
end)

julia> Malt.remote_eval_fetch(w, :x)
"x is a global variable"
```

"""
remote_eval(m::Module, w::Worker, expr) = remotecall(Core.eval, w, m, expr)


"""
Shorthand for `fetch(Malt.remote_eval(…))`. Blocks and returns the resulting value.
"""
remote_eval_fetch(m::Module, w::Worker, expr) = remotecall_fetch(Core.eval, w, m, expr)


"""
Shorthand for `wait(Malt.remote_eval(…))`. Blocks and discards the resulting value.
"""
remote_eval_wait(m::Module, w::Worker, expr) = remotecall_wait(Core.eval, w, m, expr)


"""
    Malt.worker_channel(w::Worker, expr)

Create a channel to communicate with worker `w`. `expr` must be an expression
that evaluates to a Channel. `expr` should assign the Channel to a (global) variable
so the worker has a handle that can be used to send messages back to the manager.
"""
function worker_channel(w::Worker, expr)
    RemoteChannel(w, expr)
end


struct RemoteChannel{T} <: AbstractChannel{T}
    worker::Worker
    id::UInt64
    
    function RemoteChannel{T}(worker::Worker, expr) where T
        
        id = (worker.current_message_id += MsgID(1))::MsgID
        remote_eval_wait(Main, worker, quote
            Main._channel_cache[$id] = $expr
        end)
        new{T}(worker, id)
    end
    
    RemoteChannel(w::Worker, expr) = RemoteChannel{Any}(w, expr)
end

Base.take!(rc::RemoteChannel) = remote_eval_fetch(Main, rc.worker, :(take!(Main._channel_cache[$(rc.id)])))::eltype(rc)

Base.put!(rc::RemoteChannel, v) = remote_eval_wait(Main, rc.worker, :(put!(Main._channel_cache[$(rc.id)], $v)))

Base.isready(rc::RemoteChannel) = remote_eval_fetch(Main, rc.worker, :(isready(Main._channel_cache[$(rc.id)])))::Bool

Base.wait(rc::RemoteChannel) = remote_eval_wait(Main, rc.worker, :(wait(Main._channel_cache[$(rc.id)])))::Bool


## Signals & Termination

"""
    Malt.isrunning(w::Worker)::Bool

Check whether the worker process `w` is running.
"""
isrunning(w::Worker)::Bool = Base.process_running(w.proc)

_assert_is_running(w::Worker) = isrunning(w) || throw(TerminatedWorkerException())


"""
    Malt.stop(w::Worker)::Bool

Try to terminate the worker process `w` using `Base.exit`.

If `w` is still alive, and a termination message is sent, `stop` returns true.
If `w` is already dead, `stop` returns `false`.
"""
function stop(w::Worker)
    if isrunning(w)
        remote_do(Base.exit, w)
        true
    else
        false
    end
end


"""
    Malt.kill(w::Worker)

Terminate the worker process `w` forcefully by sending a `SIGTERM` signal.

This is not the recommended way to terminate the process. See `Malt.stop`.
""" # https://youtu.be/dyIilW_eBjc
kill(w::Worker) = Base.kill(w.proc)


function _wait_for_exit(w::Worker; timeout_s::Real=20)
    t0 = time()
    while isrunning(w)
        sleep(0.01)
        if time() - t0 > timeout_s
            error("Worker did not exit after $timeout_s seconds")
        end
    end
end


"""
    Malt.interrupt(w::Worker)

Send an interrupt signal to the worker process. This will interrupt the
latest request (`remotecall*` or `remote_eval*`) that was sent to the worker.
"""
function interrupt(w::Worker)
    if Sys.iswindows()
        _assert_is_running(w)
        _send_msg(w, MsgType.from_host_interrupt, (), false)
    else
        Base.kill(w.proc, Base.SIGINT)
    end
end





# Based on `Base.task_done_hook`
function _rethrow_to_repl(e::InterruptException; rethrow_regular::Bool=false)
    if isdefined(Base, :active_repl_backend) &&
        isdefined(Base.active_repl_backend, :backend_task) &&
        isdefined(Base.active_repl_backend, :in_eval) &&
        Base.active_repl_backend.backend_task.state === :runnable &&
        (isdefined(Base, :Workqueue) || isempty(Base.Workqueue)) &&
        Base.active_repl_backend.in_eval
        
        @debug "HOST: Rethrowing interrupt to REPL"
        @async Base.schedule(Base.active_repl_backend.backend_task, e; error=true)
    elseif rethrow_regular
        @debug "HOST: Don't know what to do with this interrupt, rethrowing" exception=(e, catch_backtrace())
        rethrow(e)
    end
end

end # module
