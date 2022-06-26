using Sockets
using Serialization
using Logging

include("./messages.jl")

# global_logger(ConsoleLogger(stderr, Logging.Debug))

function handle(sock, msg::EvalRequest)
    serialize(sock, EvalResponse(eval(msg.expr)))
end

function handle(sock, msg::ExitRequest)
    serialize(sock, nothing) # REVIEW: Should there be a last message confirming exit?
    close(sock)
    @debug "Exit message. bye!"
    exit()
end

function work(port)
    sock = connect(port)

    while isopen(sock) && isreadable(sock)
        try
            msg = deserialize(sock)

            # FIXME: This seems redundant
            if typeof(msg) <: AbstractMessage
                handle(sock, msg)
            else
                continue
            end

        catch InterruptException
            @debug "Caught interrupt. bye!"
            exit()
        end
    end

    @debug "Closed socket. bye!"
end

function main()
    port_str = get(ENV, "DALT_PORT", "")
    if port_str === ""
        @debug "No `\$DALT_PORT` specified."
        exit(-1)
    else
        port = parse(UInt16, port_str)
        work(port)
    end
end

main()

