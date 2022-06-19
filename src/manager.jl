import Base: Process
import Sockets: TCPServer, localhost

using Sockets

struct Manager
    server::TCPServer
    port::UInt16
end

# TODO: Does Worker actually need an explicit finalizer?
mutable struct Worker
    proc::Process
    sock::TCPSocket
end

function Manager()
    server = TCPServer()
    bind(server, localhost, 0)
    listen(server)
    _ip, port = getsockname(server)
    Manager(server, port)
end

function Worker(man::Manager)
    cmd = worker_cmd(man.port)
    t = @async accept(man.server)
    proc = open(cmd) # Create worker process
    sock = fetch(t)  # wait until process is connected
    Worker(proc, sock)
end

function worker_cmd(port)
    jl_bin = `julia`    # REVIEW: Can we always assume that julia is in $PATH?

    script = dirname(@__FILE__) * "/worker.jl"

    addenv(`julia $script`, Dict("DALT_PORT" => string(port)))
end

# TODO: Message (serialization)

