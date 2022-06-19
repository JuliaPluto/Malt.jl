# Week 1

## "State of the art"

Different ways to communicate Julia processes:

- [Distributed](https://docs.julialang.org/en/v1/stdlib/Distributed/)
- [RemoteREPL](https://github.com/c42f/RemoteREPL.jl):
  The code seems to be very well organized, but both the client and the server
  need to import the `RemoteREPL` module.
- [DaemonMode](https://github.com/dmolina/DaemonMode.jl):
  The goal of deamonmode is to run julia scripts faster. However:
  The code for the client and the server is in the same file 😐,
  the client still takes some time to start, and the messages sent to
  the server are not structured (strings separated by newlines).
  If the client was a shell script instead, the whole thing
  might be a lot faster.
- [IJulia](https://github.com/JuliaLang/IJulia.jl)


## Readings

Things I read during the first week:

- [A deep dive into Distributed.jl](https://juntian.me/programming/A_Deep_Dive_into_Distributed.jl/)
  explains the control flow of Distributed. 
  While reading this, I noticed that —by default— Distributed creates processes
  in detached mode, which means `SIGINT` is not passed to it!

- [Beej's Guide to Network Programming](https://beej.us/guide/bgnet/)
  to review the order in which socket functions should be called.

- `man netstat(1)`. Darwin/MacOS doesn't include the `-p` flag to list PIDs. 😤

- Parts of `julia/base/proccess.jl`.


## Difficulties

Problems I had during the week:

- To ensure connecting to an available port, the `TCPServer` has to be bound manually.
- IO in Julia is buffered by default. `flush` when necessary!
- The port number can be passed to the worker via arguments or env variables.
  For now, I've settled on an env variable.


# TO-DO Next week
- Talk to prof. Pedraza

