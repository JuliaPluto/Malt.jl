import Sockets: TCPServer, localhost

using Sockets
using Serialization
using Logging

include("./messages.jl")

# # TODO: Logger for user code.
# global_logger(ConsoleLogger(stderr, Logging.Debug))

module Stub end

function main()
    # NOTE: Same port hint as Distributed
    port_hint = 9000 + (getpid() % 1000)
    port, server = listenany(port_hint)

    # Write port number to stdout so manager knows where to send requests.
    @debug port
    println(stdout, port)

    handle(server)
end

"Handle requests sent to server"
function handle(server::TCPServer)
    try
        while isopen(server)
            # Wait for new request
            sock = accept(server)

            # Handle request asynchronously
            @async begin
                msg = deserialize(sock)
                work(sock, msg)
            end
        end
    catch InterruptException
        @debug("Caught interrupt. bye!")
        exit()
    end
    @debug("Closed socket. bye!")
end

function work(sock, msg::EvalRequest)
    # @debug msg
    serialize(sock, EvalResponse(@eval(Stub, $(msg.ex))))
    close(sock)
end

function work(sock, msg::ExitRequest)
    serialize(sock, nothing)
    close(sock)
    @debug("Exit message. bye!")
    exit()
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

