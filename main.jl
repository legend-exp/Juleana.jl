# set environment variables
ENV["JULIA_DEBUG"] = Main # enable debug
ENV["JULIA_CPU_TARGET"] = "generic" # enable AVX2
ENV["LEGEND_DATA_CONFIG"] = "/home/iwsatlas1/henkes/l200/auto/config.json"

# load packages
import Pkg
# Pkg.instantiate() # instantiate
# Pkg.precompile() # precompile

using LegendDataManagement, PropertyFunctions, TypedTables, PropDicts
using Unitful, Formatting, LaTeXStrings
using Plots
using LegendHDF5IO, LegendDSP, LegendSpecFits
using Distributed, ProgressMeter

# select plot backend
gr()
# plotlyjs()

# config for MPP servers
server_config = [("cslg-02.mpp.mpg.de", 10), ("cslg-03.mpp.mpg.de", 25)]
addprocs(server_config, exeflags=`--threads=4 --project=$(dirname(Pkg.project().path))`, env=["JULIA_CPU_TARGET"=>"generic"], topology=:master_worker)
addprocs(25, exeflags=`--threads=4 --project=$(dirname(Pkg.project().path))`, env=["JULIA_CPU_TARGET"=>"generic"], topology=:master_worker)

@info "Using Julia $VERSION"
@info "Using Julia project $(dirname(Pkg.project().path))"

# Sanity check:
worker_ids = Distributed.remotecall_fetch.(Ref(Distributed.myid), Distributed.workers())
@assert length(worker_ids) == Distributed.nworkers()

@info "$(Distributed.nworkers()) Julia worker processes active."
@assert @fetchfrom 2 ENV["JULIA_CPU_TARGET"] == "generic" 

@everywhere begin
    using LegendDataManagement, PropertyFunctions, TypedTables, PropDicts
    using Unitful, Formatting, LaTeXStrings
    using Plots
    using LegendHDF5IO, LegendDSP, LegendSpecFits
    using Distributed, ProgressMeter
    ENV["LEGEND_DATA_CONFIG"] = "/home/iwsatlas1/henkes/l200/auto/config.json"
    gr()
    # plotlyjs()
end

@info "Loading Legend MetaData"
l200 = LegendData(:l200)

@info "Start Data processing"

include(joinpath(@__DIR__,"optimization/decay_time.jl"))
include(joinpath(@__DIR__,"optimization/filter_optimization.jl"))
include(joinpath(@__DIR__,"dsp/dsp.jl"))

# select periods to process
periods = [DataPeriod(i) for i in 3:3]
# periods = search_disk(DataPeriod, l200.tier[:raw, :cal])

# process periods 
for period in periods
    @info "Process period $period"
    # select runs to process
    runs = search_disk(DataRun, l200.tier[:raw, :cal, period])
    @info "Found runs $(string.(runs))"
    # process runs
    for run in runs
        if run != DataRun(1)
            continue
        end
        # if run == DataRun(0) || run == DataRun(1)
        #     continue
        # end
        @info "Process run $run"
        # process decay time
        # process_decay_time(l200, period, run)
        # process filter optimization
        # process_filter_optimization(l200, period, run)
        # process dsp
        process_dsp(l200, period, run)
    end
end