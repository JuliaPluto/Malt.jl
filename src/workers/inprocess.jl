


"""
    Malt.InProcessWorker(mod::Module=Main)

This implements the same functions as `Malt.Worker` but runs in the same
process as the caller.
"""
mutable struct InProcessWorker <: AbstractWorker
    host_module::Module
    latest_request_task::Task
    running::Bool

    function InProcessWorker(mod=Main)
        task = schedule(Task(() -> nothing))
        new(mod, task, true)
    end
end


function remotecall(f, w::InProcessWorker, args...; kwargs...)
    w.latest_request_task = @async try
        f(args...; kwargs...)
    catch ex
        ex
    end
end


function remote_do(f, ::InProcessWorker, args...; kwargs...)
    @async f(args...; kwargs...)
    nothing
end

function worker_channel(w::InProcessWorker, expr)
    Core.eval(w.host_module, expr)
end

isrunning(w::InProcessWorker) = w.running

function stop(w::InProcessWorker)
    w.running = false
    true
end

function interrupt(w::InProcessWorker)
    schedule(w.latest_request_task, InterruptException(); error=true)
end
