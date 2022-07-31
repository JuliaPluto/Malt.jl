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
                handle(sock, msg)
            end
        end
    catch InterruptException
        @debug("Caught interrupt. bye!")
        exit()
    end
    @debug("Closed socket. bye!")
end

# Poor man's dispatch
function handle(socket, msg)
    if msg.header == :call
        _handle_call(socket, msg.body)
    elseif msg.header == :channel
        _handle_channel(socket, msg.body)
    end
end

function _handle_call(socket, body)
    try
        result = body.f(body.args...; body.kwargs...)
        serialize(socket, (status=:ok, result=result))
    catch e
        serialize(socket, (status=:err, result=e))
    finally
        close(socket)
    end
end

function _handle_channel(socket, ex)
    channel = eval(ex)
    while isopen(channel)
        serialize(socket, take!(channel))
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

