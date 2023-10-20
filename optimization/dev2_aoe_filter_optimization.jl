using PropertyFunctions, TypedTables, PropDicts, StatsBase
using Unitful, Formatting, LaTeXStrings, Measures, Dates
using Plots
using LegendHDF5IO, LegendDSP, LegendSpecFits, LegendDataManagement, LegendDataTypes
using Distributed, DistributedArrays, ProgressMeter

import Pkg
# Pkg.instantiate() # instantiate
# Pkg.precompile() # precompile

ENV["JULIA_DEBUG"] = Main # enable debug
ENV["QT_QPA_PLATFORM"] = "xcb" # enable qt
using Logging: global_logger
using TerminalLoggers: TerminalLogger
global_logger(TerminalLogger())

gr(margin=10mm, thickness_scaling=1.5, size=(1300, 900), dpi=600)
# plotlyjs(size=(1200, 700))
# plotlyjs(size=(900, 500))

n_workers = 30
# config for MPP servers
addprocs(n_workers, exeflags=`--threads=4 --project=$(dirname(Pkg.project().path))`, env=["JULIA_CPU_TARGET"=>"generic"], topology=:master_worker)

@info "Using Julia $VERSION"
@info "Using Julia project $(dirname(Pkg.project().path))"

# Sanity check:
worker_ids = Distributed.remotecall_fetch.(Ref(Distributed.myid), Distributed.workers())
@assert length(worker_ids) == Distributed.nworkers()

@info "$(Distributed.nworkers()) Julia worker processes active."
@assert @fetchfrom 2 ENV["JULIA_CPU_TARGET"] == "generic"

@everywhere begin
    using LegendHDF5IO, LegendDSP, LegendSpecFits, LegendDataTypes, LegendDataManagement
    using IntervalSets, PropertyFunctions, TypedTables, PropDicts, StatsBase
    using StatsBase
    using Unitful, Formatting, LaTeXStrings, Printf, Dates
    using Plots, Measures
    using Distributed, DistributedArrays, ProgressMeter

    using HDF5
    using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked

    # set environment variables
    ENV["LEGEND_DATA_CONFIG"] = "/home/iwsatlas1/henkes/l200/auto/config.json"

    # select plot backend to GR
    gr()
    # free memory
    GC.gc()
end

@info "Loading Legend MetaData"
l200 = LegendData(:l200)

period = DataPeriod(3)
run    = DataRun(1)

@info "Optimize PSD filter for period $period and run $run"

filekey = sort(search_disk(FileKey, l200.tier[:raw, :cal, period, run]), by = x-> x.time)[1]
@info "Found filekey $filekey"

chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable)

sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)
dsp_meta = l200.metadata.dataprod.config.cal.dsp(sel).default
dsp_config = create_dsp_config(dsp_meta)
@debug "Loaded DSP config: $(dsp_config)"

pars_tau_folder     = joinpath(l200.tier[:par, :cal, period, run], "decay_time")
pars_filename       = format("{}-{}-{}-{}-decay_time.json", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category))
pars_tau            = readprops(joinpath(pars_tau_folder, pars_filename))
@debug "Loaded decay times"

pars_optimization_folder = joinpath(l200.tier[:par, :cal, period, run], "optimization")
pars_filename           = format("{}-{}-{}-{}-filter_optimization.json", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category))
pars_optimization       = readprops(joinpath(pars_optimization_folder, pars_filename))
@debug "Loaded optimization parameters"

@debug "Create figures folder"
figures_folder = joinpath(l200.tier[:plt, :cal, period, run], "optimization")
ifelse(isdir(figures_folder), @debug("Figure folder $figures_folder already exists"), mkpath(figures_folder))

@debug "Create pars folder"
pars_folder = joinpath(l200.tier[:par, :cal], "optimization/")
ifelse(isdir(joinpath(pars_folder, "$period")), @debug("Pars folder $pars_folder already exists"), mkpath(joinpath(pars_folder, "$period")))

@debug "Create logs folder"
log_folder = joinpath(l200.tier[:log, :cal, period, run])
ifelse(isdir(log_folder), @debug("Log folder $log_folder already exists"), mkpath(log_folder))

