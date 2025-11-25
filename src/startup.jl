using LegendDataManagement
using ConcurrentCollections
using ParallelProcessingTools
using ParallelProcessingTools: getlabel

@always_everywhere begin
    # load packages
    using LegendHDF5IO, LegendDSP, LegendSpecFits, LegendDataTypes, LegendDataManagement, LegendDataManagement.LDMUtils, LegendEventAnalysis
    using IntervalSets, PropertyFunctions, TypedTables, PropDicts, StatsBase, Tables
    using Unitful, UnitfulAtomic, Format, LaTeXStrings, Printf, Measures, Dates, Measurements
    using Measurements: value as mvalue
    using Measurements: uncertainty as muncert
    using Distributed, ProgressMeter, TimerOutputs
    using ParallelProcessingTools
    import LegendMakie, Makie, CairoMakie

    # package settings
    LegendSpecFits.set_timelimit(180.0)

    # pin threads
    pinthreads_auto()

    using HDF5
    using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked
    using Base.Iterators, StructArrays

    # set logging to Terminallogger for Markdown output
    using Logging: global_logger
    using TerminalLoggers: TerminalLogger
    using ArgParse

    global_logger(TerminalLogger())
    include(joinpath(@__DIR__,"log_texts.jl"))

    # free memory
    GC.gc()
end