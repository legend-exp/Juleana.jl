#!/usr/bin/env -S julia

##################
# Start Processing
##################
include(joinpath(@__DIR__,"logo/juleana.jl"))

# load default packages
import Pkg

# check if environment is default environment, than activate project
@info "Using Julia $VERSION"
if last(split(string(dirname(Pkg.project().path)), ".julia/")) == last(split(string(joinpath(first(Pkg.DEPOT_PATH), "environments", "v$(VERSION.major).$(VERSION.minor)")), ".julia/"))
    @info "Using dataflow project"
    Pkg.activate(@__DIR__)
else
    @info "Using Julia project $(dirname(Pkg.project().path))"
end
@info "Load LEGEND packages"

# precompile all packages
Pkg.instantiate()
Pkg.precompile()

# terminal menu for the package update prompt
using REPL.TerminalMenus: RadioMenu, request

# check if LEGEND packages should be updated
if isinteractive()
    try
        legend_packages = ["LegendHDF5IO", "LegendDataTypes", "LegendMakie", "LegendDataManagement", "LegendSpecFits", "LegendDSP", "LegendEventAnalysis"]
        if request("Update LEGEND packages? $legend_packages", RadioMenu(["Yes", "No"], ctrl_c_interrupt = true)) == 1
            Pkg.instantiate()
            Pkg.resolve()
            Pkg.update(legend_packages)
        end
    catch e
        @error "Canceled: $e"
        exit(1)
    end
end

using Juleana

# in an interactive session, the session is left for `menu(session)`
session = Juleana.setup_session(ARGS)
if !isinteractive()
    run_processing(session)
    @info "# Processing Done"
end
