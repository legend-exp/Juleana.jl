# ENV["JULIA_DEBUG"] = Main # enable debug
# ENV["JULIA_CPU_TARGET"] = "generic" # enable AVX2
# # import Pkg; Pkg.instantiate(); Pkg.precompile() # load packages

# using LegendDataManagement, PropertyFunctions, TypedTables, PropDicts
# using Unitful, Formatting, LaTeXStrings
# using LegendHDF5IO, LegendDSP, LegendSpecFits
# using Distributed, ProgressMeter
# import Pkg


# # config for MPP servers
# server_config = [("cslg-01.mpp.mpg.de", 5), ("cslg-02.mpp.mpg.de", 10), ("cslg-03.mpp.mpg.de", 20)]
# addprocs(server_config, exeflags=`--threads=4 --project=$(dirname(Pkg.project().path))`, env=["JULIA_CPU_TARGET"=>"generic"], topology=:master_worker)
# addprocs(20, exeflags=`--threads=4 --project=$(dirname(Pkg.project().path))`, env=["JULIA_CPU_TARGET"=>"generic"], topology=:master_worker)

# @info "Using Julia $VERSION"
# @info "Using Julia project $(dirname(Pkg.project().path))"
# # Sanity check:
# worker_ids = Distributed.remotecall_fetch.(Ref(Distributed.myid), Distributed.workers())
# @assert length(worker_ids) == Distributed.nworkers()

# @info "$(Distributed.nworkers()) Julia worker processes active."
# @assert @fetchfrom 2 ENV["JULIA_CPU_TARGET"] == "generic" 

# @everywhere begin
#     using LegendDataManagement, PropertyFunctions, TypedTables, PropDicts
#     using Unitful, Formatting, LaTeXStrings
#     using LegendHDF5IO, LegendDSP, LegendSpecFits
#     using Distributed, ProgressMeter
#     ENV["LEGEND_DATA_CONFIG"] = "/home/iwsatlas1/henkes/l200/auto/config.json"
# end

# @info "Loading Legend MetaData"
# l200 = LegendData(:l200)

function process_dsp(l200::LegendData, period::DataPeriod, run::DataRun)
    @info "Process DSP for period $period and run $run"

    filekeys = sort(search_disk(FileKey, l200.tier[:raw, :cal, period, run]), by = x-> x.time)
    filekey = filekeys[1]
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
    @debug "Loaded optimization parameters: $(pars_optimization)"

    @debug "Create DSP folder"
    dsp_folder = l200.tier[:dsp, :cal, period, run]
    ifelse(isdir(dsp_folder), @debug("DSP folder $dsp_folder already exists"), mkpath(dsp_folder))


    # move all variables to workers
    @everywhere begin
        l200 = $l200
        filekeys = $filekeys
        dsp_config = $dsp_config
        pars_tau = $pars_tau
        pars_optimization = $pars_optimization
        chinfo = $chinfo
    end

    @everywhere function dsp_single_file(i::Int64)
        filename    = l200.tier[:raw, filekeys[i]]
        outfilename = l200.tier[:dsp, filekeys[i]]

        @info "Processing file: $(basename(filename))"
        data    = LHDataStore(filename, "r")
        @info "Using output file: $(basename(outfilename))"
        outdata     = LHDataStore(outfilename, "cw")
        @info "Start DSP"
        for (i, ch_short) in enumerate(chinfo.channel)
            ch_short = chinfo.channel[i]
            ch = format("ch{}", ch_short)
            det = chinfo.detector[i]

            # check if channel can be processed
            if !haskey(pars_tau, det)
                @warn "No decay time for detector $det, skip channel $ch"
                continue
            end
            if haskey(outdata, ch)
                @info "Channel $ch already processed, skip"
                continue
            end
            @debug "Processing channel $ch ($det)"

            # load data from HDF5
            data_ch = data[format("{}/raw", ch)][:]
            # process channel
            outdata[ch]  = dsp_icpc(data_ch, dsp_config, pars_tau[det].tau.val*u"µs", pars_optimization[det])
            # free memory
            GC.gc()
        end

        @info "Finished processing file: $(basename(filename))"
        close(data)
        close(outdata)
    end

    dsp_status = @showprogress pmap(eachindex(filekeys), batch_size = 1, on_error=identity) do idx
        try
            dsp_single_file(idx)
            true # success
        catch e 
            false # failed
        end
    end
    return true
end