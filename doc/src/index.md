# Malt.jl

Malt is a multiprocessing package for Julia.
You can use Malt to create Julia processes, and to perform computations in those processes.
Unlike the standard library package [`Distributed.jl`](https://docs.julialang.org/en/v1/stdlib/Distributed/),
Malt is focused on process sandboxing, not distributed computing.

```@docs
Malt
```



## Malt workers

We call the Julia process that creates processes the **manager,**
and the created processes are called **workers.**
These workers communicate with the manager using the TCP protocol.

Workers are isolated from one another by default.
There's no way for two workers to communicate with one another,
unless you set up a communication mechanism between them explicitly.

Workers have separate memory, separate namespaces, and they can have separate project environments;
meaning they can load separate packages, or different versions of the same package.

Since workers are separate Julia processes, the number of workers you can create,
and whether worker execution is multi-threaded will depend on your operating system.

```@docs
Malt.Worker
```



## Calling Functions

The easiest way to execute code in a worker is with the `remotecall*` functions.

Depending on the computation you want to perform, you might want to get the result
synchronously or asynchronously; you might want to store the result or throw it away.
The following table lists each function according to its scheduling and return value:


| Function                        | Scheduling | Return value    |
|:--------------------------------|:-----------|:----------------|
| [`Malt.remotecall`](@ref)       | Async      | <value>         |
| [`Malt.remote_do`](@ref)        | Async      | `nothing`       |
| [`Malt.remotecall_fetch`](@ref) | Blocking   | <value>         |
| [`Malt.remotecall_wait`](@ref)  | Blocking   | `nothing`       |


```@docs
Malt.remotecall
Malt.remote_do
Malt.remotecall_fetch
Malt.remotecall_wait
```

## Evaluating expressions

In some cases, evaluating functions is not enough. For example, importing modules
alters the global state of the worker and can only be performed in the top level scope.
For situations like this, you can evaluate code using the `remote_eval*` functions.

Like the `remotecall*` functions, there's different a `remote_eval*` depending on the scheduling and return value.


```@docs
Malt.remote_eval
Malt.remote_eval_fetch
Malt.remote_eval_wait
Malt.worker_channel
```

## Signals and Termination

Once you're done computing with a worker, or if you find yourself in an unrecoverable situation
(like a worker executing a divergent function), you'll want to terminate the worker.

The ideal way to terminate a worker is to use the `stop` function,
this will send a message to the worker requesting a graceful shutdown.

Note that the worker process runs in the same process group as the manager,
so if you send a [signal](https://en.wikipedia.org/wiki/Signal_(IPC)) to a manager,
the worker will also get a signal.

```@docs
Malt.isrunning
Malt.stop
Base.kill(::Malt.Worker)
Malt.interrupt
Malt.TerminatedWorkerException
```

