# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

"""
    module Juleana

The Julia LEGEND Analysis dataflow.
"""
module Juleana

using LegendDataManagement
using ConcurrentCollections
using ParallelProcessingTools
using ParallelProcessingTools: getlabel

using LegendHDF5IO, LegendDSP, LegendSpecFits, LegendDataTypes, LegendDataManagement, LegendDataManagement.LDMUtils, LegendEventAnalysis
using IntervalSets, PropertyFunctions, TypedTables, PropDicts, StatsBase
using Unitful, UnitfulAtomic, Format, LaTeXStrings, Printf, Measures, Dates, Measurements
using Measurements: value as mvalue
using Measurements: uncertainty as muncert
using Distributed, ProgressMeter, TimerOutputs
using ParallelProcessingTools
import LegendMakie, Makie, CairoMakie

using HDF5
using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked
using Base.Iterators, StructArrays

using Logging: global_logger
using TerminalLoggers: TerminalLogger
using ArgParse

# apply default settings
include("setdefaults.jl")

# startup functions with command line utilities
include("config.jl")

# Log text for reports
include("log_texts.jl")

# Utilities and functionalities for parallel processing
include("parallel.jl")

# interactive utils
include("interactive.jl")

end # module
