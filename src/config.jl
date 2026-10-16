# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

"""
    parse_commandline(args::AbstractVector{<:AbstractString})

Parse the command line options of the dataflow driver and return them as a
`Dict{String,Any}` keyed by the long option names. With `--help` or `--version`,
ArgParse prints the text and exits the process in a non-interactive session; in an
interactive session it returns `nothing`.

Options (see `juleana --help` for the full text):
- `--config`, `-c`: path of the processing config file. Without it, the
  [`Juleana.install_default_config`](@ref) file of the data production is used (copied
  from the config shipped with Juleana if the production has none), or `nothing` when
  `LEGEND_DATA_CONFIG` is not set (no data production is selected).
- `--periods`, `-p`: periods, each optionally with runs: `6` (all runs of p06), `6,1`
  (r001), `6,1-3` (r001 to r003), `6,1,4-6`. Each occurrence gives one vector of these
  strings, so `-p 3 4 -p 6,1` gives `[["3", "4"], ["6,1"]]`; see
  [`Juleana.parse_period_runs`](@ref).
- `--runs`, `-r`: run numbers for the periods given without runs, as one vector per
  occurrence.
- `--runmode`, `--rm`: `local` or `slurm`, replacing the config's run mode.
- `--dataset`: name of the dataset in the metadata `datasets/runlists` that selects the runs;
  `"default"` when not given.
- `--log_path`, `-o`: log directory; `""` when not given.
- Flags, `false` when not given: `--no-tui`, `--new-production`, `--reprocess`, `--only_runs` (`--or`),
  `--only_partitions` (`--op`), `--submit_jobs`, `--ignore_config`,
  `--analysis_runs_only`.

# Examples
```jldoctest
julia> args = Juleana.parse_commandline(["-c", "config.json", "-p", "3", "4", "--reprocess"]);

julia> args["periods"], args["reprocess"], args["only_runs"]
([["3", "4"]], true, false)
```
"""
function parse_commandline(args::AbstractVector{<:AbstractString})
    settings = ArgParseSettings(prog="LEGEND Julia main data processing",
                            description="LEGEND Julia main data processing for data processing on single server machines or via SLURM with access to LEGEND data. Please check the config for all settings related to the data processing.",
                            version = string(pkgversion(Juleana)),
                            add_version = true)
    @add_arg_table! settings begin
        "--config", "-c"
            help = "path to config file; default: config/processing_config.json in the data production, copied there from the config shipped with Juleana if missing"
            arg_type = String
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
        "--new-production", "--new_production"
            help = "open the terminal user interface on the creation of a new data production"
            dest_name = "new_production"
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
        "--dataset"
            help = "dataset of the run lists in the metadata (datasets/runlists) that selects the runs"
            arg_type = String
            default = "default"
        "--log_path", "-o"
            help = "path to store log files in"
            arg_type = String
            default = ""
        "--analysis_runs_only"
            help = "process only channels that are marked as analysis runs"
            action = :store_true
        "--periods", "-p"
            help = "periods to process, each optionally with runs: 6 (all runs), 6,1 (r001), 6,1-3, 6,1,4-6; repeatable"
            nargs = '+'
            arg_type = String
            action = :append_arg
        "--runs", "-r"
            help = "runs to process in the periods given without runs"
            nargs = '+'
            arg_type = Int
            action = :append_arg
    end
    parsed_args = parse_args(append!(String[], args), settings)
    !isnothing(parsed_args) && isnothing(parsed_args["config"]) && haskey(ENV, "LEGEND_DATA_CONFIG") &&
        (parsed_args["config"] = install_default_config())
    return parsed_args
end

