using Logging
using Serialization
using Sockets

# # TODO: Don't use a global Logger. Use one for dev, and one for user code (handled by Pluto).
# global_logger(ConsoleLogger(stderr, Logging.Debug))

function main()
    # NOTE: Same port hint as Distributed
    port_hint = 9000 + (getpid() % 1000)
    port, server = listenany(port_hint)

    # Write port number to stdout to let main process know where to send requests.
    @debug(port)
    println(stdout, port)

    serve(server)
end

function serve(server::Sockets.TCPServer)
    try
        while isopen(server)
            # Wait for new request
            sock = accept(server)
            @debug(sock)

            # Handle request asynchronously
            @async begin
                msg = deserialize(sock)
                @debug(msg)
                handle(sock, Msg{msg.header}, msg.body)
            end
        end
    catch InterruptException
        @debug("Caught interrupt. bye!")
        exit()
    end
    @debug("Closed socket. bye!")
end

struct Msg{S} end

function handle(socket, ::Type{Msg{:eval}}, expr)
    serialize(socket, eval(expr))
    close(socket)
end

function handle(socket, ::Type{Msg{:channel}}, expr)
    channel = eval(expr)
    while isopen(channel)
        serialize(socket, take!(channel))
    end
end

function handle(socket, ::Type{Msg{:exit}}, _)
    serialize(socket, nothing)
    close(socket)
    @debug("Exit message. bye!")
    exit()
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

