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

include("./shared.jl")

# ENV["JULIA_DEBUG"] = @__MODULE__

include("./workers/abstract.jl")
include("./workers/remotechannel.jl")

include("./workers/inprocess.jl")
include("./workers/default.jl")
include("./workers/criu.jl")

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
        @debug "HOST: Don't know what to do with this interrupt, rethrowing" exception = (e, catch_backtrace())
        rethrow(e)
    end
end

end # module
