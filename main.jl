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
    # env = first(processing_config.env_args_worker)
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
# possible_steps = filter!(x -> x != :default, Symbol.(keys(processing_config.processors)))
# process_status = ConcurrentDict{DataPeriod, ConcurrentDict{Symbol, ConcurrentDict{DataRun, Bool}}}()
# for period in periods
#     # get all processable runs
#     processable_runs = get_proccessable_runs(runs, period)
#     # set up process status for each period
#     process_status[period] = ConcurrentDict{Symbol, ConcurrentDict{DataRun, Bool}}(possible_steps .=> [ConcurrentDict{DataRun, Bool}(processable_runs .=> Ref(p)) for p in .!getproperty.(getproperty.(Ref(processing_config.processors), possible_steps), Ref(:enabled))])
# end

# possible_p_steps = filter!(x -> x != :default, Symbol.(keys(processing_config.p_processors)))

# p_process_status = ConcurrentDict{DataPeriod, ConcurrentDict{Symbol, Bool}}()
# for period in periods
#     p_process_status[period] = ConcurrentDict{Symbol, Bool}(possible_p_steps .=> .!getproperty.(getproperty.(Ref(processing_config.p_processors), possible_p_steps), Ref(:enabled)))
# end



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
                            # check if run is a analysis run if switched on
                            if processing_config.analysis_runs_only && !is_lrun(l200, (period, run, :cal))
                                @warn "Run $run is not a analysis run"
                                continue
                            end

                            Threads.@spawn begin
                                # iterate through process steps
                                @info "Process run $run"
                                for process in process_steps
                                    @info "$process"
                                    flush(stdout)
                                    
                                    # check if process has dependencies
                                    if !processing_config.only_runs
                                        # get all dependencies of process from config
                                        dependencies = Symbol.(processing_config.processors[process].dependencies)
                                        # add all smaller ranks to list of dependencies and remove duplicates
                                        dependencies = unique(vcat([processing_config.p_possible_process_steps[1:findfirst(processing_config.p_possible_process_steps .== dep)] for dep in dependencies]...))
                                        # check if dependencies are met
                                        if !all([p_process_status[period][dep] for dep in dependencies])
                                            @warn "Dependencies not yet met for $process"
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
            p_process_steps =  processing_config.p_process_steps

            # process partitions 
            Threads.@spawn begin
                for period in periods

                    @info "Process partitions in $period"

                    Threads.@spawn begin
                        # iterate through process steps
                        for process in p_process_steps
                            @info "$process"

                            if !processing_config.only_partitions
                                # check if p process has dependencies
                                dependencies = Symbol.(processing_config.p_processors[process].dependencies)
                                # add all smaller ranks to list of dependencies and remove duplicates
                                dependencies = unique(vcat([processing_config.possible_process_steps[1:findfirst(processing_config.possible_process_steps .== dep)] for dep in dependencies]...))
                                if !all([all(values(process_status[period][dep])) for dep in dependencies])
                                    @warn "Dependencies not yet met for $process"
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
                            getfield(Main, process)(processing_config, l200, period,; kwargs...)
                            # update process status
                            p_process_status[period][process] = true
                        end
                    end
                end
            end
        end
    end
    @info "# Processing Done"
end
