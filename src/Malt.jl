module Malt

export Worker
export send
export stop
export remote_eval
export @remote_eval

include("./messages.jl")
include("./manager.jl")

end # module
