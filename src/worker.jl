using Sockets

function work(port)
    @show sock = connect(port)

    while isopen(sock) && isreadable(sock)
        try
            # Read message
            msg = readline(sock)

            if strip(msg) == "exit"
                close(sock)
                exit()
            end

            # send back modified message
            println(sock, uppercase(msg))
            flush(sock)

        catch InterruptException
            println(stderr, "bye!")
            exit()
        end
    end
end

function main()
    port_str = get(ENV, "DALT_PORT", nothing)
    if port_str === nothing
        # println(stderr, "No `\$DALT_PORT` specified.")
        exit(-1)
    else
        port = parse(UInt16, port_str)
        work(port)
    end
end

main()

