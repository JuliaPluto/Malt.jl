using Logging
using Serialization
using Sockets

## Allow catching InterruptExceptions
Base.exit_on_sigint(false)

# ENV["JULIA_DEBUG"] = @__MODULE__

include("./MsgType.jl")
include("./BufferedIO.jl")

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
                    
                    msg_type = read(client_connection, UInt8)
                    msg_id = read(client_connection, MsgID)
                    msg_data = deserialize(client_connection)
                    
                    # TODO: msg boundary
                    # _discard_msg_boundary = deserialize(client_connection)
                    
                    if msg_type === MsgType.from_host_interrupt
                        interrupt(latest)
                    else
                        @debug("WORKER: Received message", msg_data)
                        handle(Val(msg_type), client_connection, msg_data, msg_id)
                        @debug("WORKER: handled")
                        
                    end
                end
            end
        catch e
            if e isa InterruptException
                @debug("WORKER: Caught interrupt!")
            else
                @error("WORKER: Caught exception!", exception=(e, backtrace()))
            end
            interrupt(latest)
            continue
        end
    end
    @debug("WORKER: Closed server socket. Bye!")
end

# Check if task is still running before throwing interrupt
interrupt(t::Task) = istaskdone(t) || Base.schedule(t, InterruptException(); error=true)
interrupt(::Nothing) = nothing



"""
Low-level: send a message to the host.
"""
function _send_msg(host_socket, msg_type::UInt8, msg_id::MsgID, msg_data)
    # io = IOBuffer()
    # write(io, msg_type)
    # write(io, msg_id)
    # serialize(io, msg_data)
    # seekstart(io)
    # write(host_socket, io)
    
    @debug "asdf" msg_type msg_data
    
    
    # write(host_socket, msg_type)
    # write(host_socket, msg_id)
    # serialize(host_socket, msg_data)
    
    
    io = BufferedIO(host_socket; buffersize=8192)
    # Change the buffersize (while keeping it fixed on the server side) and run our benchmarks. Results:
    # 32 is too small
    # 64 is too small
    # 128 is too small
    # 256 is too small ?
    # 512 is good
    # 1024 is good
    # 2048 is good
    # 4096 is good
    # 8192 is good
    # 16384 is good
    # 32768 is good
    # 65536 is good
    # 131072 is good
    # 262144 is good
    # 524288 is too big
    # 1048576 is good
    # 2097152 is too big
    # 16777216 is too big
    
    write(io, msg_type)
    write(io, msg_id)
    serialize(io, msg_data)
    # TODO: send msg boundary
    # serialize(host_socket, MSG_BOUNDARY)
    
    flush(io)
    return nothing
end


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
    
    _send_msg(
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





# function handle(::Val{:channel}, socket, msg, msg_id::MsgID)
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

