using Logging
using Serialization
using Sockets

## Allow catching InterruptExceptions
Base.exit_on_sigint(false)

const msg_type_from_host = (
    from_host_call_with_response = UInt8(1),
    from_host_call_without_response = UInt8(2),
    from_host_channel_open = UInt8(10),
    from_host_interrupt = UInt8(20),
    ####
    from_worker_call_result = UInt8(80),
    from_worker_call_failure = UInt8(81),
    from_worker_channel_value = UInt8(90),
)

# ## TODO:
# ## * Don't use a global Logger. Use one for dev, and one for user code (handled by Pluto)
# ## * Define a worker specific LogLevel
# global_logger(ConsoleLogger(stderr, Logging.Debug))

function main()
    # Use the same port hint as Distributed
    port_hint = 9000 + (getpid() % 1000)
    port, server = listenany(port_hint)

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
            client_connection = accept(server)
            @debug("New connection", client_connection)
            
            # Handle request asynchronously
            latest = @async while true
                # Set network parameters, this is copied from Distributed
                Sockets.nagle(client_connection, false)
                Sockets.quickack(client_connection, true)
                
                if !eof(client_connection)
                    id, msg = deserialize(client_connection)
                    if get(msg, :header, nothing) === :interrupt
                        interrupt(latest)
                    else
                        @debug("WORKER: Received message", msg)
                        handle(Val(msg.header), client_connection, msg, id)
                    end
                end
            end
        catch InterruptException
            @debug("WORKER: Caught interrupt!")
            interrupt(latest)
            continue
        end
    end
    @debug("WORKER: Closed server socket. Bye!")
end

# Check if task is still running before throwing interrupt
interrupt(t::Task) = istaskdone(t) || Base.throwto(t, InterruptException)
interrupt(::Nothing) = nothing



function handle(::Val{:call}, socket, msg, id::UInt16)
    try
        result = msg.f(msg.args...; msg.kwargs...)
        # @debug("WORKER: Evaluated result", result)
        serialize(socket, (status=:ok, result=(msg.send_result ? result : nothing)))
    catch e
        # @debug("WORKER: Got exception!", e)
        serialize(socket, (status=:err, result=e))
    end
end

function handle(::Val{:remote_do}, socket, msg, id::UInt16)
    msg.f(msg.args...; msg.kwargs...)
end

# function handle(::Val{:channel}, socket, msg, id::UInt16)
#     channel = eval(msg.expr)
#     while isopen(channel) && isopen(socket)
#         serialize(socket, take!(channel))
#     end
#     isopen(socket) && close(socket)
#     isopen(channel) && close(channel)
#     return
# end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

