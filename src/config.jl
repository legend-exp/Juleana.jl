# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

"""
    parse_commandline(args::AbstractVector{<:AbstractString})

Parse the command line options of the dataflow driver and return them as a
`Dict{String,Any}` keyed by the long option names. With `--help` or `--version`,
ArgParse prints the text and exits the process in a non-interactive session; in an
interactive session it returns `nothing`.

Options (see `juleana --help` for the full text):
- `--config`, `-c` (required): path of the processing config file.
- `--periods`, `-p` and `--runs`, `-r`: period and run numbers. Each occurrence gives
  one vector, so `-p 3 4 -p 6` gives `[[3, 4], [6]]`.
- `--runmode`, `--rm`: `local` or `slurm`, replacing the config's run mode.
- `--log_path`, `-o`: log directory; `""` when not given.
- Flags, `false` when not given: `--no-tui`, `--reprocess`, `--only_runs` (`--or`),
  `--only_partitions` (`--op`), `--submit_jobs`, `--ignore_config`,
  `--analysis_runs_only`.

# Examples
```jldoctest
julia> args = Juleana.parse_commandline(["-c", "config.json", "-p", "3", "4", "--reprocess"]);

julia> args["periods"], args["reprocess"], args["only_runs"]
([[3, 4]], true, false)
```
"""
function parse_commandline(args::AbstractVector{<:AbstractString})
    settings = ArgParseSettings(prog="LEGEND Julia main data processing",
                            description="LEGEND Julia main data processing for data processing on single server machines or via SLURM with access to LEGEND data. Please check the config for all settings related to the data processing.",
                            version = string(pkgversion(Juleana)),
                            add_version = true)
    @add_arg_table! settings begin
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
        "--no-tui", "--no_tui"
            help = "run all enabled processors without the terminal user interface and exit"
            dest_name = "no_tui"
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
    return parse_args(append!(String[], args), settings)
end

"""
    setup_processing(parsed_args::AbstractDict)

Build the processing setup from the output of [`parse_commandline`](@ref) and return
`(l200, processing_config, periods)`.

Reads the config file, applies the command line overrides, sets `ENV` from the
config's `env_variables` (before the metadata is loaded), builds `LegendData(:l200)`,
and creates the log directory: `--log_path` when given, otherwise a directory in the `jllog` tier
named by the current UTC time (`yyyy-mm-ddTHH:MM:SSZ`). `periods` are the selected periods that are available
on disk, or all available periods when the config selects all.
"""
function setup_processing(parsed_args::AbstractDict)
    config_dict = readlprops(parsed_args["config"])
    # command line overrides; repeated `--periods`/`--runs` options are concatenated
    cli = (;
        runmode = parsed_args["runmode"],
        submit_jobs = parsed_args["submit_jobs"],
        analysis_runs_only = parsed_args["analysis_runs_only"],
        only_partitions = parsed_args["only_partitions"],
        only_runs = parsed_args["only_runs"],
        ignore_config = parsed_args["ignore_config"],
        reprocess = parsed_args["reprocess"],
        periods = isempty(parsed_args["periods"]) ? nothing : reduce(vcat, parsed_args["periods"]),
        runs = isempty(parsed_args["runs"]) ? nothing : reduce(vcat, parsed_args["runs"])
    )
    processing_config = ProcessingConfig(config_dict; cli...)
    # the environment variables must be set before the metadata is loaded
    for (key, value) in processing_config.env_variables
        ENV[key] = value
    end

    @info "Loading Legend MetaData"
    l200 = LegendData(:l200)

    log_path = mkpath(isempty(parsed_args["log_path"]) ? joinpath(l200.tier[:jllog], utc_timestamp()) : parsed_args["log_path"])
    processing_config = ProcessingConfig(config_dict; cli..., log_path)
    @info "Log path: $log_path"

    processing_config.analysis_runs_only && @info "Process only analysis runs"
    processing_config.only_partitions && @info "Process only partitions"
    processing_config.only_runs && @info "Process only runs"
    @info "Runmode: $(processing_config.runmode)"
    processing_config.submit_jobs && @info "Will submit $(processing_config.runmode) jobs"
    parsed_args["reprocess"] && @info "Reprocess all processors"

    # restrict the selected periods to those available on disk
    on_disk = available_periods(l200)
    periods = if isnothing(processing_config.periods)
        on_disk
    else
        filter(in(on_disk), processing_config.periods)
    end
    @info "Process periods: $(string.(periods))"
    runs = processing_config.runs
    @info isnothing(runs) ? "Process all runs on disk for each period" : "Process runs: $(string.(runs))"

    return l200, processing_config, periods
