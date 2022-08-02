module Malt

export Worker
export remotecall
export remotecall_eval

import Base.Meta: quot
import Base: Process, Channel, kill
import Serialization: AbstractSerializer, serialize, deserialize

using Logging
using Sockets

mutable struct Worker
    port::UInt16
    proc::Process
end

function Worker()
    # Spawn process
    cmd = _get_worker_cmd()
    proc = open(cmd, "w+") # TODO: Capture stdio

    # Block until reading the port number of the process
    port_str = readline(proc)
    port = parse(UInt16, port_str)
    Worker(port, proc)
end

function _get_worker_cmd(bin="julia")
    script = dirname(@__FILE__) * "/worker.jl"
    # TODO: Project environment
    `$bin $script`
end

# We use tuples instead of structs so the worker doesn't need to load
# additional modules.
call_msg(f, args...; kwargs...) = (header=:call, body=(f=f, args=args, kwargs=kwargs))
channel_msg(ex) = (header=:channel, body=ex)


function _send_msg(w::Worker, msg)
    socket = connect(w.port)
    serialize(socket, msg)
    return socket
end

function _promise(socket)
    @async begin
        response = deserialize(socket)
        close(socket)
        # FIXME:
        # `response.result` can be the result of a computation, or an Exception.
        # If it's an exception defined in Base, we could rethrow it here,
        # but what should be done if it's an exception that's NOT defined in Base???
        #
        # Also, these exceptions are wrapped in a `TaskFailedException`,
        # which seems kind of ugly. How to unwrap them?
        response.result
    end
end

function send(w::Worker, msg)
    _promise(_send_msg(w, msg))
end

"""
    worker_channel(w::Worker, ex)

Create a channel to communicate with worker `w`. `ex` must be an expression
that evaluates to a Channel. `ex` should assign the Channel to a (global) variable
so the worker has a handle that can be used to send messages back to the manager.
"""
function worker_channel(w::Worker, ex)::Channel
    # Send message
    s = connect(w.port)
    serialize(s, channel_msg(ex))

    # Return channel
    Channel(function(channel)
        while isopen(channel) && isopen(s)
            put!(channel, deserialize(s))
        end
        close(s)
        return
    end)
end

function remotecall(f, w::Worker, args...; kwargs...)
    send(w, call_msg(f, args..., kwargs...))
end

function remote_do(f, w::Worker, args...; kwargs...)
    _send_msg(w, call_msg(f, args..., kwargs...))
    return
end

"""
    remotecall_eval([m], w::Worker, ex)

Evaluate expression `ex` under module `m` on the worker `w`.
If no module is specified, `ex` is evaluated under Main.

Unlike `remotecall`, `remotecall_eval` is a blocking call.
"""
remotecall_eval(m, w::Worker, ex) = fetch(remotecall(Core.eval, w, m, ex))
remotecall_eval(w::Worker, ex) = remotecall_eval(Main, w, ex)

Base.Channel(w::Worker, ex::Expr) = worker_channel(w, ex)

Base.kill(w::Worker) =  remote_do(Base.exit, w)

end # module