@debug "Create pars db"
reprocess = false
pars_db = PropDict()
pars_filename       = joinpath(pars_folder, "$period/$run.json")
pars_validTimeStamp = string(filekey.time)
# read params if exist
if isfile(pars_filename)
    @info "File $pars_filename already exists."
    pars_db = readprops(pars_filename)
end

if reprocess
    @info "Reprocess all channels"
    pars_db = PropDict()
end

# move all variables to workers
@everywhere begin
    l200 = $l200
    sel = $sel
    dsp_config = $dsp_config
    filekey = $filekey
    pars_tau = $pars_tau
    pars_optimization = $pars_optimization
    chinfo = $chinfo
    figures_folder = $figures_folder
    pars_db = $pars_db
    reprocess = $reprocess
end

@everywhere function ch_sg_optimization(i::Int64)

    ch_short = chinfo.channel[i]
    ch = format("ch{}", ch_short)
    det = chinfo.detector[i]

    if !reprocess && haskey(pars_db, det)
        @debug "Channel $(chinfo.detector[i]) already processed, skip"
        log = "| $ch | $det | Success| $(pars_db[det].sg_wl.val*u"ns") | $(round(pars_db[det].sg_min_sep_sf, digits=2)) | $(round(pars_db[det].sg_min_sep_sf_err, digits=2)) | Already processed --> skipped. |"
        result_sg_wl = (
            wl = NaN*u"ns",
            sf = NaN,
            sf_err = NaN
        )
        return (result = result_sg_wl, log = log)
    end

    @info "Processing channel $ch ($det)"

    if haskey(l200.metadata.dataprod.config.cal.dsp(sel).optimization, det)
        optimization_config = l200.metadata.dataprod.config.cal.dsp(sel).optimization[det]
        @debug "Use config for detector $det"
    else
        optimization_config = l200.metadata.dataprod.config.cal.dsp(sel).optimization.default
        @debug "Use default config"
    end
    
    filename = joinpath(l200.tier[DataTier(:peaks), :cal, filekey.period, filekey.run], format("{}-{}-{}-{}-{}-tier_peaks.lh5", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch))
    if !isfile(filename)
        @warn "File $filename does not exist, Skip channel $ch"
        # throw(LoadError(string(basename(filename)), 154,"File $(basename(filename)) does not exist"))
    end
    
    wvfs_ch_dep = nothing
    wvfs_ch_sep = nothing
    
    try 
        data = LHDataStore(filename, "r")

        @debug "Loading Tl208 FEP data from $(filename)"
        wvfs_ch_dep_bi121fep = data[ch].Tl208DEP_Bi212FEP.waveform[:]
        e_ch_dep_bi121fep    = data[ch].Tl208DEP_Bi212FEP.daqenergy[:]
        wvfs_ch_dep   = wvfs_ch_dep_bi121fep[e_ch_dep_bi121fep .< quantile(e_ch_dep_bi121fep, optimization_config.sg.dep_sep_quantile)]
        wvfs_ch_sep   = data[ch].Tl208SEP.waveform[:]

        close(data)
    catch e
        @error "DEP and SEP data from $(basename(filename)) cannot be loaded"
        throw(LoadError(string(basename(filename)), 154,"DEP and SEP data from $(basename(filename)) cannot be loaded"))
    end
    
    dsp_dep = nothing
    dsp_sep = nothing

    try
        # DSP
        @debug "Generating DSP AoE grid for SEP and DEP data"
        dsp_dep = dsp_sg_optimization(wvfs_ch_dep, dsp_config, pars_tau[det].tau.val*u"µs", pars_optimization[det])
        dsp_sep = dsp_sg_optimization(wvfs_ch_sep, dsp_config, pars_tau[det].tau.val*u"µs", pars_optimization[det])
    catch e
        @error "Failed DSP for DEP or SEP"
        throw(ErrorException("Failed DSP for DEP or SEP."))
    end

    # free memory
    GC.gc()

    dep_sep_after_qc = nothing

    try
        # generate simple QC cuts
        @debug "Use simple QC cuts for SEP and DEP"
        dep_sep_after_qc = qc_sg_optimization(dsp_dep, dsp_sep, optimization_config)
    catch e
        @error "Failed QC for DEP or SEP"
        throw(ErrorException("QC for DEP or SEP."))
    end
    
    # free memory
    GC.gc()

    result_sg_wl, report_sg_wl = nothing, nothing

    try
        # fit SG window length
        @debug "Sweep through window lengths for SEP and DEP and get SEP survival fraction after simple PSD cut on DEP"
        result_sg_wl, report_sg_wl = fit_sg_wl(dep_sep_after_qc, dsp_config.a_grid_wl_sg, optimization_config)    
    catch e
        @error "Failed SG window length optimization"
        throw(ErrorException("SG window length optimization."))
    end
    
    plot(report_sg_wl, title=format("{} SG Filter Optimization ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))

    savefig(joinpath(figures_folder, format("{}-{}-{}-{}-{}-sg_sweep.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

    @info """Found optimal window length at $(result_sg_wl.wl) with survival fraction $(round(result_sg_wl.sf, digits=2)) ± $(round(result_sg_wl.sf_err, digits=2))%"""

    # write log
    log_info = "| $ch | $det | Success| $(result_sg_wl.wl) | $(round(result_sg_wl.sf, digits=2)) | $(round(result_sg_wl.sf_err, digits=2)) | - |"
    
    # free memory
    GC.gc()

    return (result = result_sg_wl, log = log_info)
end

result_sg = @showprogress pmap(eachindex(chinfo.channel), batch_size = 3) do idx
    try
        chinfo.detector[idx] => ch_sg_optimization(idx)
    catch e
        @debug "Write Error log for $(chinfo.detector[idx])"
        log_info = "| ch$(chinfo.channel[idx]) | $(chinfo.detector[idx]) | Failed | - | - | - | $(e) |"
        result_sg_wl = (
            wl = NaN*u"ns",
            sf = NaN,
            sf_err = NaN
        )
        chinfo.detector[idx] => (result = result_sg_wl, log = log_info)
    end
end

@info "Finished SG filter optimization"
@info "Remove all workers"
rmprocs(workers()...)

main_log = """
# Main log 
Time of processing: $(now())
## SG window length optimization
This is the log for the savitzky-golay filter optimization for the PSD analysis. The processing involves
a small DSP routine on the waveforms in the DEP and SEP, a simple AoE cut for different window lengths
and the calculation of the survival fraction in the SEP after a simple PSD cut on the DEP. Then, the 
window length with the lowest survival fraction is chosen.

# MetaData
| Setup | Period | Run | Category |
|-------|--------|-----|----------|
| $(filekey.setup) | $(filekey.period) | $(filekey.run) | $(filekey.category) |

# Results
| Channel | Detector | Success | Window length | SF    | SF Error | Error |
|---------|----------|---------|---------------|-------|----------|-------|
"""
# extract results into pars_db and append to main log
for (det, res) in result_sg
    # save pars to db
    if !isnan(res.result.sf)
        pars_det                    = pars_db[det]
        pars_det.sg_wl              = res.result.wl
        pars_det.sg_min_sep_sf      = res.result.sf
        pars_det.sg_min_sep_sf_err  = res.result.sf_err
    end
    # add log to main log
    main_log = """
    $main_log$(res.log)
    """
    # main_log *= res.log
end

# save pars to disk
@info "Save pars to disk"
writeprops(pars_filename, pars_db, multiline=true)

# write validity
if !isfile(pars_filename)
    open(joinpath(pars_folder, "validity.jsonl"), "a") do io
        println(io, "{\"valid_from\":\"$pars_validTimeStamp\", \"category\":\"all\", \"apply\":[\"$period/$run.json\"]}")
    end
end

@info "Write main log to disk"
@info main_log

log_filename = joinpath(log_folder, format("{}-{}-{}-{}-sg_filter_optimization.md", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
open(log_filename, "w+") do file
    write(file, replace(main_log, "Success" => raw"$${\color{green}Success}$$", "Failed" => raw"$${\color{red}Failed}$$"))
end