end

"""
    find_data_tier(l200::LegendData, keys...)

Return the first `(tier, category)` among the `raw`, `jldsp` and `jlevt` tiers and the
`cal` and `phy` categories whose directory `l200.tier[tier, category, keys...]` exists,
or `nothing` if none does.
"""
function find_data_tier(l200::LegendData, keys...)
    for t in (:raw, :jldsp, :jlevt), c in (:cal, :phy)
        ispath(l200.tier[t, c, keys...]) && return (t, c)
    end
    return nothing
end

function available_periods(l200::LegendData)
    tc = find_data_tier(l200)
    possible_periods = if isnothing(tc)
        @warn "No `DataPeriod` found in `raw`, `jldsp` or `jlevt` for either `cal` or `phy`"
        DataPeriod[]
    else
        search_disk(DataPeriod, l200.tier[tc...])
    end
    # filter out periods that are not available on disk
    available_runs_dict = Dict{DataPeriod, Vector{DataRun}}(possible_periods .=> available_runs.(Ref(l200), possible_periods))
    filter!(p -> !isempty(available_runs_dict[p]), possible_periods)
    possible_periods
end

function available_runs(l200::LegendData, period::DataPeriod)
    tc = find_data_tier(l200, period)
    if isnothing(tc)
        @warn "No `DataRun` found for period $period in `raw`, `jldsp` or `jlevt` for either `cal` or `phy`"
        return DataRun[]
    end
    search_disk(DataRun, l200.tier[tc..., period])
end

# `runs === nothing` selects all runs of `period` available on disk
function processable_runs(l200::LegendData, period::DataPeriod, runs::Union{AbstractVector{DataRun}, Nothing})
    on_disk = available_runs(l200, period)
    isnothing(runs) && return on_disk
    for run in runs
        run in on_disk || @warn "Run $run not found in period $period"
    end
    return DataRun[r for r in runs if r in on_disk]
end


# Return `(periods, run_status, partition_status)`: the given periods that have
# processable runs, and the completion flags of every step for them. The status of a
# step starts as finished unless the step is in `run_steps` or `partition_steps`, so
# only the selected steps are waited for.
function setup_dependency_graph(l200::LegendData, processing_config::ProcessingConfig, periods::AbstractVector{DataPeriod},
        runs::Union{AbstractVector{DataRun}, Nothing}, run_steps::AbstractVector{Symbol}, partition_steps::AbstractVector{Symbol})
    # get all possible steps
    # `run_steps`/`partition_steps` are local names here, so read the step lists from the tables.
    possible_steps = _sorted_steps(processing_config.processors, false)
    # generate process status with all possible steps for all possible runs in all periods
    run_status = RunStatus()

    # check if each period contains any runs at all
    processable_runs_dict = Dict{DataPeriod, Vector{DataRun}}(periods .=> processable_runs.(Ref(l200), periods, Ref(runs)))
    periods = filter(p -> !isempty(processable_runs_dict[p]), periods)

    # fill
    for period in periods
        # get all processable runs
        period_runs = processable_runs_dict[period]
        run_status[period] = ConcurrentDict{Symbol, ConcurrentDict{DataRun, Bool}}([step => ConcurrentDict{DataRun, Bool}(period_runs .=> !(step in run_steps)) for step in possible_steps])
    end

    # get all possible steps for partition processing
    possible_p_steps = _sorted_steps(processing_config.p_processors, false)
    # generate process status with all possible steps for all possible runs in all periods
    partition_status = PartitionStatus()
    for period in periods
        partition_status[period] = ConcurrentDict{Symbol, Bool}([step => !(step in partition_steps) for step in possible_p_steps])
    end

    return periods, run_status, partition_status
end
