function menu()        
    # main menu options
    options = ["Execute processors", "Reload processors", "Select periods", "Reload processing config", "Reload dependency graph", "Submit workers", "Exit"]
    # main menu
    menu = RadioMenu(options)
    choice = request("Select action:", menu)
    
    # reload all processors from files
    if choice == 4
        global l200, processing_config, runs, periods
        l200, processing_config, runs, periods = get_processingconfig()
        @info "Reloaded processing config"
    # redefine periods per user choice
    elseif choice == 3
        global periods
        possible_periods = search_disk(DataPeriod, l200.tier[:raw, :cal])
        periods_menu = MultiSelectMenu(string.(possible_periods); selected=eachindex(possible_periods)[map(x -> x in periods, possible_periods)])
        periods = possible_periods[collect(request("Select periods to be executed:", periods_menu))]
        @info "Selected periods: $periods"
    # reload processors from all processor files
    elseif choice == 2
        r = include.(filter(contains(r".jl$"), readdir(joinpath(dirname(@__DIR__), "processors/"); join=true)))
        @info "Reloaded processors: $r"
    # reload dependency graph
    elseif choice == 5
        global process_status, p_process_status
        process_status, p_process_status = setup_dependency_graph(processing_config, periods, runs)
        @info "Reloaded dependency graph"
    # add workers according to slurm settings
    elseif choice == 6
        @async runworkers(runmode)
        @info "Submitted workers"
    # execute processing steps
    elseif choice == 1
        execute_processors()
    end
end

function execute_processors()
    # create menus for processing steps
    steps_menu = MultiSelectMenu(String.(processing_config.possible_process_steps))
    p_steps_menu = MultiSelectMenu(String.(processing_config.p_possible_process_steps))
    additional_args = ["reprocess", "check_dependencies"]
    additional_args_menu = MultiSelectMenu(additional_args)

    # processing steps menu to select and deselect
    process_steps = processing_config.possible_process_steps[collect(request("Select processing steps to be executed:", steps_menu))]
    process_steps = sort(process_steps, by = s -> processing_config.processors[s].rank)
    println()
    println()
    p_process_steps = processing_config.p_possible_process_steps[collect(request("Select partition processing steps to be executed:", p_steps_menu))]
    p_process_steps = sort(p_process_steps, by = s -> processing_config.p_processors[s].rank)
    println()
    println()
    additional_args = additional_args[collect(request("Select additional args:", additional_args_menu))]
    println()
    println()
    
    # execute steps one after each other without period and run parallelization
    if isempty(process_steps) && isempty(p_process_steps)
        @warn "No processing steps selected"
        return
    else
        @sync begin

            if !isempty(process_steps)
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
                                        if "check_dependencies" in additional_args
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

                                        # run process
                                        kwargs = NamedTuple([(k, v) for (k, v) in pairs(processing_config.processors[process].kwargs)])
                                        if "reprocess" in additional_args
                                            kwargs = merge(kwargs, (reprocess = true, ))
                                        end
                                        getfield(Main, process)(processing_config, l200, period, run,; kwargs...)
                                        flush(stdout)

                                        # update process status
                                        process_status[period][process][run] = true

                                        @info "Finished $period-$run $process"
                                    end
                                end
                            end
                        end
                    end
                end
            end

            if !isempty(p_process_steps)
                # process partitions 
                Threads.@spawn begin
                    for period in periods

                        @info "Process partitions in $period"

                        Threads.@spawn begin
                            # iterate through process steps
                            for process in p_process_steps
                                @info "$process"

                                if "check_dependencies" in additional_args
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
                                if "reprocess" in additional_args
                                    kwargs = merge(kwargs, (reprocess = true, ))
                                end
                                # process partitions
                                has_lower_period_depedency = getfield(Main, process)(processing_config, l200, period,; kwargs...)
                                
                                # if process finished but depends on lower period dependency wait till met
                                if has_lower_period_depedency && "check_dependencies" in additional_args
                                    if !p_process_status[DataPeriod(period.no - 1)][process]
                                        @warn "Processed $period $process but depends on $(DataPeriod(period.no - 1)) --> wait"
                                    end
                                    while !p_process_status[DataPeriod(period.no - 1)][process]
                                        sleep(10)
                                    end
                                end
                                # update process status
                                p_process_status[period][process] = true

                                @info "Finished $period $process"
                            end
                        end
                    end
                end
            end
        end
    end
end