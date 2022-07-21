"""Supertype for requests send to, and responses received from Dalt workers"""
abstract type AbstractMessage end

# TODO: Completion requests

struct EvalRequest <: AbstractMessage
    ex::Expr
end

# TODO: Responses should only use Core and Base types. To avoid
# module loading mismatches.
struct EvalResponse{T} <: AbstractMessage
    response::T
end

# TODO: Move this docstring elsewhere??
"""
    ChannelRequest(ex::Expr)

`ChannelRequest` is a type of message sent to Dalt workers to create a
unidirectional Channel between processes (from worker to manager).

`ex` has to be an expression that evaluates to a Channel. `ex` should assign
the Channel to a global variable so the worker has a handle that can be used to
send messages back to the manager.
"""
struct ChannelRequest <: AbstractMessage
    ex::Expr
end

struct ExitRequest <: AbstractMessage end

