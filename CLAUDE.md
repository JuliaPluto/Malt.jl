# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Malt.jl is a multiprocessing package for Julia focused on process sandboxing (not distributed computing). It's used by Pluto.jl to manage Julia processes that execute notebook code, serving as a replacement to Julia's Distributed standard library.

Key differences from Distributed.jl:
- Process isolation: workers don't inherit ENV variables or Pkg environment
- Nested use: workers can host their own workers
- Cross-platform interrupts (including Windows)
- Faster launch times (~50% faster)
- Expression evaluation API via `remote_eval_fetch`

## Development Commands

### Testing
```bash
julia --project=. -e "using Pkg; Pkg.test()"
```

### Documentation
```bash
julia --project=doc doc/make.jl
```

### Individual Test Files
```bash
julia --project=. test/basic.jl
julia --project=. test/interrupt.jl  
julia --project=. test/exceptions.jl
julia --project=. test/nesting.jl
julia --project=. test/benchmark.jl
```

## Architecture

### Core Components

**Main Module (`src/Malt.jl`)**: Defines the main API and worker types
- `Worker`: External Julia process communication via TCP sockets
- `InProcessWorker`: Same-process execution for testing/debugging  
- `RemoteChannel`: Channel communication between host and workers

**Worker Process (`src/worker.jl`)**: Standalone Julia script that workers execute
- Listens on TCP socket for commands from host process
- Handles message deserialization and function execution
- Manages interrupt signals and error formatting

**Shared Protocol (`src/shared.jl`)**: Communication protocol definitions
- `MsgType` constants for different message types
- Message serialization/deserialization utilities
- Message boundary markers for error recovery

### Communication Architecture

1. **Host Process** spawns worker via `julia worker.jl`
2. **Worker** creates TCP server, prints port to stdout  
3. **Host** connects to worker's TCP port
4. **Message Exchange** using custom binary protocol:
   - Message type (UInt8) + Message ID (UInt64) + Serialized data + Boundary marker
   - Async message handling with response correlation via message IDs

### API Layers

**High-level API**:
- `remote_call*`: Function execution with return values
- `remote_eval*`: Expression evaluation  
- `remote_do`: Fire-and-forget execution
- `worker_channel`: Bidirectional communication

**Low-level Protocol**:
- `_send_msg`: Send message to worker
- `_wait_for_response`: Block for worker response  
- `_send_receive`: Combined send/receive

### Process Management

- Workers auto-terminate when host loses reference (finalizers)
- Graceful shutdown: `Base.exit` → `SIGTERM` → `SIGKILL`
- Cross-platform interrupt handling (Windows uses `GenerateConsoleCtrlEvent`)
- Process tracking via `__iNtErNaL_running_procs` set

## Key Files

- `src/Malt.jl`: Main module with Worker struct and high-level API
- `src/worker.jl`: Worker process entry point and message handling  
- `src/shared.jl`: Communication protocol and message types
- `src/DistributedStdlibWorker.jl`: Compatibility layer for Distributed.jl patterns
- `test/runtests.jl`: Test orchestration with process cleanup validation