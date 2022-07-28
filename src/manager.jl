import Base: Process
import Sockets: TCPServer, localhost
import Base: Channel
import Base.Meta: quot

using Serialization
using Sockets

mutable struct Worker
    port::UInt16
    proc::Process
end

function Worker()
    # Create remote process
    cmd = _get_worker_cmd()
    proc = open(cmd, "w+") # TODO: Capture stdio

    # Block until having the port of the remote process
    port_str = readline(proc)
    port = parse(UInt16, port_str)
    Worker(port, proc)
end

function _get_worker_cmd(bin="julia")
    script = dirname(@__FILE__) * "/worker.jl"
    # TODO: Project environment
    `$bin $script`
end

function send(w::Worker, msg::AbstractMessage)
    # Send message
    s = connect(w.port)
    serialize(s, msg)

    # Return a task to act as Promise
    @async begin
        response = deserialize(s)
        close(s)
        response
    end
end

"Create a channel to communicate with worker. See `ChannelRequest`"
function send(w::Worker, msg::ChannelRequest)
    # Send message
    s = connect(w.port)
    serialize(s, msg)

    # Return channel
    Channel(function(channel)
        while isopen(channel)
            put!(channel, deserialize(s))
        end
        close(s)
        return
    end)
end


## Shorthands

stop(w::Worker) = send(w, ExitRequest())

Base.Channel(w::Worker, ex::Expr) = send(w, ChannelRequest(ex))

remote_eval(w::Worker, ex::Expr) = send(w, EvalRequest(ex))
remote_eval(w::Worker, sym::Symbol) = send(w, EvalRequest(Expr(sym)))

macro remote_eval(w, ex)
    Expr(
        :call,
        remote_eval,
        esc(w),     # Evaluate w
        quot(ex),   # Don't evaluate ex
    )
end

