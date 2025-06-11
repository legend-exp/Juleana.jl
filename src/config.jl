function getboolkwarg(processing_config::PropDict, parsed_args::Dict, key::String; section::Symbol=:processing)
    if parsed_args["ignore_config"]
        parsed_args[key]
    elseif parsed_args[key]
        true
    else
        get(processing_config[section], Symbol(key), true)
    end
end

# process parsed arguments for the main function
function get_argparse()
    settings = ArgParseSettings(prog="LEGEND Julia main data processing",
                            description="LEGEND Julia main data processing for data processing on single server machines or via SLURM with access to LEGEND data. Please check the config for all settings related to the data processing.",
                            commands_are_required = true,
                            version = "1.0",
                            add_version = true)
    @add_arg_table settings begin
        "--config", "-c"
            help = "path to config file"
            arg_type = String
            required = true
        "--reprocess"
            help = "reprocess all channels while deleting old data"
            action = :store_true
        "--only_runs", "--or"
            help = "process only period and runs ignoring partitions"
            dest_name = "only_runs"
            action = :store_true
        "--only_partitions", "--op"
            help = "process only partitions ignoring periods and runs"
            dest_name = "only_partitions"
            action = :store_true
        "--submit_jobs"
            help = "submit slurm jobs to the selected run mode"
            action = :store_true
        "--runmode", "--rm"
            help = "run mode to use for processing"
            dest_name = "runmode"
            arg_type = String
        "--ignore_config"
            help = "ignore all settings and config and only take command line arguments"
            action = :store_true
        "--log_path", "-o"
            help = "path to store log files in"
            arg_type = String
            default = ""
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
    env_args_worker = Dict{String, String}(string.(keys(processing_config.config.env_variables)) .=> string.(values(processing_config.config.env_variables)))
    for key in keys(processing_config.config.env_variables)
        ENV[String(key)] = processing_config.config.env_variables[key]
    end
    processing_config.env_args_worker = (env_args_worker, )
    
    # get remote workers
    processing_config.config.remote_workers = [Tuple(p) for p in get(processing_config.processing, :remote_workers, [])]

    # load metadata
    @info "Loading Legend MetaData"
    l200 = LegendData(:l200)

    # get log path
    if isempty(parsed_args["log_path"])
        processing_config.processing.log_path = mkpath(joinpath(l200.tier[:jllog], string(Dates.now())))
    else
        processing_config.processing.log_path = mkpath(parsed_args["log_path"])
    end
    @info "Log path: $(processing_config.processing.log_path)"

    # check flags if only partitions or only runs should be processed, if slurm jobs should be submitted or only analysis runs should be processed
    processing_config.analysis_runs_only = getboolkwarg(processing_config, parsed_args, "analysis_runs_only")
    if processing_config.analysis_runs_only @info "Process only analysis runs" end
    processing_config.only_partitions    = getboolkwarg(processing_config, parsed_args, "only_partitions")
    if processing_config.only_partitions @info "Process only partitions" end
    processing_config.only_runs          = getboolkwarg(processing_config, parsed_args, "only_runs")
    if processing_config.only_runs @info "Process only runs" end

    if processing_config.only_partitions && processing_config.only_runs
        throw(ArgumentError("Only one of `only_partitions` or `only_runs` can be set"))
    end

    # get runmode and runmode flags
    processing_config.runmode = parsed_args["runmode"]
    if isnothing(processing_config.runmode)
        processing_config.runmode = get(processing_config.config, :runmode, "")
    end
    if !(processing_config.runmode in ["local", "slurm"])
        @error "Runmode $(processing_config.runmode) not supported"
        throw(ArgumentError("Runmode $(processing_config.runmode) not supported"))
    end
    @info "Runmode: $(processing_config.runmode)"
    processing_config.submit_jobs       = getboolkwarg(processing_config, parsed_args, "submit_jobs"; section=:config)
    if processing_config.submit_jobs @info "Will submit $(processing_config.runmode) jobs" end
    
    # get processing steps from config and sort by rank
    possible_process_steps = Symbol.(keys(processing_config.processors))
    possible_process_steps = possible_process_steps[possible_process_steps .!= :default]
    possible_process_steps = sort(possible_process_steps, by = s -> processing_config.processors[s].rank)

    # if reprocess passed as global argument set reprocess flag for all processors
    if parsed_args["reprocess"]
        @info "Reprocess all processors"
        for process in possible_process_steps
            processing_config.processors[process].reprocess = true
        end
    end
    processing_config.possible_process_steps = possible_process_steps
    processing_config.process_steps = possible_process_steps[[processing_config.processors[step].enabled for step in possible_process_steps]]

    # get processing steps for partition and sort by rank
    p_possible_process_steps = Symbol.(keys(processing_config.p_processors))
    p_possible_process_steps = p_possible_process_steps[p_possible_process_steps .!= :default]
    p_possible_process_steps = sort(p_possible_process_steps, by = s -> processing_config.p_processors[s].rank)

    # if reprocess passed as global argument set reprocess flag for all processors
    if parsed_args["reprocess"]
        for process in p_possible_process_steps
            processing_config.p_processors[process].reprocess = true
        end
    end
    processing_config.p_possible_process_steps = p_possible_process_steps
    processing_config.p_process_steps = p_possible_process_steps[[processing_config.p_processors[step].enabled for step in p_possible_process_steps]]

    if isempty(processing_config.process_steps) && isempty(processing_config.p_process_steps) 
        throw(ArgumentError("No processing steps enabled"))
    end

    # get runs and periods
    runs, periods = nothing, nothing
    runs, periods = get_runsandperiods(parsed_args, processing_config, l200)

    return l200, processing_config, runs, periods
