using Logging: Logging, @debug
using Serialization: serialize, deserialize, Serializer
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
    # FIXME: This `latest` task no longer works
    latest = nothing
    while isopen(server)
        try
            # Wait for new request
            @debug("WORKER: Waiting for new connection")
            io = Sockets.accept(server)
            @debug("WORKER: New connection", io)
            
            # Set network parameters, this is copied from Distributed
            Sockets.nagle(io, false)
            Sockets.quickack(io, true)
            _buffer_writes(io)

            serializer = Serializer(io)

            # Handle request asynchronously
            latest = @async while true
                if !isopen(io)
                    @debug("WORKER: io closed.")
                    break
                end
                @debug "WORKER: Waiting for message"
                msg_type = try
                    if eof(io)
                        @debug("WORKER: io closed.")
                        break
                    end
                    read(io, UInt8)
                catch e
                    if e isa InterruptException
                        @debug("WORKER: Caught interrupt while waiting for incoming data, ignoring...")
                        continue # and go back to waiting for incoming data
                    else
                        @error("WORKER: Caught exception while waiting for incoming data, breaking", exception = (e, backtrace()))
                        break
                    end
                end
                # this next line can't fail
                msg_id = read(io, MsgID)
                
                msg_data, success = try
                    deserialize(serializer), true
                catch err
                    err, false
                finally
                    _discard_until_boundary(io)
                end
                
                if !success
                    if msg_type === MsgType.from_host_call_with_response
                        msg_type = MsgType.special_serialization_failure
                    else
                        continue
                    end
                end
                
                try
                    if msg_type === MsgType.from_host_interrupt
                        @debug("WORKER: Received interrupt message")
                        interrupt(latest)
                    else
                        @debug("WORKER: Received message", msg_data)
                        handle(Val(msg_type), serializer, msg_data, msg_id)
                        @debug("WORKER: handled")
                    end
                catch e
                    if e isa InterruptException
                        @debug("WORKER: Caught interrupt while handling message, ignoring...")
                    else
                        @error("WORKER: Caught exception while handling message, ignoring...", exception = (e, backtrace()))
                    end
                    handle(Val(MsgType.special_serialization_failure), io, e, msg_id)
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


function handle(::Val{MsgType.from_host_call_with_response}, serializer, msg, msg_id::MsgID)
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
        serializer,
        success ? MsgType.from_worker_call_result : MsgType.from_worker_call_failure,
        msg_id,
        result
    )
end


function handle(::Val{MsgType.from_host_call_without_response}, serializer, msg, msg_id::MsgID)
    f, args, kwargs, _ignored = msg

    try
        f(args...; kwargs...)
    catch e
        @warn("WORKER: Got exception while running call without response", exception=(e, catch_backtrace()))
        # TODO: exception is ignored, is that what we want here?
    end
end

function handle(::Val{MsgType.special_serialization_failure}, serializer, msg, msg_id::MsgID)
    _serialize_msg(
        serializer,
        MsgType.from_worker_call_failure,
        msg_id,
        msg
    )
end

const _channel_cache = Dict{UInt64, Channel}()

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

