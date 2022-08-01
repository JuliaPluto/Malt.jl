## DONE

- Communicate with worker using tuples instead of structs (see [week 6](./week6.md)).
  * This means `src/messages.jl` isn't needed.
- Make API more like Distributed (naming conventions and the like).
  * `Distributed.remotecall_eval` has two methods: One blocking and one non-blocking.
    This is really unintuitive and it's probably better to have functions with different names.
- Format `Pluto.jl/src/evaluation/WorkspaceManager.jl`.

## TODO
- How should exceptions in the workers be handled?
  Exceptions defined in Core or Base can be serialized, be what about user defined exceptions?
- Pluto has a no-Distributed mode. The code has many `Distributed.myid()` checks.
  What should be done about those?

<!--
* Why is `remote_log_channel` double quoted? (in `make_workspace`)
* `while true` instead of `while isopen(...)`
-->

