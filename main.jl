#!/usr/bin/env -S /home/iwsatlas1/henkes/julia-1.9.0/bin/julia -t 1 --heap-size-hint=10G
# set julia traget to generic for similar compilecache in all workers
ENV["JULIA_CPU_TARGET"] = "generic"

# reading arguments
using ArgParse
settings = ArgParseSettings(prog="LEGEND Julia main data processing",
                            description="LEGEND Julia main data processing for data processing on single server machines with access to LEGEND data. Please check the config for all settings related to the data processing.",
                            commands_are_required = true,
                            version = "0.1",
                            add_version = true)
@add_arg_table settings begin
    "--config", "-c"
        help = "path to config file"
        arg_type = String
        required = true
    "--reprocess"
        help = "reprocess all channels while deleting old data"
        action = :store_true
    "--onlyruns"
        help = "process only period and runs ignoring partitions"
        action = :store_true
    "--onlypart"
        help = "process only partitions ignoring periods and runs"
        action = :store_true
    "--analysis"
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
parsed_args = parse_args(settings)

using PropDicts
import Pkg
processing_config = PropDict()
env_args_worker = Pair{String, String}[]
worker_instantiate, worker_precompile = false, false
try
    global processing_config = readprops(parsed_args["config"])
    ENV["LEGEND_DATA_CONFIG"] = processing_config.config.LEGEND_DATA_CONFIG
    if processing_config.config.debug
        ENV["JULIA_DEBUG"] = Main # enable debug
    end
    for key in keys(processing_config.config.env_variables)
        ENV[String(key)] = processing_config.config.env_variables[key]
        push!(env_args_worker, Pair{String, String}(String(key), processing_config.config.env_variables[key]))
    end
    Pkg.activate(processing_config.config.env)
    if processing_config.config.instantiate
        Pkg.instantiate()
        global worker_instantiate = true
    end
    if processing_config.config.precompile
        Pkg.precompile()
        global worker_precompile = true
    end
catch e
    @error "Could not setup config: $(parsed_args["config"])"
    rethrow(e)
end

@info "Using Julia $VERSION"
@info "Using Julia project $(dirname(Pkg.project().path))"
@info "Load LEGEND packages"

using LegendHDF5IO, LegendDSP, LegendSpecFits, LegendDataTypes, LegendDataManagement
using IntervalSets, PropertyFunctions, TypedTables, PropDicts, StatsBase
using Unitful, Formatting, LaTeXStrings, Printf, Measures, Dates
using Plots
using Distributed, ProgressMeter, TimerOutputs

using HDF5
using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked

# set logging to Terminallogger for Markdown output
using Logging: global_logger
using TerminalLoggers: TerminalLogger
global_logger(TerminalLogger())

# kill all workers at exist
function kill_sessions()
    @info "Kill all sessions"
    # kill all sessions
    rmprocs(workers()...)
    run(`pkill -u $(processing_config.config.user) -f worker`)
end
atexit(kill_sessions)

# check for precompile on the workers
@everywhere begin
    import Pkg
    worker_instantiate, worker_precompile = $worker_instantiate, $worker_precompile
    if worker_instantiate
        Pkg.instantiate()
    end
    if worker_precompile
        Pkg.precompile()
    end
end

# parse periods and runs from arguments, if not supported use config
runs, periods = nothing, nothing
if !isempty(parsed_args["runs"]) && isempty(parsed_args["periods"])
    @error "ArgumentError: Runs without periods are not supported"
    throw(ArgParseError("Runs without periods are not supported"))
elseif !isempty(parsed_args["periods"]) && isempty(parsed_args["runs"])
    periods = [DataPeriod(p) for p in parsed_args["periods"][1]]
    @info "Process all runs in periods $(parsed_args["periods"][1])"
    processing_config.processing.runs = "all"
elseif !isempty(parsed_args["periods"])
    periods = [DataPeriod(p) for p in parsed_args["periods"][1]]
    runs = [DataRun(r) for r in parsed_args["runs"][1]]
    @info "Process runs: $(parsed_args["runs"][1]) in periods: $(parsed_args["periods"][1])"
end

# parse data_partitions from config
partitions = processing_config.p_processing.partitions
if !isempty(parsed_args["partitions"])
    partitions = parsed_args["partitions"][1]
    @info "Process partitions: $(parsed_args["partitions"][1])"
end


# load metadata
@info "Loading Legend MetaData"
l200 = LegendData(:l200)

@info "Start Data processing"

# load all available processors
include(joinpath(@__DIR__,"utils.jl"))
include(joinpath(@__DIR__,"dsp/split_raw_by_energy.jl"))
include(joinpath(@__DIR__,"optimization/decay_time.jl"))
include(joinpath(@__DIR__,"optimization/filter_optimization.jl"))
include(joinpath(@__DIR__,"optimization/aoe_filter_optimization.jl"))
include(joinpath(@__DIR__,"dsp/dsp_cal.jl"))
include(joinpath(@__DIR__,"dsp/dsp_phy.jl"))
include(joinpath(@__DIR__,"cuts/cuts.jl"))
include(joinpath(@__DIR__,"energy/energy.jl"))
include(joinpath(@__DIR__,"energy/energy_ct.jl"))
include(joinpath(@__DIR__,"energy/energy_partition.jl"))
include(joinpath(@__DIR__,"aoe/aoe_cal.jl"))
include(joinpath(@__DIR__,"aoe/psd_cut_partition.jl"))
include(joinpath(@__DIR__,"sipm/dsp_sipm.jl"))
include(joinpath(@__DIR__,"hit/generate_hit_cal.jl"))

