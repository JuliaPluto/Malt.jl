## DONE

*Add unidirectional remote channels:* Pluto only needs remote channels to
send information from the worker to the main process, mainly for logging and
sending data on async events (PlutoHooks).

*Package namespace issue:* When loading Malt as a module (as opposed to single
files with `include`) all the structs are namespaced to the module. This
information is sent when serializing a struct (which makes sense because Julia
has a nominal type system), so both ends need exaclty the same packages loaded.
Basically, the workers also have to `import Malt`.


## TODO

An alternative solution to the package namespace issue might be to communicate
using tuples instead of structs.