end

function get_runsandperiods(parsed_args::Dict, processing_config::PropDict, l200::LegendData)
    # parse periods and runs from arguments, if not supported use config
    runs, periods = missing, DataPeriod[]
    if !isempty(parsed_args["runs"]) && isempty(parsed_args["periods"])
        @error "ArgumentError: Runs without periods are not supported"
        throw(ArgParseError("Runs without periods are not supported"))
    elseif !isempty(parsed_args["periods"]) && isempty(parsed_args["runs"])
        periods = DataPeriod.(parsed_args["periods"][1])
        @info "Process all runs in periods $(parsed_args["periods"][1])"
        runs = "all"
    elseif !isempty(parsed_args["periods"])
        periods = DataPeriod.(parsed_args["periods"][1])
        runs = DataRun.(parsed_args["runs"][1])
        @info "Process runs: $(parsed_args["runs"][1]) in periods: $(parsed_args["periods"][1])"
    end


    if processing_config.processing.periods == "all" && isempty(periods)
        periods = search_disk(DataPeriod, l200.tier[:raw, :cal])
        @info "Process all periods on disk: $(string.(periods))"
    elseif isempty(periods)
        periods = DataPeriod.(processing_config.processing.periods)
        @info "Process periods: $(string.(periods))"
    end
    if processing_config.processing.runs == "all" && ismissing(runs)
        runs = "all"
        @info "Process all runs on disk for each period"
    elseif ismissing(runs)
        runs = DataRun.(processing_config.processing.runs)
        @info "Process runs: $(string.(runs))"
    end

    # filter out periods that are not available on disk
    filter!(in(get_available_periods(l200)), periods)
    
    return runs, periods
end

function get_available_periods(l200::LegendData)
    tiers = [:raw, :jldsp, :jlevt]
    categories = [:cal, :phy]
    tier, cat = nothing, nothing
    for t in tiers
        for c in categories
            if ispath(l200.tier[t, c])
                tier = t
                cat = c
                break
            end
        end
        if !isnothing(tier)
            break
        end
    end
    possible_periods = if isnothing(tier) || isnothing(cat)
        @warn "No `DataPeriod` found for in `raw`, `jldsp` or `jlevt` neither for `cal` nor `phy`"
        DataPeriod[]
    else
        search_disk(DataPeriod, l200.tier[tier, cat])
    end
    # filter out periods that are not available on disk
    available_runs_dict = Dict{DataPeriod, Vector{DataRun}}(possible_periods .=> get_available_runs.(Ref(l200), possible_periods))
    filter!(p -> !isempty(available_runs_dict[p]), possible_periods)
    possible_periods
end

function get_available_runs(l200::LegendData, period::DataPeriod)
    # select runs to process
    tiers = [:raw, :jldsp, :jlevt]
    categories = [:cal, :phy]
    tier, cat = nothing, nothing
    for t in tiers
        for c in categories
            if ispath(l200.tier[t, c, period])
                tier = t
                cat = c
                break
            end
        end
        if !isnothing(tier)
            break
        end
    end
    available_runs = if isnothing(tier) || isnothing(cat)
        @warn "No `DataRun` found for period $period in `raw`, `jldsp` or `jlevt` neither for `cal` nor `phy`"
        DataRun[]
    else
        search_disk(DataRun, l200.tier[tier, cat, period])
    end
    available_runs
end

function get_proccessable_runs(l200::LegendData, period::DataPeriod, runs::Union{Vector{DataRun}, String})
    available_runs = get_available_runs(l200, period)
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

    return DataRun.([r for r in processable_runs if r in available_runs])
end


function setup_dependency_graph(l200::LegendData, processing_config::PropDict, periods::Vector{DataPeriod}, runs::Union{Vector{DataRun}, String})
    # get all possible steps
    possible_steps = filter!(x -> x != :default, Symbol.(keys(processing_config.processors)))
    # generate process status with all possible steps for all possible runs in all periods
    process_status = ConcurrentDict{DataPeriod, ConcurrentDict{Symbol, ConcurrentDict{DataRun, Bool}}}()

    # check if each period contains any runs at all
    processable_runs_dict = Dict{DataPeriod, Vector{DataRun}}(periods .=> get_proccessable_runs.(Ref(l200), periods, Ref(runs)))
    filter!(p -> !isempty(processable_runs_dict[p]), periods)
    
    # fill
    for period in periods
        # get all processable runs
        processable_runs = processable_runs_dict[period]
        process_status[period] = ConcurrentDict{Symbol, ConcurrentDict{DataRun, Bool}}(possible_steps .=> [ConcurrentDict{DataRun, Bool}(processable_runs .=> Ref(p)) for p in .!getproperty.(getproperty.(Ref(processing_config.processors), possible_steps), Ref(:enabled))])
    end

    # get all possible steps for partition processing
    possible_p_steps = filter!(x -> x != :default, Symbol.(keys(processing_config.p_processors)))
    # generate process status with all possible steps for all possible runs in all periods
    p_process_status = ConcurrentDict{DataPeriod, ConcurrentDict{Symbol, Bool}}()
    for period in periods
        p_process_status[period] = ConcurrentDict{Symbol, Bool}(possible_p_steps .=> .!getproperty.(getproperty.(Ref(processing_config.p_processors), possible_p_steps), Ref(:enabled)))
    end

    return process_status, p_process_status
end