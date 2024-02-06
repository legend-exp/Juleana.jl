#!/usr/bin/env -S julia -t 1 --project=../ --heap-size-hint=10G

# set julia traget to generic for similar compilecache in all workers
ENV["JULIA_CPU_TARGET"] = "generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)"

##################
# Start Processing
##################

# load utils
import Pkg
@info "Using Julia $VERSION"
@info "Using Julia project $(dirname(Pkg.project().path))"
@info "Load LEGEND packages"

# precompile all packages
Pkg.instantiate()
Pkg.precompile()

# load packages
include(joinpath(@__DIR__,"src/LegendJuliaDataflow.jl"))

# evaluate config
processing_config, runs, periods, partitions = get_processingconfig()

# kill all workers at exist
atexit(kill_sessions)

# load metadata
@info "Loading Legend MetaData"
l200 = LegendData(:l200)

# exit()

@info "Start Data processing"

# load all available processors
include.(filter(contains(r".jl$"), readdir("processors/"; join=true)))

####################
# Process Runs
####################
if !processing_config.only_partitions
    
    # get processing steps from config and sort by rank
    process_steps =  processing_config.process_steps

    # process periods 
    for period in periods
        @info "Process period $period"

        # select runs to process
        processable_runs = get_proccessable_runs(runs, period)

        # process runs
        for run in processable_runs

            # check if run is a analysis run if switched on
            if processing_config.analysis_runs_only && !is_analysis_run(l200, period, run)
                @warn "Run $run is not a analysis run"
                continue
            end

            # iterate through process steps
            @info "Process run $run"
            for process in process_steps
                @info "$process"

                # run process
                kwargs = NamedTuple([(k, v) for (k, v) in pairs(processing_config.processors[process]) if !(k in [:enabled, :rank, :n_workers])])
                getfield(Main, process)(processing_config, l200, period, run,; kwargs...)
            end
        end
    end
end

####################
# Process Partitions
####################
if !processing_config.only_runs

    # get processing steps from config for partitions
    process_steps =  processing_config.p_process_steps

    # get processable partitions
    processable_partitions = get_processable_partitions(partitions)

    # process partitions 
    for partition in partitions

        # iterate through process steps
        @info "Process partition $partition"
        for process in process_steps
            @info "$process"

            # create workers
            create_workers(processing_config, process)

            # run process
            kwargs = NamedTuple([(k, v) for (k, v) in pairs(processing_config.p_processors[process]) if !(k in [:enabled, :rank, :n_workers])])
            getfield(Main, process)(processing_config, l200, period, run,; kwargs...)
        end
    end
end

@info "##################"
@info "# Processing Done #"
@info "##################"