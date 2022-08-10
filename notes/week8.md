## DONE

- Replace Distributed with Malt in Pluto. See fonsp/Pluto.jl#2240


## TODO

- There's a world age problem when making the Pluto logger global (`make_global` kwarg).
  No idea how that's supposed to be debugged.

<!--
Should the Pluto server disable `exit_on_sigint` (like the worker already does)?

Malt + Pluto works
Malt + Distributed works
Malt + Pluto + Distributed doesn't work (???)
-->

