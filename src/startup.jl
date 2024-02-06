import Pkg
try
    worker_instantiate
    worker_precompile
    debug 
catch e
    @warn "No precompile or debug flag set on worker"
else
    if worker_instantiate
        Pkg.instantiate()
    end
    if worker_precompile
        Pkg.precompile()
    end
    if debug
        ENV["JULIA_DEBUG"] = Main # enable debug
    end
end

# load packages
using LegendHDF5IO, LegendDSP, LegendSpecFits, LegendDataTypes, LegendDataManagement
using IntervalSets, PropertyFunctions, TypedTables, PropDicts, StatsBase
using Unitful, Formatting, LaTeXStrings, Printf, Measures, Dates
using Plots
using Distributed, ProgressMeter, TimerOutputs

using HDF5
using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked
using Base.Iterators

# select plot backend to GR
gr(margin=10mm, thickness_scaling=1.5, size=(1300, 900), dpi=600)

# set logging to Terminallogger for Markdown output
using Logging: global_logger
using TerminalLoggers: TerminalLogger
using ArgParse

global_logger(TerminalLogger())
include(joinpath(@__DIR__,"utils.jl"))

# free memory
GC.gc()