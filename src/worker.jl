using Logging: Logging, @debug
using Serialization: serialize, deserialize
using Sockets: Sockets

@enum Header begin
    hcall
    hchannel
    hinterrupt
    hremote_do
end

## Allow catching InterruptExceptions
Base.exit_on_sigint(false)

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
    # FIXME: This `latest` task isn't a good hack.
    # It only works if the main server is disciplined about the order of requests.
    # That happens to be the case for Pluto, but it's not true in general.
    latest = nothing
    while isopen(server)
        try
            # Wait for new request
            client_connection = Sockets.accept(server)
            @debug("New connection", client_connection)

            # Handle request asynchronously
            # TODO: if `begin` was `while true`, then this connection could be reused. (like in Distributed)
            latest = @async begin
                # Set network parameters, this is copied from Distributed
                Sockets.nagle(client_connection, false)
                Sockets.quickack(client_connection, true)

                if !eof(client_connection)
                    msg = deserialize(client_connection)
                    if get(msg, 1, nothing) === hinterrupt
                        interrupt(latest)
                    else
                        @debug("WORKER: Received message", msg)
                        handle(Val(msg[1]), client_connection, msg)
                    end
                end
            end
        catch e
            if e isa InterruptException
                @debug("WORKER: Caught interrupt!")
            else
                @error("WORKER: Caught exception!", exception=(e, backtrace()))
            end
            interrupt(latest)
            continue
        end
    end
    @debug("WORKER: Closed server socket. Bye!")
end

# Check if task is still running before throwing interrupt
interrupt(t::Task) = istaskdone(t) || Base.schedule(t, InterruptException(); error=true)
interrupt(::Nothing) = nothing

function handle(::Val{UInt8(hcall)}, socket, msg)
    try
        result = msg.f(msg.args...; msg.kwargs...)
        # @debug("WORKER: Evaluated result", result)
        serialize(socket, (true, msg.send_result ? result : nothing))
    catch e
        # @debug("WORKER: Got exception!", e)
        serialize(socket, (false, e))
    finally
        close(socket)
    end
end

function handle(::Val{UInt8(hremote_do)}, socket, msg)
    try
        msg.f(msg.args...; msg.kwargs...)
    finally
        close(socket)
    end
end

function handle(::Val{UInt8(hchannel)}, socket, msg)
    channel = eval(msg.expr)
    while isopen(channel) && isopen(socket)
        serialize(socket, take!(channel))
    end
    isopen(socket) && close(socket)
    isopen(channel) && close(channel)
    return
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

