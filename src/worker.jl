import Sockets: TCPServer, localhost

using Sockets
using Serialization
using Logging
using Malt

# # TODO: Don't use a global Logger. Use one for dev, and one for user code (handled by Pluto).
# global_logger(ConsoleLogger(stderr, Logging.Debug))

module Stub end

function main()
    # NOTE: Same port hint as Distributed
    port_hint = 9000 + (getpid() % 1000)
    port, server = listenany(port_hint)

    # Write port number to stdout so manager knows where to send requests.
    @debug(port)
    println(stdout, port)

    serve(server)
end

function serve(server::TCPServer)
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
    catch e
        println(e)
        @debug("Caught interrupt. bye!")
        exit()
    end
    @debug("Closed socket. bye!")
end

# TODO:
# Right now all EvalRequests are sandboxed in the stub module.
# However, it might make sense to distinguish between sandboxed and unsandboxed
# expressions (e.g. those used to initialize the PlutoRunner).
function handle(sock, msg::EvalRequest)
    serialize(sock, EvalResponse(@eval(Stub, $(msg.ex))))
    close(sock)
end

function handle(sock, msg::ExitRequest)
    serialize(sock, nothing)
    close(sock)
    @debug("Exit message. bye!")
    exit()
end

function handle(sock, msg::ChannelRequest)
    c = @eval(Stub, $(msg.ex))

    while isopen(c)
        serialize(sock, take!(c))
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

