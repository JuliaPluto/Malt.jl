"""Supertype for requests send to, and responses received from Dalt workers"""
abstract type AbstractMessage end

# TODO: Completion requests

struct EvalRequest <: AbstractMessage
    expr::Expr
end

struct EvalResponse <: AbstractMessage
    response
end

struct ExitRequest <: AbstractMessage end

