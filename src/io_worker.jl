"""
    Malt.IOWorker(io::IO)

A worker that speaks the Malt protocol over an already connected, bidirectional `io`,
for example a websocket to a process that is already running. The other end must be
running [`Malt.serve`](@ref) on the matching stream.

Malt owns no process here. [`Malt.stop`](@ref) and `kill` close `io`, and
[`Malt.interrupt`](@ref) is not available. Calls still waiting for a reply throw a
[`Malt.TerminatedWorkerException`](@ref) once `io` ends.

Messages are written from several tasks at once. A custom `IO` type has to implement
`Base.lock` and `Base.unlock`, so that each message stays in one piece. Sockets already do.
"""
mutable struct IOWorker <: ProtocolWorker
    io::IO
    current_message_id::MsgID
    expected_replies::Dict{MsgID,Channel{WorkerResult}}
    running::Bool
end

function IOWorker(io::IO)
    w = IOWorker(io, MsgID(0), Dict{MsgID,Channel{WorkerResult}}(), true)
    receiving = _receive_loop(w)
    # The receive loop only ends with the stream, so no more replies will arrive.
    @async try
        wait(receiving)
    finally
        stop(w)
        terminate_expected_replies(w)
    end
    return w
end

worker_io(w::IOWorker) = w.io

Base.summary(io::IO, ::IOWorker) = write(io, "Malt.IOWorker")

isrunning(w::IOWorker)::Bool = w.running && isopen(w.io)

function stop(w::IOWorker)
    w.running || return false
    w.running = false
    close(w.io)
    return true
end

Base.kill(w::IOWorker, signum=Base.SIGTERM) = (stop(w); nothing)
