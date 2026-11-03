pushfirst!(LOAD_PATH, "@stdlib")
using Logging: Logging, @debug
using Serialization: serialize, deserialize
using Sockets: Sockets
popfirst!(LOAD_PATH)

## Allow catching InterruptExceptions
Base.exit_on_sigint(false)

# ENV["JULIA_DEBUG"] = @__MODULE__

include("./shared.jl")
include("./worker_loop.jl")

## TODO:
## * Don't use a global Logger. Use one for dev, and one for user code (handled by Pluto)
## * Define a worker specific LogLevel
# Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Debug))

function main()
    # Use the same port hint as Distributed
    port_hint = 9000 + (Sockets.getpid() % 1000)
    port, server = Sockets.listenany(port_hint)

    # Write port number to stdout to let main process know where to send requests
    @debug("WORKER: new port", port)
    println(stdout, port)
    flush(stdout)

    # Set network parameters, this is copied from Distributed
    Sockets.nagle(server, false)
    Sockets.quickack(server, true)

    serve(server)
end

function serve(server::Sockets.TCPServer)

    # Wait for new request
    @debug("WORKER: Waiting for new connection")
    io = Sockets.accept(server)
    @debug("WORKER: New connection", io)

    # Set network parameters, this is copied from Distributed
    Sockets.nagle(io, false)
    Sockets.quickack(io, true)
    _buffer_writes(io)

    serve(io)

    @debug("WORKER: Closed server socket. Bye!")
end

# Check if task is still running before throwing interrupt
interrupt(t::Task) = istaskdone(t) || Base.schedule(t, InterruptException(); error=true)
interrupt(::Nothing) = nothing

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
