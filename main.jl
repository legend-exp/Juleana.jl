# julia -t 1 --project=/ptmp/lschl/l200/current/jlenv --heap-size-hint=10G main.jl --config ./config/processing_config.json -p 3 -r 0 1 --only_runs

# set julia traget to generic for similar compilecache in all workers
ENV["JULIA_CPU_TARGET"] = "generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)"

##################
# Start Processing
##################
include(joinpath(@__DIR__,"src/juleana.jl"))

# load utils
import Pkg
@info "Using Julia $VERSION"
@info "Using Julia project $(dirname(Pkg.project().path))"
@info "Load LEGEND packages"

# precompile all packages
Pkg.precompile()

# load packages
include(joinpath(@__DIR__,"src/LegendJuliaDataflow.jl"))

# evaluate config
l200, processing_config, runs, periods, partitions = get_processingconfig()
@info "Start Data processing"

# load all available processors
include.(filter(contains(r".jl$"), readdir(joinpath(@__DIR__, "processors/"); join=true)))

# create workers
if !processing_config.submit_slurm
    runmode = SlurmRun(
        slurm_flags = get_slurm_flags(processing_config),
        julia_flags = get_julia_flags(processing_config),
        redirect_output = false,
        # env = processing_config.env_args_worker
    )
    @info "Write worker start script to $(joinpath(homedir(), "startjlworkers.sh"))"
    write_worker_start_script(joinpath(homedir(), "startjlworkers.sh"), runmode)
    # get wpool
    wpool = FlexWorkerPool(withmyid = false, label = "juleana"; maxoccupancy = 1)
    ppt_worker_pool!(wpool)
    # run mode 
    # @async runworkers(runmode)
end

flush(stdout)

####################
# Process Runs
####################
if !processing_config.only_partitions
    
    # get processing steps from config and sort by rank
    process_steps =  processing_config.process_steps

    # process periods
    @sync begin
        for period in periods
            Threads.@spawn begin
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

                    # submit slurm job if enabled
                    if processing_config.submit_slurm
                        sbatch(l200, processing_config, period, run)
                        continue
                    end

                    Threads.@spawn begin
                        # iterate through process steps
                        @info "Process run $run"
                        for process in process_steps
                            @info "$process"
                            flush(stdout)

                            # run process
                            kwargs = NamedTuple([(k, v) for (k, v) in pairs(processing_config.processors[process]) if !(k in [:enabled, :rank, :n_workers])])
                            getfield(Main, process)(processing_config, l200, period, run,; kwargs...)
                            flush(stdout)
                        end
                    end
                end
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
    @sync begin 
        for part in partitions

            @info "Process partition $part"

            # submit slurm job if enabled
            if processing_config.submit_slurm
                sbatch(l200, processing_config, part)
                continue
            end

            Threads.@spawn begin
                # iterate through process steps
                for process in process_steps
                    @info "$process"

                    # run process
                    kwargs = NamedTuple([(k, v) for (k, v) in pairs(processing_config.p_processors[process]) if !(k in [:enabled, :rank, :n_workers])])
                    getfield(Main, process)(processing_config, l200, part,; kwargs...)
                end
            end
        end
    end
end

@info "# Processing Done"