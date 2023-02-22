"""
The Malt module doesn't export anything, use qualified names instead.
Internal functions are marked with a leading underscore,
these functions are not stable.
"""
module Malt

# using Logging: Logging, @debug
using Serialization: serialize, deserialize
using Sockets: Sockets

using RelocatableFolders: RelocatableFolders


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
    proc::Base.Process

    function Worker(;env=String[], exeflags=[])
        # Spawn process
        cmd = _get_worker_cmd(;env, exeflags)
        proc = open(cmd, "w+")

        # Block until reading the port number of the process (from its stdout)
        port_str = readline(proc)
        port = parse(UInt16, port_str)

        # There's no reason to keep the worker process alive after the manager loses its handle.
        w = finalizer(w -> @async(stop(w)), new(port, proc))
        atexit(() -> stop(w))

        return w
    end
end

const worker_script_path = RelocatableFolders.@path(joinpath(@__DIR__, "worker.jl"))

function _get_worker_cmd(exe=Base.julia_cmd()[1]; env, exeflags)
    return addenv(`$exe --startup-file=no $exeflags $worker_script_path`, Base.byteenv(env))
end

_assert_is_running(w::Worker) = isrunning(w) || throw(TerminatedWorkerException())


## We use named tuples instead of structs for messaging so the worker doesn't need to load additional modules.

_new_call_msg(send_result::Bool, f::Function, args...; kwargs...) = (;
    header = :call,
    f,
    args,
    kwargs,
    send_result,
)

_new_do_msg(f::Function, args...; kwargs...) = (;
    header = :remote_do,
    f,
    args,
    kwargs,
)

_new_channel_msg(expr) = (;
    header = :channel,
    expr,
)

function _send_msg(port::UInt16, msg)
    socket = Sockets.connect(port)
    serialize(socket, msg)
    return socket
end

function _recv(socket)
    try
        if !eof(socket)
            response = deserialize(socket)
            response.result
        end
    catch e
        rethrow(e)
    finally
        close(socket)
    end
end

function _send(w::Worker, msg)
    _assert_is_running(w)
    _recv(_send_msg(w.port, msg))
end

# TODO: Unwrap TaskFailedExceptions
function _send_async(w::Worker, msg)::Task
    _assert_is_running(w)
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
    _assert_is_running(w)
    _send_msg(w.port, _new_do_msg(f, args..., kwargs...))
    nothing
end


"""
    Malt.remotecall_fetch(f, w::Worker, args...; kwargs...)

Shorthand for `fetch(Malt.remotecall(…))`. Blocks and then returns the result of the remote call.
"""
function remotecall_fetch(f, w::Worker, args...; kwargs...)
    _send(w, _new_call_msg(true, f, args..., kwargs...))
end


"""
    Malt.remotecall_wait(f, w::Worker, args...; kwargs...)

Shorthand for `wait(Malt.remotecall(…))`. Blocks and discards the resulting value.
"""
function remotecall_wait(f, w::Worker, args...; kwargs...)
    _send(w, _new_call_msg(false, f, args..., kwargs...))
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
    s = Sockets.connect(w.port)
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
        _assert_is_running(w)
        _send_msg(w.port, (header=:interrupt,))
    else
        Base.kill(w.proc, Base.SIGINT)
    end
end

end # module
