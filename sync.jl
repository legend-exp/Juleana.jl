#!/usr/bin/env -S julia

import Pkg

# Mirror main.jl: activate the dataflow project only when the default
# environment is active, so `julia --project=<other> sync.jl` keeps that project.
if last(split(string(dirname(Pkg.project().path)), ".julia/")) == last(split(string(joinpath(first(Pkg.DEPOT_PATH), "environments", "v$(VERSION.major).$(VERSION.minor)")), ".julia/"))
    Pkg.activate(@__DIR__)
end

include(joinpath(@__DIR__, "src", "sync", "JuleanaSync.jl"))

exit(JuleanaSync.main(ARGS))
