# process parsed arguments for the main function
function get_argparse()
    settings = ArgParseSettings(prog="LEGEND Julia main data processing",
                            description="LEGEND Julia main data processing for data processing on single server machines with access to LEGEND data. Please check the config for all settings related to the data processing.",
                            commands_are_required = true,
                            version = "0.2",
                            add_version = true)
    @add_arg_table settings begin
        "--config", "-c"
            help = "path to config file"
            arg_type = String
            required = true
        "--reprocess"
            help = "reprocess all channels while deleting old data"
            action = :store_true
        "--only_runs"
            help = "process only period and runs ignoring partitions"
            action = :store_true
        "--only_partitions"
            help = "process only partitions ignoring periods and runs"
            action = :store_true
        "--analysis_runs_only"
            help = "process only channels that are marked as analysis runs"
            action = :store_true
        "--periods", "-p"
            help = "Periods to process"
            nargs = '+'
            arg_type = Int
            action = :append_arg
        "--runs", "-r"
            help = "Runs to process within periods"
            nargs = '+'
            arg_type = Int
            action = :append_arg
        "--partitions"
            help = "Analysis partitions to process"
            nargs = '+'
            arg_type = Int
            action = :append_arg
    end
    parse_args(settings)
end

function get_processingconfig()
    # read parsed arguments
    parsed_args = get_argparse()
    # read config
    processing_config = readprops(parsed_args["config"])
    # save parsed args for later
    processing_config.parsed_args = parsed_args
    # get environoment variables
    env_args_worker = Pair{String, String}[]
    worker_instantiate, worker_precompile = false, false
    for key in keys(processing_config.config.env_variables)
        ENV[String(key)] = processing_config.config.env_variables[key]
        push!(env_args_worker, Pair{String, String}(String(key), processing_config.config.env_variables[key]))
    end
    processing_config.env_args_worker = env_args_worker
    # check for precompile on the workers
    @everywhere begin
        worker_instantiate, worker_precompile = $processing_config.config.worker_instantiate, $processing_config.config.worker_precompile
        if worker_instantiate
            Pkg.instantiate()
        end
        if worker_precompile
            Pkg.precompile()
        end
    end
    # set debug flag
    if processing_config.config.debug
        ENV["JULIA_DEBUG"] = Main # enable debug
    end

    # check flags if only partitions or only runs should be processed
    processing_config.only_partitions = parsed_args["only_partitions"]
    processing_config.only_runs       = parsed_args["only_runs"]

    # check flag if only analysis runs should be processed
    processing_config.analysis_runs_only = ifelse(parsed_args["analysis_runs_only"], true, processing_config.processing.analysis_runs_only)
    if processing_config.analysis_runs_only @info "Process only analysis runs" end
    
    # get processing steps from config and sort by rank
    process_steps = Symbol.(keys(processing_config.processors))
    process_steps = process_steps[process_steps .!= :default]
    process_steps = sort(process_steps[[processing_config.processors[step].enabled for step in process_steps]], by = s -> processing_config.processors[s].rank)

    # if reprocess passed as global argument set reprocess flag for all processors
    if parsed_args["reprocess"]
        for process in process_steps
            processing_config.processors[process].reprocess = true
        end
    end

    processing_config.process_steps = process_steps

    # get processing steps for partition and sort by rank
    p_process_steps = Symbol.(keys(processing_config.p_processors))
    p_process_steps = p_process_steps[p_process_steps .!= :default]
    p_process_steps = sort(p_process_steps[[processing_config.p_processors[step].enabled for step in p_process_steps]], by = s -> processing_config.p_processors[s].rank)

    # if reprocess passed as global argument set reprocess flag for all processors
    if parsed_args["reprocess"]
        for process in p_process_steps
            processing_config.p_processors[process].reprocess = true
        end
    end

    processing_config.p_process_steps = p_process_steps

    # get runs and periods
    runs, periods = nothing, nothing
    if !(processing_config.only_partitions)
        runs, periods = get_runsandperiods(parsed_args, processing_config)
    end

    # get partitions
    partitions = nothing
    if !(processing_config.only_runs)
        partitions = get_partitions(parsed_args, processing_config)
    end

    return processing_config, runs, periods, partitions
end

function get_runsandperiods(parsed_args::Dict, processing_config::PropDict)
    # parse periods and runs from arguments, if not supported use config
    runs, periods = nothing, nothing
    if !isempty(parsed_args["runs"]) && isempty(parsed_args["periods"])
        @error "ArgumentError: Runs without periods are not supported"
        throw(ArgParseError("Runs without periods are not supported"))
    elseif !isempty(parsed_args["periods"]) && isempty(parsed_args["runs"])
        periods = [DataPeriod(p) for p in parsed_args["periods"][1]]
        @info "Process all runs in periods $(parsed_args["periods"][1])"
        runs = "all"
    elseif !isempty(parsed_args["periods"])
        periods = [DataPeriod(p) for p in parsed_args["periods"][1]]
        runs = [DataRun(r) for r in parsed_args["runs"][1]]
        @info "Process runs: $(parsed_args["runs"][1]) in periods: $(parsed_args["periods"][1])"
    end
    if processing_config.processing.periods == "all" && isnothing(periods)
        periods = search_disk(DataPeriod, l200.tier[:raw, :cal])
        @info "Process all periods on disk: $(string.(periods))"
    elseif isnothing(periods)
        periods = [DataPeriod(p) for p in processing_config.processing.periods]
        @info "Process periods: $(string.(periods))"
    end
    if processing_config.processing.runs == "all" && isnothing(runs)
        runs = "all"
        @info "Process all runs on disk for each period"
    elseif isnothing(runs)
        runs = [DataRun(r) for r in processing_config.processing.runs]
        @info "Process runs: $(string.(runs))"
    end

    return runs, periods
end

function get_partitions(parsed_args::Dict, processing_config::PropDict)
    # parse data_partitions from config
    partitions = [DataPartition(p) for p in processing_config.processing.partitions]
    if !isempty(parsed_args["partitions"])
        partitions = [DataPartition(p) for p in parsed_args["partitions"][1]]
        @info "Process partitions: $(parsed_args["partitions"][1])"
    end
    if partitions == "all"
        partitions = collect(keys(partitioninfo(l200)))
        @info "Process all partitions from partitioninfo: $(string.(partitions))"
    end
    return partitions
end

function get_proccessable_runs(runs, period)
    # select runs to process
    available_runs = search_disk(DataRun, l200.tier[:raw, :cal, period])
    processable_runs = runs
    if runs == "all"
        processable_runs = available_runs
    end

    # if runs has no data available skip
    for run in processable_runs
        if !(run in available_runs)
            @warn "Run $run not found in period $period"
            continue
        end
    end

    return [r for r in processable_runs if r in available_runs ]

end

function get_processable_partitions(partitions)
    # select partitions to process
    possible_partitions = collect(keys(partitioninfo(l200)))
    for partition in partitions
        if !(partition in possible_partitions)
            @warn "Partition $partition is not a valid data partition"
            continue
        end
    end
    return [p for p in partitions if p in possible_partitions]
end