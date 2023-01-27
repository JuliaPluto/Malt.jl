using Logging: Logging, @debug
using Serialization: serialize, deserialize
using Sockets: Sockets

## Allow catching InterruptExceptions
Base.exit_on_sigint(false)

# ENV["JULIA_DEBUG"] = @__MODULE__

include("./shared.jl")

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
            @debug("WORKER: Waiting for new connection")
            client_connection = Sockets.accept(server)
            @debug("WORKER: New connection", client_connection)
            
            # Set network parameters, this is copied from Distributed
            Sockets.nagle(client_connection, false)
            Sockets.quickack(client_connection, true)
            _buffer_writes(client_connection)

            # Handle request asynchronously
            latest = @async while true
                try
                    if !isopen(client_connection)
                        @debug("WORKER: client_connection closed.")
                        break
                    end
                    # this will block while waiting for new data
                    if eof(client_connection)
                        @debug("WORKER: eof on client_connection.")
                        break
                    end
                catch e
                    if e isa InterruptException
                        @debug("WORKER: Caught interrupt while waiting for incoming data, ignoring...")
                        continue # and go back to waiting for incoming data
                    else
                        @error("WORKER: Caught exception while waiting for incoming data, ignoring...", exception = (e, backtrace()))
                        continue # will go back to isopen(client_connection)                        
                    end
                end
                try

                    msg_type = read(client_connection, UInt8)
                    msg_id = read(client_connection, MsgID)
                    msg_data, success = try
                        deserialize(client_connection), true
                    catch err
                        err, false
                    finally
                        _discard_until_boundary(client_connection)
                    end

                    if !success
                        continue
                    end

                    if msg_type === MsgType.from_host_interrupt
                        @debug("WORKER: Received interrupt message")
                        interrupt(latest)
                    else
                        @debug("WORKER: Received message", msg_data)
                        handle(Val(msg_type), client_connection, msg_data, msg_id)
                        @debug("WORKER: handled")

                    end
                catch e
                    if e isa InterruptException
                        @debug("WORKER: Caught interrupt")
                    else
                        @error("WORKER: Caught exception", exception = (e, backtrace()))
                    end
                end
            end
        catch e
            if e isa InterruptException
                @debug("WORKER: Caught interrupt while waiting for connection, ignoring...")
            else
                @error("WORKER: Caught exception while waiting for connection, ignoring...", exception = (e, backtrace()))
            end
        end
    end
    @debug("WORKER: Closed server socket. Bye!")
end

# Check if task is still running before throwing interrupt
interrupt(t::Task) = istaskdone(t) || Base.schedule(t, InterruptException(); error=true)
interrupt(::Nothing) = nothing


function handle(::Val{MsgType.from_host_call_with_response}, socket, msg, msg_id::MsgID)
    f, args, kwargs, respond_with_nothing = msg

    success, result = try
        result = f(args...; kwargs...)

        # @debug("WORKER: Evaluated result", result)
        (true, respond_with_nothing ? nothing : result)
    catch e
        # @debug("WORKER: Got exception!", e)
        (false, e)
    end

    _serialize_msg(
        socket,
        success ? MsgType.from_worker_call_result : MsgType.from_worker_call_failure,
        msg_id,
        result
    )
end


function handle(::Val{MsgType.from_host_call_without_response}, socket, msg, msg_id::MsgID)
    f, args, kwargs, _ignored = msg

    try
        f(args...; kwargs...)
    catch e
        @warn("WORKER: Got exception!", e)
        @debug("WORKER: Got exception!", e)
        # TODO: exception is ignored, is that what we want here?
    end
end



const _channel_cache = Dict{UInt64, Channel}()



if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