# check which periods to process
if isnothing(periods)
    try
        eval(Meta.parse(processing_config.processing.periods))
    catch e
        @error "Could not parse periods: $(processing_config.processing.periods)"
        rethrow(e)
    end
end

if !parsed_args["onlypart"]
    # get processing steps from config
    process_steps = Symbol.(keys(processing_config.processors))
    process_steps = process_steps[process_steps .!= :default]
    process_steps = sort(process_steps[[processing_config.processors[step].enabled for step in process_steps]], by = s -> processing_config.processors[s].rank)

    # process periods 
    for period in periods
        @info "Process period $period"
        # select runs to process
        available_runs = search_disk(DataRun, l200.tier[:raw, :cal, period])
        processed_runs = runs
        if processing_config.processing.runs == "all" && isnothing(runs)
            processed_runs = available_runs
        elseif isnothing(runs)
            try
                processed_runs = eval(Meta.parse(processing_config.processing.runs))
            catch e
                @error "Could not parse runs: $(processing_config.processing.runs)"
                rethrow(e)
            end
        end

        # process runs
        for run in processed_runs
            # if runs has no data available skip
            if !(run in available_runs)
                @warn "Run $run not found in period $period"
                continue
            end
            # check if run is a analysis run if switched on
            if parsed_args["analysis"]
                if l200.metadata.dataprod.config.analysis[Symbol(period)] != "all" && !(string(run) in l200.metadata.dataprod.config.analysis[Symbol(period)])
                    @warn "Run $run is not a analysis run"
                    continue
                end
            elseif processing_config.processing.analysis
                if l200.metadata.dataprod.config.analysis[Symbol(period)] != "all" && !(string(run) in l200.metadata.dataprod.config.analysis[Symbol(period)])
                    @warn "Run $run is not a analysis run"
                    continue
                end
            end
            # iterate through process steps
            @info "Process run $run"
            for process in process_steps
                @info "$process"
                # create workers
                if haskey(processing_config.processors[process], :n_workers)
                    create_workers(processing_config.processors[process].n_workers; env_args=env_args_worker)
                else
                    create_workers(processing_config.processors.default.n_workers)
                end
                @everywhere begin
                    using LegendHDF5IO, LegendDSP, LegendSpecFits, LegendDataTypes, LegendDataManagement
                    using IntervalSets, PropertyFunctions, TypedTables, PropDicts, StatsBase
                    using Unitful, Formatting, LaTeXStrings, Printf, Measures, Dates
                    using Plots
                    using Distributed, ProgressMeter, TimerOutputs
            
                    using HDF5
                    using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked
            
                    # set environment variables
                    ENV["LEGEND_DATA_CONFIG"] = "/home/iwsatlas1/henkes/l200/auto/config.json"
            
                    # select plot backend to GR
                    gr(margin=10mm, thickness_scaling=1.5, size=(1300, 900), dpi=600)
                    # free memory
                    GC.gc()
                end
                # get reprocess
                reprocess = false
                if parsed_args["reprocess"]
                    reprocess = true
                else
                    reprocess = processing_config.processors[process].reprocess
                end
                # run process
                if haskey(processing_config.processors[process], :timeout)
                    getfield(Main, process)(l200, period, run,; reprocess=reprocess, timeout=processing_config.processors[process].timeout)
                else
                    getfield(Main, process)(l200, period, run,; reprocess=reprocess)
                end
            end
        end
    end
end


if !parsed_args["onlyruns"]

    # get processing steps from config for partitions
    process_steps = Symbol.(keys(processing_config.p_processors))
    process_steps = process_steps[process_steps .!= :default]
    process_steps = sort(process_steps[[processing_config.p_processors[step].enabled for step in process_steps]], by = s -> processing_config.p_processors[s].rank)

    possible_partitions = collect(keys(data_partitions(l200)))

    # process periods 
    for partition in partitions
        
        if !(partition in possible_partitions)
            @warn "Partition $partition is not a valid data partition"
            continue
        end

        # iterate through process steps
        @info "Process partition $partition"
        for process in process_steps
            @info "$process"
            # create workers
            if haskey(processing_config.p_processors[process], :n_workers)
                create_workers(processing_config.p_processors[process].n_workers; env_args=env_args_worker)
            else
                create_workers(processing_config.p_processors.default.n_workers)
            end
            @everywhere begin
                using LegendHDF5IO, LegendDSP, LegendSpecFits, LegendDataTypes, LegendDataManagement
                using IntervalSets, PropertyFunctions, TypedTables, PropDicts, StatsBase
                using Unitful, Formatting, LaTeXStrings, Printf, Measures, Dates
                using Plots
                using Distributed, ProgressMeter, TimerOutputs
        
                using HDF5
                using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked
        
                # set environment variables
                ENV["LEGEND_DATA_CONFIG"] = "/home/iwsatlas1/henkes/l200/auto/config.json"
        
                # select plot backend to GR
                gr(margin=10mm, thickness_scaling=1.5, size=(1300, 900), dpi=600)
                # free memory
                GC.gc()
            end
            # get reprocess
            reprocess = false
            if parsed_args["reprocess"]
                reprocess = true
            else
                reprocess = processing_config.p_processors[process].reprocess
            end
            # run process
            if haskey(processing_config.p_processors[process], :timeout)
                getfield(Main, process)(l200, partition,; reprocess=reprocess, timeout=processing_config.p_processors[process].timeout)
            else
                getfield(Main, process)(l200, partition,; reprocess=reprocess)
            end
        end
    end
end