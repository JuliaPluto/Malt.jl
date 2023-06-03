
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

"Worker type"
abstract type AbstractWorker end

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
function remotecall end


"""
    Malt.remotecall_fetch(f, w::Worker, args...; kwargs...)

Shorthand for `fetch(Malt.remotecall(…))`. Blocks and then returns the result of the remote call.
"""
function remotecall_fetch(f, w::AbstractWorker, args...; kwargs...)
    fetch(remotecall(f, w, args...; kwargs...))
end

"""
    Malt.remotecall_wait(f, w::Worker, args...; kwargs...)

Shorthand for `wait(Malt.remotecall(…))`. Blocks and discards the resulting value.
"""
function remotecall_wait(f, w::AbstractWorker, args...; kwargs...)
    wait(remotecall(f, w, args...; kwargs...))
end


"""
    Malt.remote_do(f, w::Worker, args...; kwargs...)

Evaluate `f(args...; kwargs...)` in worker `w` asynchronously.
Unlike `remotecall`, it discards the result of the computation,
meaning there's no way to check if the computation was completed.
"""
function remote_do end

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
remote_eval(m::Module, w::AbstractWorker, expr) = remotecall(Core.eval, w, m, expr)

"""
Shorthand for `fetch(Malt.remote_eval(…))`. Blocks and returns the resulting value.
"""
remote_eval_fetch(m::Module, w::AbstractWorker, expr) = remotecall_fetch(Core.eval, w, m, expr)

"""
Shorthand for `wait(Malt.remote_eval(…))`. Blocks and discards the resulting value.
"""
remote_eval_wait(m::Module, w::AbstractWorker, expr) = remotecall_wait(Core.eval, w, m, expr)

"""
    Malt.worker_channel(w::AbstractWorker, expr)

Create a channel to communicate with worker `w`. `expr` must be an expression
that evaluates to a Channel. `expr` should assign the Channel to a (global) variable
so the worker has a handle that can be used to send messages back to the manager.
"""
function worker_channel end


"""
    Malt.isrunning(w::Worker)::Bool

Check whether the worker process `w` is running.
"""
function isrunning end

"""
    Malt.stop(w::Worker)::Bool

Try to terminate the worker process `w` using `Base.exit`.

If `w` is still alive, and a termination message is sent, `stop` returns true.
If `w` is already dead, `stop` returns `false`.
"""
function stop(w::AbstractWorker) end

"""
    Malt.kill(w::Worker)

Terminate the worker process `w` forcefully by sending a `SIGTERM` signal.

This is not the recommended way to terminate the process. See `Malt.stop`.
""" # https://youtu.be/dyIilW_eBjc
function kill(w::AbstractWorker) end

function _wait_for_exit(::AbstractWorker; timeout_s::Real=20) end

"""
    Malt.interrupt(w::Worker)

Send an interrupt signal to the worker process. This will interrupt the
latest request (`remotecall*` or `remote_eval*`) that was sent to the worker.
"""
function interrupt(w::AbstractWorker) end