"""
    Juleana.production_config_dir()

Return the path of the `config` folder of the data production: the folder `config` next
to the data config file named by the environment variable `LEGEND_DATA_CONFIG`, the
folder that `\$_` stands for in that file. The folder need not exist.

Throws an `ArgumentError` if `LEGEND_DATA_CONFIG` is not set, or names several files
in different folders.
"""
function production_config_dir()
    haskey(ENV, "LEGEND_DATA_CONFIG") ||
        throw(ArgumentError("production_config_dir: the environment variable LEGEND_DATA_CONFIG is not set"))
    # several files are separated by colons, as LegendDataManagement reads them
    dirs = unique(dirname.(abspath.(split(ENV["LEGEND_DATA_CONFIG"], r":(?!\\)"))))
    length(dirs) == 1 || throw(ArgumentError(
        "production_config_dir: the files of LEGEND_DATA_CONFIG are in several folders: $(join(dirs, ", "))"))
    return joinpath(only(dirs), "config")
end

"""
    Juleana.default_config_file()

Return the path of the default processing config file of the data production,
`processing_config.json` in the [`Juleana.production_config_dir`](@ref). The file need
not exist; see [`Juleana.install_default_config`](@ref).
"""
default_config_file() = joinpath(production_config_dir(), "processing_config.json")

"""
    Juleana.install_default_config()

Return the [`Juleana.default_config_file`](@ref). If the file does not exist, first
create the [`Juleana.production_config_dir`](@ref) and copy the
`config/processing_config.json` shipped with Juleana into it, logging the copy. An
existing file is never overwritten.
"""
function install_default_config()
    path = default_config_file()
    if !isfile(path)
        shipped = joinpath(pkgdir(Juleana), "config", "processing_config.json")
        cp(shipped, joinpath(mkpath(dirname(path)), basename(path)))
        @info "Copied the processing config shipped with Juleana ($shipped) to $path"
    end
    return path
end

"""
    Juleana.parse_period_runs(period_args, run_args)

Turn the `--periods` and `--runs` options of [`parse_commandline`](@ref) into
`(periods, runs)`. `period_args` and `run_args` are vectors with one vector per
occurrence of the option: strings like `"6"`, `"6,1"`, `"6,1-3"` or `"6,1,4-6"` for
periods, and run numbers for runs.

`periods` is a `Vector{DataPeriod}` in the given order, or `nothing` without
`--periods`. `runs` is
- a `Dict{DataPeriod,Vector{DataRun}}` with the sorted runs of each period given with
  runs, when any is; the other periods keep all their runs;
- else the `--runs` numbers as a `Vector{DataRun}` for all given periods;
- else `nothing`.

Throws an `ArgumentError` for a malformed string, a period given twice, a run range
that ends before it starts, and for `--runs` together with periods given with runs.

# Examples
```jldoctest
julia> periods, runs = Juleana.parse_period_runs([["3", "6,1-3"], ["7,2,5"]], []);

julia> string.(periods), sort([string(p) => string.(r) for (p, r) in runs])
(["p03", "p06", "p07"], ["p06" => ["r001", "r002", "r003"], "p07" => ["r002", "r005"]])
```
"""
function parse_period_runs(period_args, run_args)
    periods = DataPeriod[]
    period_runs = Dict{DataPeriod,Vector{DataRun}}()
    function number(text, spec)
        n = tryparse(Int, strip(text))
        isnothing(n) && throw(ArgumentError("invalid period or run `$text` in `-p $spec`"))
        return n
    end
    for spec in Iterators.flatten(period_args)
        parts = split(spec, ',')
        period = DataPeriod(number(first(parts), spec))
        period in periods && throw(ArgumentError("period $period is given more than once"))
        push!(periods, period)
        length(parts) > 1 || continue
        runs = Int[]
        for part in parts[2:end]
            bounds = number.(split(part, '-'; limit = 2), spec)
            first(bounds) <= last(bounds) || throw(ArgumentError("run range `$part` in `-p $spec` ends before it starts"))
            append!(runs, first(bounds):last(bounds))
        end
        period_runs[period] = DataRun.(sort!(unique!(runs)))
    end
    global_runs = DataRun[DataRun(r) for r in Iterators.flatten(run_args)]
    !isempty(period_runs) && !isempty(global_runs) &&
        throw(ArgumentError("`-r` cannot be combined with periods given with runs (`-p 6,1`)"))
    runs = !isempty(period_runs) ? period_runs : isempty(global_runs) ? nothing : global_runs
    return isempty(periods) ? nothing : periods, runs
