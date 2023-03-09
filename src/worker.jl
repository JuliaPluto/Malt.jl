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
 
    dir = mktempdir()
     @debug("WORKER: Fifo dir: ", dir)
    serve(dir)
end

function serve(dir)
    h2w_path = joinpath(dir, "h2w")        
    w2h_path = joinpath(dir, "w2h")        

    # the order of everything is important...
    # first create fifos
    run(`mkfifo $h2w_path`)
    run(`mkfifo $w2h_path`)

    # then, publish information to host
    println(stdout, dir)
    flush(stdout)


    # the ordering and modes need to be reversed on the host    
    w2h = open(w2h_path, "w")
    h2w = open(h2w_path, "r")
    
    _buffer_writes(w2h)
    # Handle request asynchronously
    @async while true
        if !isopen(h2w)
            @debug("WORKER: io closed.")
            break
        end
        @debug "WORKER: Waiting for message"
        msg_type = try
            if eof(h2w)
                @debug("WORKER: io closed.")
                break
            end
            read(h2w, UInt8)
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
        msg_id = read(h2w, MsgID)
        
        msg_data, success = try
            deserialize(h2w), true
        catch err
            err, false
        finally
            _discard_until_boundary(h2w)
        end
        
        if !success
            if msg_type === MsgType.from_host_call_with_response
                msg_type = MsgType.special_serialization_failure
            else
                continue
            end
        end
        
        try
            @debug("WORKER: Received message", msg_data)
            handle(Val(msg_type), w2h, msg_data, msg_id)
            @debug("WORKER: handled")
        catch e
            if e isa InterruptException
                @debug("WORKER: Caught interrupt while handling message, ignoring...")
            else
                @error("WORKER: Caught exception while handling message, ignoring...", exception = (e, backtrace()))
            end
            handle(Val(MsgType.special_serialization_failure), w2h, e, msg_id)
        end
    end
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
        @warn("WORKER: Got exception while running call without response", exception=(e, catch_backtrace()))
        # TODO: exception is ignored, is that what we want here?
    end
end

function handle(::Val{MsgType.special_serialization_failure}, socket, msg, msg_id::MsgID)
    _serialize_msg(
        socket,
        MsgType.from_worker_call_failure,
        msg_id,
        msg
    )
end

const _channel_cache = Dict{UInt64, Channel}()

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

