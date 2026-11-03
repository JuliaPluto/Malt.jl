# The worker side of the Malt protocol, included after `shared.jl` by both entry points:
#   * `worker.jl`, the spawned-process script, accepts a TCP connection and serves it.
#   * the `Malt` module, so a running process can serve any bidirectional `IO`.

const _channel_cache = Dict{UInt64, AbstractChannel}()

format_error(err, bt) = sprint() do io
    Base.invokelatest(showerror, io, err, bt)
end

"""
    Malt.serve(io::IO)

Run the worker message loop over `io` until it closes: read a message, dispatch it and
write the response back over the same `io`. This is the far end of a [`Malt.IOWorker`](@ref).
"""
function serve(io::IO)
    # `RemoteChannel` builds expressions that reference `Main._channel_cache`. `worker.jl`
    # runs in `Main`, so it is already there. The `Malt` module has to alias its own cache.
    isdefined(Main, :_channel_cache) || Core.eval(Main, :(const _channel_cache = $(_channel_cache)))

    # Here we use:
    # `for _i in Iterators.countfrom(1)`
    # instead of
    # `while true`
    # as a workaround for https://github.com/JuliaLang/julia/issues/37154
    for _i in Iterators.countfrom(1)
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
            (Base.invokelatest(deserialize, io), true)
        catch err
            (format_error(err, catch_backtrace()), false)
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
            @debug("WORKER: Received message", msg_data)
            handle(Val(msg_type), io, msg_data, msg_id)
            @debug("WORKER: handled")
        catch e
            if e isa InterruptException
                @debug("WORKER: Caught interrupt while handling message, ignoring...")
            else
                @error("WORKER: Caught exception while handling message, ignoring...", exception = (e, backtrace()))
            end
            handle(Val(MsgType.special_serialization_failure), io, e, msg_id)
        end
    end
end

function handle(::Val{MsgType.from_host_call_with_response}, socket, msg, msg_id::MsgID)
    f, args, kwargs, respond_with_nothing = msg

    @async begin
        result, success = try
            result = f(args...; kwargs...)

            # @debug("WORKER: Evaluated result", result)
            (respond_with_nothing ? nothing : result, true)
        catch err
            # @debug("WORKER: Got exception!", e)
            (format_error(err, catch_backtrace()), false)
        end

        _serialize_msg(
            socket,
            success ? MsgType.from_worker_call_result : MsgType.from_worker_call_failure,
            msg_id,
            result
        )
    end
end

function handle(::Val{MsgType.from_host_call_without_response}, socket, msg, msg_id::MsgID)
    f, args, kwargs, _ignored = msg

    @async try
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