end

"""
    setup_processing(parsed_args::AbstractDict)

Build the processing setup from the output of [`parse_commandline`](@ref) and return
`(l200, processing_config, periods)`.

Reads the config file, applies the command line overrides, sets `ENV` from the
config's `env_variables` (before the metadata is loaded), builds `LegendData(:l200)` for the `--dataset`,
and creates the log directory: `--log_path` when given, otherwise a directory in the `jllog` tier
named by the current UTC time (`yyyy-mm-ddTHH:MM:SSZ`). `periods` are the selected periods that are available
on disk, or all available periods when the config selects all.
"""
function setup_processing(parsed_args::AbstractDict)
    config_dict = readlprops(parsed_args["config"])
    # command line overrides; per-period runs are applied to the session, not the config
    periods, runs = parse_period_runs(parsed_args["periods"], parsed_args["runs"])
    cli = (;
        runmode = parsed_args["runmode"],
        submit_jobs = parsed_args["submit_jobs"],
        analysis_runs_only = parsed_args["analysis_runs_only"],
        only_partitions = parsed_args["only_partitions"],
        only_runs = parsed_args["only_runs"],
        ignore_config = parsed_args["ignore_config"],
        reprocess = parsed_args["reprocess"],
        periods,
        runs = runs isa AbstractDict ? nothing : runs
    )
    processing_config = ProcessingConfig(config_dict; cli...)
    # the environment variables must be set before the metadata is loaded
    for (key, value) in processing_config.env_variables
        ENV[key] = value
    end

    @info "Loading Legend MetaData"
    dataset = Symbol(parsed_args["dataset"])
    l200 = LegendData(:l200; dataset)
    dataset == :default || haskey(l200.metadata.datasets.runlists, dataset) ||
        throw(ArgumentError("dataset $dataset is not in the metadata datasets/runlists"))

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
    if runs isa AbstractDict
        @info "Process runs: " * join(("$p: $(join(string.(r), ", "))" for (p, r) in sort!(collect(runs); by = first)), "; ")
    else
        runs = processing_config.runs
        @info isnothing(runs) ? "Process all runs on disk for each period" : "Process runs: $(string.(runs))"
    end

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

"""
    Juleana.available_periods(l200::LegendData)
    Juleana.available_runs(l200::LegendData, period::DataPeriod)

Return the periods, or the runs of `period`, that are on disk (see `find_data_tier`)
and in the `runinfo` of `l200`, which holds the runs of the dataset of `l200`. A period
is available if it has an available run.
"""
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
    rinfo = runinfo(l200)
    listed = Set(rinfo.run[rinfo.period .== period])
    return filter(in(listed), search_disk(DataRun, l200.tier[tc..., period]))
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

# Runs given per period; a period without an entry keeps all its runs.
processable_runs(l200::LegendData, period::DataPeriod, runs::AbstractDict{DataPeriod}) =
    processable_runs(l200, period, get(runs, period, nothing))


# Return `(periods, run_status, partition_status)`: the given periods that have
# processable runs, and the completion flags of every step for them. The status of a
# step starts as finished unless the step is in `run_steps` or `partition_steps`, so
# only the selected steps are waited for. `runs` is `nothing` (all runs), a vector of
# runs for every period, or a dict of runs per period (other periods keep all runs).
function setup_dependency_graph(l200::LegendData, processing_config::ProcessingConfig, periods::AbstractVector{DataPeriod},
        runs::Union{AbstractVector{DataRun}, AbstractDict{DataPeriod}, Nothing}, run_steps::AbstractVector{Symbol}, partition_steps::AbstractVector{Symbol})
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
