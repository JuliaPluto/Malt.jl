
struct RemoteChannel{T} <: AbstractChannel{T}
    worker::AbstractWorker
    id::UInt64

    function RemoteChannel{T}(worker::AbstractWorker, expr) where {T}

        id = (worker.current_message_id += MsgID(1))::MsgID
        remote_eval_wait(Main, worker, quote
            Main._channel_cache[$id] = $expr
        end)
        new{T}(worker, id)
    end

    RemoteChannel(w::AbstractWorker, expr) = RemoteChannel{Any}(w, expr)
end





Base.take!(rc::RemoteChannel) = remote_eval_fetch(Main, rc.worker, :(take!(Main._channel_cache[$(rc.id)])))::eltype(rc)

Base.put!(rc::RemoteChannel, v) = remote_eval_wait(Main, rc.worker, :(put!(Main._channel_cache[$(rc.id)], $v)))

Base.isready(rc::RemoteChannel) = remote_eval_fetch(Main, rc.worker, :(isready(Main._channel_cache[$(rc.id)])))::Bool

Base.wait(rc::RemoteChannel) = remote_eval_wait(Main, rc.worker, :(wait(Main._channel_cache[$(rc.id)])))::Bool

