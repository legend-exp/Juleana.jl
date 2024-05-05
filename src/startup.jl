using LegendDataManagement
using ParallelProcessingTools

ParallelProcessingTools.@always_everywhere begin
    ParallelProcessingTools.pinthreads_auto()
    if !haskey(ENV, "LEGEND_DEBUG")
        @warn "No debug flag set"
    else
        if ENV["LEGEND_DEBUG"] == "true"
            ENV["JULIA_DEBUG"] = Main # enable debug
        end
    end

    # load packages
    using LegendHDF5IO, LegendDSP, LegendSpecFits, LegendDataTypes, LegendDataManagement, LegendDataManagement.LDMUtils
    using IntervalSets, PropertyFunctions, TypedTables, PropDicts, StatsBase
    using Unitful, Formatting, LaTeXStrings, Printf, Measures, Dates, Measurements
    using Measurements: value as mvalue
    using Measurements: uncertainty as muncert
    using Plots
    using Distributed, ProgressMeter, TimerOutputs
    using ParallelProcessingTools

    using HDF5
    using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked
    using Base.Iterators, StructArrays

    # select plot backend to GR
    gr(margin=10mm, thickness_scaling=1.5, size=(1300, 900), dpi=600)

    # set logging to Terminallogger for Markdown output
    using Logging: global_logger
    using TerminalLoggers: TerminalLogger
    using ArgParse

    global_logger(TerminalLogger())
    include(joinpath(@__DIR__,"log_texts.jl"))

    # free memory
    GC.gc()
end