using Logging
using Serialization
using Sockets

## Allow catching InterruptExceptions
Base.exit_on_sigint(false)

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
    ## FIXME: This `latest` task isn't a good hack.
    ## It only works if the main server is disciplined about the order of requests.
    ## That happens to be the case for Pluto, but it's not true in general.
    latest = nothing
    while isopen(server)
        try
            # Wait for new request
            sock = accept(server)
            @debug(sock)

            # Handle request asynchronously
            latest = @async begin
                msg = deserialize(sock)
                @debug(msg)
                handle(sock, msg)
            end
        catch InterruptException
            # Rethrow interrupt in the latest task.
            @debug("Caught interrupt!")
            if latest isa Task && !istaskdone(latest)
                Base.throwto(latest, InterruptException)
            end
            continue
        end
    end
    @debug("Closed server socket. bye!")
end

# Poor man's dispatch
function handle(socket, msg)
    if msg.header == :call
        _handle_call(socket, msg.body, msg.send_result)
    elseif msg.header == :remote_do
        _handle_remote_do(socket, msg.body)
    elseif msg.header == :channel
        _handle_channel(socket, msg.body)
    end
end

function _handle_call(socket, body, send_result)
    try
        result = body.f(body.args...; body.kwargs...)
        serialize(socket, (status=:ok, result=(send_result ? result : nothing)))
    catch e
        serialize(socket, (status=:err, result=e))
    finally
        close(socket)
    end
end

function _handle_remote_do(socket, body)
    try
        body.f(body.args...; body.kwargs...)
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

