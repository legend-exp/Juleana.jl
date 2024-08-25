#!/usr/bin/env -S julia

##################
# Start Processing
##################
include(joinpath(@__DIR__,"logo/juleana.jl"))

# load default packages
import Pkg, REPL
using REPL.TerminalMenus

# check if environment is default environment, than activate project
@info "Using Julia $VERSION"
if last(split(string(dirname(Pkg.project().path)), ".julia/")) == last(split(string(joinpath(first(Pkg.DEPOT_PATH), "environments", "v$(VERSION.major).$(VERSION.minor)")), ".julia/"))
    @info "Using dataflow project"
    Pkg.activate(@__DIR__)
else
    @info "Using Julia project $(dirname(Pkg.project().path))"
end
@info "Load LEGEND packages"

# check if LEGEND packages should be updated
if isinteractive()
    try
        legend_packages = ["LegendHDF5IO", "LegendDataTypes", "LegendDataManagement", "LegendSpecFits", "LegendDSP", "LegendEventAnalysis"]
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

# precompile all packages
Pkg.precompile()

# load packages
include(joinpath(@__DIR__,"src/LegendJuliaDataflow.jl"))

# evaluate config
l200, processing_config, runs, periods = get_processingconfig()
@info "Start Data processing"

# load all available processors
include.(filter(contains(r".jl$"), readdir(joinpath(@__DIR__, "processors/"); join=true)))

# create workers
runmode = SlurmRun(
    slurm_flags = get_slurm_flags(processing_config),
    julia_flags = get_julia_flags(processing_config),
    redirect_output = false,
    env = first(processing_config.env_args_worker)
)
@info "Write worker start script to $(joinpath(@__DIR__, "startjlworkers.sh"))"
write_worker_start_script(joinpath(@__DIR__, "startjlworkers.sh"), runmode)
# get wpool
wpool = FlexWorkerPool(withmyid = false, label = "juleana"; maxoccupancy = 1)
ppt_worker_pool!(wpool)

# submit to cluster
if processing_config.submit_slurm
    @async runworkers(runmode)
end

# set up dependency graph
process_status, p_process_status = setup_dependency_graph(processing_config, periods, runs)

flush(stdout)

#################
# Interactive Mode
#################
if isinteractive()
    # execute interactive menu
    menu()
else
    @sync begin

        ####################
        # Process Partitions
        ####################
        if !processing_config.only_runs

            # get processing steps from config for partitions
            p_process_steps =  processing_config.p_process_steps

            # process partitions 
            Threads.@spawn begin
                for period in periods

                    @info "Process partitions in $period"

                    Threads.@spawn begin
                        # iterate through process steps
                        for process in p_process_steps
                            @info "$(string(process))"

                            if !processing_config.only_partitions
                                # check if p process has dependencies
                                dependencies = Symbol.(processing_config.p_processors[process].dependencies)
                                # combined periods and actual period to check for dependency globally
                                combined_periods = unique(push!(get_partition_combined_periods(l200, period), period))
                                # add all smaller ranks to list of dependencies and remove duplicates
                                dependencies = unique(vcat([processing_config.possible_process_steps[1:findfirst(processing_config.possible_process_steps .== dep)] for dep in dependencies]...))
                                if !all([all(values(process_status[period][dep])) for dep in dependencies for period in combined_periods])
                                    @warn "Dependencies not yet met for $(string(process))"
                                end
                                while !all([all(values(process_status[period][dep])) for dep in dependencies])
                                    sleep(10)
                                end
                            end

                            # get kwargs
                            kwargs = NamedTuple([(k, v) for (k, v) in pairs(processing_config.p_processors[process].kwargs)])
                            # make sure that only the first period in each partitions are processed
                            kwargs = merge(kwargs, (only_first_period = DataPeriod(period.no - 1) in periods, ))
                            # run process
                            has_lower_period_depedency = getfield(Main, process)(processing_config, l200, period,; kwargs...)

                            # if process finished but depends on lower period dependency wait till met
                            if has_lower_period_depedency
                                if !p_process_status[DataPeriod(period.no - 1)][process]
                                    @warn "Processed $period $(string(process)) but depends on $(DataPeriod(period.no - 1)) --> wait"
                                end
                                while !p_process_status[DataPeriod(period.no - 1)][process]
                                    sleep(10)
                                end
                            end
                            # update process status
                            p_process_status[period][process] = true

                            @info "Finished $period $(string(process))"
                        end
                    end
                end
            end
        end

        ####################
        # Process Runs
        ####################
        if !processing_config.only_partitions
            
            # get processing steps from config and sort by rank
            process_steps =  processing_config.process_steps

            # process periods
            Threads.@spawn begin
                for period in periods
                    Threads.@spawn begin
                        @info "Process period $period"

                        # select runs to process
                        processable_runs = sort(collect(keys(last(first(process_status[period])))))

                        # process runs
                        for run in processable_runs

                            Threads.@spawn begin
                                # iterate through process steps
                                @info "Process run $run"
                                for process in process_steps
                                    @info "$(string(process))"
                                    flush(stdout)

                                    # check if run is a analysis run if switched on
                                    if processing_config.analysis_runs_only && !is_analysis_run(l200, (period, run, processing_config.processors[process].category))
                                        @warn "$period-$run-$(processing_config.processors[process].category) is not a analysis run, skip $(string(process))"
                                        continue
                                    elseif !is_lrun(l200, (period, run, processing_config.processors[process].category))
                                        @warn "$period-$run-$(processing_config.processors[process].category) is not in runinfo, skip $(string(process))"
                                        continue
                                    end
                                    
                                    # check if process has dependencies
                                    if !processing_config.only_runs
                                        # get all dependencies of process from config
                                        dependencies = Symbol.(processing_config.processors[process].dependencies)
                                        # add all smaller ranks to list of dependencies and remove duplicates
                                        dependencies = unique(vcat([processing_config.p_possible_process_steps[1:findfirst(processing_config.p_possible_process_steps .== dep)] for dep in dependencies]...))
                                        # check if dependencies are met
                                        if !all([p_process_status[period][dep] for dep in dependencies])
                                            @warn "Dependencies not yet met for $(string(process))"
                                        end
                                        # if not met wait till met
                                        while !all([p_process_status[period][dep] for dep in dependencies])
                                            sleep(10)
                                        end
                                    end

                                    # get kwargs
                                    kwargs = NamedTuple([(k, v) for (k, v) in pairs(processing_config.processors[process].kwargs)])
                                    # run process
                                    getfield(Main, process)(processing_config, l200, period, run,; kwargs...)

                                    # flush streams
                                    flush(stdout)

                                    # update process status
                                    process_status[period][process][run] = true

                                    @info "Finished $period-$run $(string(process))"
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    @info "# Processing Done"
end
