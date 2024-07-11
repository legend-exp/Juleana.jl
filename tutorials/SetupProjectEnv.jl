
```
add modules for processing to environment
remember to set some of them to #dev branch:
* LegendDataManagement
* LegendSpecFits
* LegendEventAnalysis
```
processing_env = "/ptmp/lschl/l200/current/jlenv"
import Pkg
Pkg.activate(processing_env)

Pkg.add("LegendDataManagement")
Pkg.add("ClusterManagers")
Pkg.add("ParallelProcessingTools")
Pkg.add("LegendHDF5IO")
Pkg.add("HDF5")
Pkg.add("LegendDSP")
Pkg.add("LegendSpecFits")
Pkg.add("LegendDataTypes")
Pkg.add("LegendEventAnalysis")
Pkg.add("IntervalSets")
Pkg.add("PropertyFunctions")
Pkg.add("TypedTables")
Pkg.add("PropDicts")
Pkg.add("StatsBase")
Pkg.add("Unitful")
Pkg.add("Formatting")
Pkg.add("LaTeXStrings")
Pkg.add("Printf")
Pkg.add("Measures")
Pkg.add("Dates")
Pkg.add("Measurements")
Pkg.add("Plots")
Pkg.add("Distributed")
Pkg.add("ProgressMeter")
Pkg.add("TimerOutputs")
Pkg.add("Logging")
Pkg.add("TerminalLoggers")
Pkg.add("ArgParse")
Pkg.add("StructArrays")





