## DONE

- Create workers processes dynamically
- Bind TCP ports dynamically (no port exhaustion problems)
- Send messages over TCP


### Readings

Things I read during the first week:

- [A deep dive into Distributed.jl](https://juntian.me/programming/A_Deep_Dive_into_Distributed.jl/)
  explains the control flow of Distributed. 
  While reading this, I noticed that —by default— Distributed creates processes
  in detached mode, which means `SIGINT`s are not passed to them!
- [Beej's Guide to Network Programming](https://beej.us/guide/bgnet/)
  to review the order in which socket functions should be called.
- `man netstat(1)`. Darwin/MacOS doesn't include the `-p` flag to list PIDs. 😤
- Parts of `julia/base/proccess.jl`.

### Looking into the "state of the art"

Different ways to communicate Julia processes:

- [Distributed](https://docs.julialang.org/en/v1/stdlib/Distributed/)
- [RemoteREPL](https://github.com/c42f/RemoteREPL.jl):
  The code seems to be very well organized, but both the client and the server
  need to import the `RemoteREPL` module.
- [DaemonMode](https://github.com/dmolina/DaemonMode.jl):
  The goal of DaemonMode is to run Julia scripts faster. However,
  the client and server code is in the same file 😐,
  the client takes quite a while to start, and the messages sent to
  the server are not structured (newline-separated strings).
  The client does very little, and it might be faster if it was a shell script instead.
- [IJulia](https://github.com/JuliaLang/IJulia.jl)


### Difficulties
 
Problems I had during the week:

- To ensure connecting to an available port, the `TCPServer` has to be bound manually.
- IO in Julia is buffered by default. `flush` when necessary!
- The port number can be passed to the worker via arguments or env variables.
  For now, I've settled on an env variable.

