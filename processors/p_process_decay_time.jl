# function p_process_decay_time(processing_config::PropDict, l200::LegendData, period::DataPeriod,; reprocess::Bool=false, timeout::Union{Int, Bool}=false, max_wvfs::Int=15000)
    period = DataPeriod(3)
    @info "Process decay time for all partitions containing period $period"

    partinfo = partitioninfo(l200, "default")
    partperiod = last(partinfo).period
    @info "Loaded partition info with $(length(partinfo)) runs"

    filekey = first(partinfo).cal.startkey
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) channels"

    dsp_config = DSPConfig(dataprod_config(l200).dsp(filekey).default)
    @debug "Loaded DSP config: $(dsp_config)"

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Status, Symbol("Decay Time"), Symbol("Number of Events"), :Error)}
    
    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # get subpartitions
    channels = chinfo.channel

    period = partperiod
    ch = channels[1]
    ch = ChannelId(1108800)
    partinfo_ch = partitioninfo(l200, ch)
    subpartitions = Vector{DataPartition}([p for (p, pinfo) in partinfo_ch if period in pinfo.period])

    # flush stdout
    flush(stdout)

    # function to process decay time
    # function ch_decay_time(chinfo_ch::NamedTuple)

        ch  = chinfo_ch.channel
        det = chinfo_ch.detector
        part = chinfo_ch.partition

        pars_db_ch = PropDict(l200.par.ppars.pz[det, part])

        partinfo_ch = partitioninfo(l200, ch, part)
        @debug "Loaded channel partition info with $(length(partinfo_ch)) runs"
    
        filekey_ch = start_filekey(l200, (period_ch, run_ch, :cal))
        @debug "Found filekey $filekey_ch"

        validity_dict_ch = Dict{@NamedTuple{period::DataPeriod, run::DataRun}, String}(partinfo_ch .=> Ref("$det/$(part).json"))

        if !reprocess && haskey(pars_db_ch, det)
            @debug "Channel $det already processed, skip"
            log_ch = log_nt((ch, det, ProcessStatus(1), pars_db_ch[det].τ, pars_db_ch[det].n_tau, "Already processed --> skipped."))
            return (processed = false, log = log_ch, validity = validity_dict_ch)
        end

        @debug "Processing channel $ch ($det)"

        pz_config = dataprod_config(l200).dsp(filekey_ch).pz
        pz_config_ch = merge(pz_config.p_default, get(pz_config.p, det, PropDict()))
        @debug "Loaded PZ config: $(pz_config_ch)"

        # unpack config
        min_τ, max_τ = pz_config_ch.min_tau, pz_config_ch.max_tau
        nbins        = pz_config_ch.nbins
        rel_cut_fit  = pz_config_ch.rel_cut_fit
        n_evts      = pz_config_ch.n_evts
        select_random = pz_config_ch.select_random

        # load data
        wvfs_ch_fep = nothing
        try
            @debug "Loading Tl208 FEP data from $(part), select $(ifelse(select_random, "randomly", "")) $n_evts events from each run"
            data = load_partitionch(lh5open, fast_flatten, l200, partinfo_ch, :jlpeaks, :cal, ch; data_keys=(:Tl208FEP, ), n_evts=n_evts, select_random=select_random)
            wvfs_ch_fep = data.Tl208FEP.waveform_presummed[:]
            if length(wvfs_ch_fep) > max_wvfs
                @warn "Tl208 FEP events exceed $max_wvfs, keep only first $max_wvfs events"
                wvfs_ch_fep = wvfs_ch_fep[1:max_wvfs]
            end
        catch e
            @error "FEP data from $(part) cannot be loaded: $e"
            throw(LoadError(string(part), 154,"FEP data from $(part) cannot be loaded: $e"))
        end
        yield()

        # DSP
        decay_times = nothing
        try
            @debug "Generating DSP for FEP decay times"
            decay_times = dsp_decay_times(wvfs_ch_fep, dsp_config)
        catch e
            @error "Error in DSP for FEP: $e"
            throw(ErrorException("Error in DSP for FEP: $e"))
        end
        yield()

        # get decay time
        cuts_τ, result, report =  nothing, nothing, nothing
        try
            cuts_τ = cut_single_peak(decay_times, min_τ, max_τ,; n_bins=nbins, relative_cut=rel_cut_fit)
            result, report = fit_single_trunc_gauss(decay_times, cuts_τ)
        catch e
            @error "Failed decay time extraction: $e"
            throw(ErrorException("Error in decay time extraction: $e"))
        end
        yield()
        
        p = plot(report, decay_times, cuts_τ, xlabel="Decay Time [µs]", thickness_scaling=1.8, size=(1200, 900))
        title!(p, get_plottitle(filekey_ch, det, "Decay Time Distribution"))

        savelfig(savefig, p, l200, part, filekey_ch, det, :decay_time)

        @info "Found decay time at $(round(u"µs", result.µ, digits=2)) for channel $ch ($det)"

        log_ch = log_nt((ch, det, ProcessStatus(1), result.μ, result.n, "-"))

        # generate channel result
        result_ch = (result = (τ = result.μ, fit = result), processed = true, log = log_ch, validity = validity_dict_ch)
        result_pz_ch = Dict{NamedTuple, NamedTuple}(chinfo_ch => result_ch)
        
        pars_db_ch = create_pars(pars_db_ch, result_pz_ch)
        writelprops(l200.par.ppars.pz[det], part, pars_db_ch)
        writevalidity(l200.par.ppars.pz[det], filekey_ch, part)
        @info "Saved pars to disk for channel $ch ($det)"

        return result_ch
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_pz = parallel(chinfo, ch_decay_time, log_nt, wpool; timeout=timeout)

    @info "Finished decay time extraction"

    @info "Write $part validity"
    writevalidity(l200.par.rpars.pz, filekey)
    props_db = l200.par.ppars.pz
    partinfo = partitioninfo(l200)[part]
    result = result_pz
    

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, decay_time_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_pz))

    @info "Write log report"
    writelreport(get_reportfilename(l200, filekey, :decay_time), report)
    @info report
    
    # flush stdout
    flush(stdout)
# end