# set environment variables
ENV["JULIA_DEBUG"] = Main # enable debug
ENV["JULIA_CPU_TARGET"] = "generic" # enable AVX2
ENV["QT_QPA_PLATFORM"] = "xcb" # enable qt
ENV["GKSwstype"] = "100" # disable cannot connect to localhost display warnings in parallel processing
ENV["LEGEND_DATA_CONFIG"] = "/home/iwsatlas1/henkes/l200/auto/config.json"

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
    "--reprocess", "-r"
        help = "reprocess all channels while deleting old data"
        action = :store_true
        required = false
    "--periods", "-p"
        help = "Periods to process"
        nargs = "+"
        action = :append_arg
    "--runs", "-r"
        help = "Runs to process within periods"
        nargs = "+"
        action = :append_arg
end

@info "Using Julia $VERSION"
@info "Using Julia project $(dirname(Pkg.project().path))"
@info "Load "

using LegendHDF5IO, LegendDSP, LegendSpecFits, LegendDataTypes, LegendDataManagement
using IntervalSets, PropertyFunctions, TypedTables, PropDicts, StatsBase
using Unitful, Formatting, LaTeXStrings, Printf, Measures, Dates
using Plots
using Distributed, ProgressMeter, TimerOutputs

using HDF5
using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked

# kill all workers at exist
function kill_sessions()
    @info "Kill all sessions"
    # kill all sessions
    rmprocs(workers()...)
    run(`pkill -u henkes -f worker`)
end
atexit(kill_sessions)

# select plot backend
# gr(margin=10mm, thickness_scaling=1.5, size=(1300, 900), dpi=600)

@info "Loading Legend MetaData"
l200 = LegendData(:l200)

@info "Start Data processing"

include(joinpath(@__DIR__,"utils.jl"))
include(joinpath(@__DIR__,"dsp/split_raw_by_energy.jl"))
include(joinpath(@__DIR__,"optimization/decay_time.jl"))
include(joinpath(@__DIR__,"optimization/filter_optimization.jl"))
include(joinpath(@__DIR__,"optimization/aoe_filter_optimization.jl"))
include(joinpath(@__DIR__,"dsp/dsp.jl"))
include(joinpath(@__DIR__,"cuts/cuts.jl"))
include(joinpath(@__DIR__,"energy/dev_energy.jl"))

# reprocess everything or not
reprocess = false

# process steps
# process_steps = [:process_peak_split, :process_decay_time, :process_filter_optimization, :process_aoe_optimization, :process_dsp, :process_cuts, :process_energy, :process_aoe]
# process_steps = [:process_peak_split, :process_decay_time, :process_filter_optimization, :process_aoe_optimization, :process_dsp]
# process_steps = [:process_energy_calibration]

# select periods to process
# periods = [DataPeriod(i) for i in 6:7]
# periods = [DataPeriod(6)]
# periods = [DataPeriod(4)]
# periods = [DataPeriod(3)]

# process periods 
for period in periods
    @info "Process period $period"
    # select runs to process
    runs = search_disk(DataRun, l200.tier[:raw, :cal, period])
    runs = [r for r in runs if r.no == 1]
    # runs = [DataRun(2)]
    @info "Found runs $(string.(runs))"
    # process runs
    for run in runs
        @info "Process run $run"
        
        for process in process_steps
            @info "$process"
            # create workers
            create_workers(80)
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
            # run process
            getfield(Main, process)(l200, period, run,; reprocess=reprocess)
        end
    end
end