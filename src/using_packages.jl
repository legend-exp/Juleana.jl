# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

"""
    Juleana.@using_packages

Load the exported names of the packages Juleana works with into the calling module, e.g.
the REPL, as `using` does: the LEGEND packages with `LDMUtils`, ParallelProcessingTools,
and the packages for units, tables, measurements and timing, with `mvalue` and `muncert`
for the value and uncertainty of a `Measurement`. LegendMakie, Makie and CairoMakie are
available by their module names after `using Juleana`, without their exported names.

The packages are loaded from Juleana, so they need not be in the active environment.
Names that two packages both export, such as `fit`, must be qualified, e.g. `StatsBase.fit`.

# Examples
```julia
using Juleana
Juleana.@using_packages
channelinfo(l200, filekey)
```
"""
macro using_packages()
    return esc(Expr(:toplevel, :(using Juleana.LegendHDF5IO, Juleana.LegendDSP, Juleana.LegendSpecFits,
            Juleana.LegendDataTypes, Juleana.LegendDataManagement, Juleana.LDMUtils, Juleana.LegendEventAnalysis,
            Juleana.IntervalSets, Juleana.PropertyFunctions, Juleana.TypedTables, Juleana.PropDicts, Juleana.StatsBase,
            Juleana.Unitful, Juleana.UnitfulAtomic, Juleana.Format, Juleana.LaTeXStrings, Juleana.Printf,
            Juleana.Measures, Juleana.Dates, Juleana.Measurements, Juleana.Distributed, Juleana.ProgressMeter,
            Juleana.TimerOutputs, Juleana.ParallelProcessingTools),
        :(using Juleana.Measurements: value as mvalue, uncertainty as muncert)))
end
