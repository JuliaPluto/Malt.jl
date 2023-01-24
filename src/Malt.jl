"""
The Malt module doesn't export anything, use qualified names instead.
Internal functions are marked with a leading underscore,
these functions are not stable.
"""
module Malt

import Base: Process, Channel
import Serialization: serialize, deserialize

# using Logging
using Sockets

import RelocatableFolders


include("./MsgType.jl")



# ENV["JULIA_DEBUG"] = @__MODULE__




"""
Malt will raise a `TerminatedWorkerException` when a `remotecall` is made to a `Worker`
that has already been terminated.
"""
struct TerminatedWorkerException <: Exception end





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
    proc::Process
    
    current_socket::TCPSocket
    # socket_lock::ReentrantLock
    
    current_message_id::MsgID
    expected_replies::Dict{MsgID,Channel}
    
    function Worker(;exeflags=[])
        # Spawn process
        cmd = _get_worker_cmd(;exeflags)
        proc = open(cmd, "w+")

        # Block until reading the port number of the process (from its stdout)
        port_str = readline(proc)
        port = parse(UInt16, port_str)
        
        # Connect
        socket = connect(port)
        @debug "HOST: Starting receive loop" worker
        

        # There's no reason to keep the worker process alive after the manager loses its handle.
        w = finalizer(w -> @async(stop(w)), 
            new(port, proc, socket, MsgID(0), Dict{MsgID,Channel}())
        )
        atexit(() -> stop(w))
        
        
        receive_task = @async try
            _receive_loop(w)
        catch e
            @error "huhhh" exception=(e, catch_backtrace())
        end

        return w
    end
end





# TODO
function _receive_loop(worker::Worker)
    @debug "HOST: Starting receive loop" worker
    
    while isopen(worker.current_socket) && !eof(worker.current_socket)
        local msg_type, msg_id, msg_data
        
        success = try
            @debug "HOST: Waiting for message"
            
            msg_type = read(worker.current_socket, UInt8)
            msg_id = read(worker.current_socket, MsgID)
            @debug "HOST: 1" msg_type msg_id
            
            
            msg_data = deserialize(worker.current_socket)
            @debug "HOST: 2" msg_data
            
            
            # TODO: msg boundary
            # _discard_msg_boundary = deserialize(worker.current_socket)
            
            true
        catch e
            @error "HOST: Error deserializing data" exception=(e, catch_backtrace())
            
            
            # TODO: read until msg boundary
            # _discard_msg_boundary = deserialize(worker.current_socket)
            
            false
        end
        
        if !success
            if @isdefined(msg_id)
                msg_data = ErrorException("failed to deserialize data from worker")
                
                msg_type = MsgType.from_worker_call_failure
                
                # TODO: what about channels?
            else
                @error "HOST: Error deserializing data"
                continue
            end
        end
        
        if msg_type === MsgType.from_worker_call_result || msg_type === MsgType.from_worker_call_failure
            c = get(worker.expected_replies, msg_id, nothing)
            if c isa Channel{Any}
                put!(c, msg_data)
            else
                @error "Received unexpected response" msg_type msg_id msg_data
            end
        else
            @error "TODO NOT YET IMPLEMENTED"
        end
        
        @debug("HOST: Received message", msg_data) 
    end
    @debug("HOST: receive loop ended", worker)
end



# The entire `src` dir should be relocatable, so that worker.jl can include("MsgType.jl").
const src_path = RelocatableFolders.@path @__DIR__

function _get_worker_cmd(exe=Base.julia_cmd(); exeflags=[])
    `$exe $exeflags $(joinpath(src_path, "worker.jl"))`
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

_new_channel_msg(expr) = (
    expr,
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
        worker.expected_replies[msg_id] = Channel{Any}(0)
    end
    
    write(worker.current_socket, msg_type)
    write(worker.current_socket, msg_id)
    serialize(worker.current_socket, msg_data)
    # TODO: send msg boundary
    # serialize(worker.current_socket, MSG_BOUNDARY)

    return msg_id
end

"""
Low-level: wait for a response to a previously sent message. Returns the response. Blocking call.
"""
function _wait_for_response(worker::Worker, msg_id::MsgID)
    c = get(worker.expected_replies, msg_id, nothing)
    if c isa Channel{Any}
        response = take!(c)
        delete!(worker.expected_replies, msg_id)
        return response
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
function worker_channel(w::Worker, expr)::Channel
    # Send message
    s = connect(w.port)
    serialize(s, _new_channel_msg(expr))

    # Return channel
    Channel(function(channel)
        while isopen(channel) && isopen(s) && !eof(s)
            put!(channel, deserialize(s))
        end
        close(s)
        return
    end)
end


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
        sleep(.01)
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

end # module
