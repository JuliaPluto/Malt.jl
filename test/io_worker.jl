using Sockets: Sockets

function socket_pair()
    port, server = Sockets.listenany(Sockets.localhost, 9000)
    near = @async Sockets.connect(Sockets.localhost, port)
    far = Sockets.accept(server)
    close(server)
    return fetch(near), far
end

# The protocol over something that is not a socket.
struct DuplexIO <: IO
    incoming::Base.BufferStream
    outgoing::Base.BufferStream
    write_lock::ReentrantLock
end
Base.isopen(d::DuplexIO) = isopen(d.incoming)
Base.eof(d::DuplexIO) = eof(d.incoming)
Base.read(d::DuplexIO, ::Type{UInt8}) = read(d.incoming, UInt8)
Base.unsafe_read(d::DuplexIO, p::Ptr{UInt8}, n::UInt) = unsafe_read(d.incoming, p, n)
Base.write(d::DuplexIO, x::UInt8) = write(d.outgoing, x)
Base.unsafe_write(d::DuplexIO, p::Ptr{UInt8}, n::UInt) = unsafe_write(d.outgoing, p, n)
Base.flush(d::DuplexIO) = flush(d.outgoing)
Base.lock(d::DuplexIO) = lock(d.write_lock)
Base.unlock(d::DuplexIO) = unlock(d.write_lock)
function Base.close(d::DuplexIO)
    close(d.outgoing)
    close(d.incoming)
end

function duplex_pair()
    a, b = Base.BufferStream(), Base.BufferStream()
    return DuplexIO(a, b, ReentrantLock()), DuplexIO(b, a, ReentrantLock())
end

function pending_call_terminated(task)
    try
        wait(task)
    catch e
        return e isa TaskFailedException && task.exception isa m.TerminatedWorkerException
    end
    return false
end

@testset "IOWorker over $(pair)" for pair in (socket_pair, duplex_pair)
    @testset "calls" begin
        near, far = pair()
        served = @async m.serve(far)
        w = m.IOWorker(near)
        @test m.isrunning(w)

        @test m.remote_call_fetch(+, w, 1, 2) == 3
        @test fetch(m.remote_call(*, w, 2, 3)) == 6
        @test m.remote_call_wait(+, w, 1, 2) === nothing
        @test m.remote_eval_fetch(Main, w, :(1 + 1)) == 2
        @test fetch.([m.remote_call(identity, w, i) for i in 1:50]) == 1:50

        @test_throws m.RemoteException m.remote_call_fetch(error, w, "boom")

        channel = m.worker_channel(w, :(Channel{Int}(1)))
        put!(channel, 7)
        @test take!(channel) == 7

        m.remote_do(Core.eval, w, Main, :(put!(Main._channel_cache[$(channel.id)], 8)))
        @test timedwait(() -> isready(channel), 10.0) === :ok
        @test take!(channel) == 8

        pending = m.remote_eval(w, :(sleep(0.5)))
        @test m.stop(w)
        @test !m.isrunning(w)
        @test m.stop(w) == false
        @test pending_call_terminated(pending)
        @test_throws m.TerminatedWorkerException m.remote_call_fetch(+, w, 1, 2)
        @test timedwait(() -> istaskdone(served), 10.0) === :ok
        close(far)
    end

    @testset "other side goes away" begin
        near, far = pair()
        served = @async m.serve(far)
        w = m.IOWorker(near)
        @test m.remote_call_fetch(+, w, 1, 2) == 3
        pending = m.remote_eval(w, :(sleep(0.5)))
        close(far)
        @test pending_call_terminated(pending)
        @test !m.isrunning(w)
        @test_throws m.TerminatedWorkerException m.remote_call_fetch(+, w, 1, 2)
        @test timedwait(() -> istaskdone(served), 10.0) === :ok
    end

    @testset "kill" begin
        near, far = pair()
        served = @async m.serve(far)
        w = m.IOWorker(near)
        kill(w)
        @test !m.isrunning(w)
        @test timedwait(() -> istaskdone(served), 10.0) === :ok
        close(far)
    end
end
