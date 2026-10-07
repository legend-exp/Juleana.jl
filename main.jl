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

# import REPL TerminalMenus
import REPL
using REPL.TerminalMenus

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

# load packages
include(joinpath(@__DIR__,"src/LegendJuliaDataflow.jl"))

# evaluate config
l200, processing_config, runs, periods = get_processingconfig()
@info "Start Data processing"

# load all available processors
include.(filter(contains(r"\.jl$"), readdir(joinpath(@__DIR__, "processors/"); join=true)))
check_processor_kwargs(processing_config, Main)

if processing_config.runmode == :local
    runmode = OnLocalhost(
        n = processing_config.local_n,
        env = processing_config.env_variables
        )
    @async runworkers(runmode)
elseif processing_config.runmode == :slurm
    # create workers
    runmode = SlurmRun(
        slurm_flags = Cmd(processing_config.slurm_flags),
        julia_flags = Cmd(processing_config.slurm_julia_settings),
        redirect_output = false,
        env = processing_config.env_variables
    )
    @info "Write worker start script to $(joinpath(@__DIR__, "startjlworkers.sh"))"
    write_worker_start_script(joinpath(@__DIR__, "startjlworkers.sh"), runmode)
    # submit to cluster
    if processing_config.submit_jobs
        @async runworkers(runmode)
    end
end

# get wpool
wpool = FlexWorkerPool(withmyid = false, label = "juleana"; maxoccupancy = 1)
ppt_worker_pool!(wpool)
    

# enabled processing steps sorted by rank; with `only_runs`/`only_partitions` the other
# level is not scheduled and its steps start as finished in the dependency graph
process_steps = processing_config.only_partitions ? Symbol[] : run_steps(processing_config)
p_process_steps = processing_config.only_runs ? Symbol[] : partition_steps(processing_config)

# set up dependency graph
process_status, p_process_status = setup_dependency_graph(l200, processing_config, periods, runs, process_steps, p_process_steps)

flush(stdout)

#################
# Interactive Mode
#################
if isinteractive()
    Base.exit_on_sigint(false)
    # execute interactive menu
    menu()
else
    run_processing(processing_config, l200, periods, process_steps, p_process_steps, process_status, p_process_status; mod = Main)
    @info "# Processing Done"
end
