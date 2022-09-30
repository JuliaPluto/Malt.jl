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
    sync_socket::Union{TCPSocket, Nothing}

    function Worker(;exeflags=[])
        # Spawn process
        cmd = _get_worker_cmd(;exeflags)
        proc = open(cmd, "w+")

        # Block until reading the port number of the process (from its stdout)
        port_str = readline(proc)
        port = parse(UInt16, port_str)

        # There's no reason to keep the worker process alive after the manager loses its handle.
        w = finalizer(w -> @async(stop(w)), new(port, proc, nothing))
        atexit(() -> stop(w))

        return w
    end
end

function _get_worker_cmd(exe=joinpath(Sys.BINDIR, Base.julia_exename()); exeflags=[])
    script = joinpath(@__DIR__, "worker.jl")
    `$exe $exeflags $script`
end

## Use tuples instead of structs so the worker doesn't need to load additional modules.

_new_call_msg(send_result::Bool, f::Function, args...; kwargs...) = (
    header = :call,
    f=f,
    args=args,
    kwargs=kwargs,
    send_result = send_result,
)

_new_do_msg(f::Function, args...; kwargs...) = (
    header = :remote_do,
    f=f,
    args=args,
    kwargs=kwargs,
)

_new_channel_msg(expr) = (
    header = :channel,
    expr = expr,
)

function _send_msg(port::UInt16, msg)
    socket = connect(port)
    serialize(socket, msg)
    return socket
end

function _recv(socket)
    try
        response = deserialize(socket)
        response #.result
    catch e
        close(socket)
        rethrow(e)
    end
end

function _send_sync(w::Worker, msg)
    isrunning(w) || throw(TerminatedWorkerException())

    # Create or replace socket if necessary
    if !(isa(w.sync_socket, TCPSocket) && isopen(w.sync_socket))
        w.sync_socket = connect(w.port)
    end

    serialize(w.sync_socket, msg)
    _recv(w.sync_socket)
end

# TODO: Unwrap TaskFailedExceptions
function _send_async(w::Worker, msg)::Task
    isrunning(w) || throw(TerminatedWorkerException())
    @async(_recv(_send_msg(w.port, msg)))
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
    _send_async(w, _new_call_msg(true, f, args..., kwargs...))
end


"""
    Malt.remote_do(f, w::Worker, args...; kwargs...)

Evaluate `f(args...; kwargs...)` in worker `w` asynchronously.
Unlike `remotecall`, it discards the result of the computation,
meaning there's no way to check if the computation was completed.
"""
function remote_do(f, w::Worker, args...; kwargs...)
    # Don't talk to the dead
    isrunning(w) || throw(TerminatedWorkerException())
    _send_msg(w.port, _new_do_msg(f, args..., kwargs...))
    nothing
end


"""
    Malt.remotecall_fetch(f, w::Worker, args...; kwargs...)

Shorthand for `fetch(Malt.remotecall(…))`. Blocks and then returns the result of the remote call.
"""
function remotecall_fetch(f, w::Worker, args...; kwargs...)
    _send_sync(w, _new_call_msg(true, f, args..., kwargs...))
end


"""
    Malt.remotecall_wait(f, w::Worker, args...; kwargs...)

Shorthand for `wait(Malt.remotecall(…))`. Blocks and discards the resulting value.
"""
function remotecall_wait(f, w::Worker, args...; kwargs...)
    _send_sync(w, _new_call_msg(false, f, args..., kwargs...))
end


## Eval variants

"""
    Malt.remote_eval([m], w::Worker, expr)

Evaluate expression `expr` under module `m` on the worker `w`.
If no module is specified, `expr` is evaluated under `Main`.
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
remote_eval(w::Worker, expr) = remote_eval(Main, w, expr)


"""
Shorthand for `fetch(Malt.remote_eval(…))`. Blocks and returns the resulting value.
"""
remote_eval_fetch(m::Module, w::Worker, expr) = remotecall_fetch(Core.eval, w, m, expr)
remote_eval_fetch(w::Worker, expr) = remote_eval_fetch(Main, w, expr)


"""
Shorthand for `wait(Malt.remote_eval(…))`. Blocks and discards the resulting value.
"""
remote_eval_wait(m::Module, w::Worker, expr) = remotecall_wait(Core.eval, w, m, expr)
remote_eval_wait(w::Worker, expr) = remote_eval_wait(Main, w, expr)


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
        while isopen(channel) && isopen(s)
            put!(channel, deserialize(s))
        end
        return
    end)
end


## Signals & Termination

"""
    Malt.isrunning(w::Worker)::Bool

Check whether the worker process `w` is running.
"""
isrunning(w::Worker)::Bool = Base.process_running(w.proc)


"""
    Malt.stop(w::Worker)::Bool

Try to terminate the worker process `w`.
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


"""
    Malt.interrupt(w::Worker)

Send an interrupt signal to the worker process. This will interrupt the
latest request (`remotecall*` or `remote_eval*`) that was sent to the worker.
"""
function interrupt(w::Worker)
    if Sys.iswindows()
        isrunning(w) || throw(TerminatedWorkerException())
        _send_msg(w.port, (header=:interrupt,))
    else
        Base.kill(w.proc, Base.SIGINT)
    end
end

end # module
