function process_decay_time(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=300, max_wvfs::Int=15000)

    @info "Process decay time for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = Table(channelinfo(l200, filekey; system=:geds, only_processable=true))
    @info "Loaded channel info with $(length(chinfo)) channels"

    dsp_config = DSPConfig(dataprod_config(l200).dsp(filekey).default)
    @debug "Loaded DSP config: $(dsp_config)"

    pz_config = dataprod_config(l200).dsp(filekey).pz
    @debug "Loaded PZ config: $(pz_config)"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.pz), string(period)))
    pars_db = ifelse(l200.par.rpars.pz[period, run] isa LegendDataManagement.NoSuchPropsDBEntry, PropDict(), l200.par.rpars.pz[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" end

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Status, Symbol("Decay Time"), Symbol("Number of Events"), :Error)}
    
    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))
    
    # move all variables to workers
    @everywhere begin
        l200 = $l200
        dsp_config = $dsp_config
        pz_config = $pz_config
        filekey = $filekey
        pars_db = $pars_db
        reprocess = $reprocess
        max_wvfs = $max_wvfs
        log_nt = $log_nt
    end


    @everywhere function ch_decay_time(chinfo_ch::NamedTuple)

        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $det already processed, skip"
            log_ch = log_nt((ch, det, ProcessStatus(1), pars_db[det].tau, pars_db[det].n_tau, "Already processed --> skipped."))
            return (processed = false, log = log_ch)
        end

        @debug "Processing channel $ch ($det)"

        pz_config_ch = merge(pz_config.default, get(pz_config, det, PropDict()))

        # unpack config
        min_τ, max_τ = pz_config_ch.min_tau, pz_config_ch.max_tau
        nbins        = pz_config_ch.nbins
        rel_cut_fit  = pz_config_ch.rel_cut_fit


        filename = get_peaksfilename(l200, filekey, ch)
        if !isfile(filename)
            @warn "File $filename does not exist, Skip channel $ch"
            throw(LoadError(string(basename(filename)), 154,"File $(basename(filename)) does not exist"))
        end

        # load data
        wvfs_ch_fep = nothing
        try
            data = lh5open(filename, "r")
            @debug "Loading Tl208 FEP data from $(filename)"
            wvfs_ch_fep = data[ch].Tl208FEP.waveform[:]
            close(data)
            if length(wvfs_ch_fep) > max_wvfs
                @warn "Tl208 FEP events exceed $max_wvfs, keep only first $max_wvfs events"
                wvfs_ch_fep = wvfs_ch_fep[1:max_wvfs]
            end
        catch e
            @error "FEP data from $(basename(filename)) cannot be loaded: $e"
            throw(LoadError(string(basename(filename)), 154,"FEP data from $(basename(filename)) cannot be loaded: $e"))
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
        
        p = plot(report, decay_times, cuts_τ, xlabel="Decay Time [µs]", legend=:topright)
        title!(p, get_plottitle(filekey, det, "Decay Time Distribution"))

        savelfig(savefig, p, l200, filekey, ch, :decay_time)

        @info "Found decay time at $(round(u"µs", result.µ, digits=2)) for channel $ch ($det)"

        log_ch = log_nt((ch, det, ProcessStatus(1), result.μ, result.n, "-"))
        return (result = (tau = result.μ, fit = result), processed = true, log = log_ch)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_pz = parallel(chinfo, ch_decay_time, log_nt, wpool; timeout=timeout)

    @info "Finished decay time extraction"

    pars_db = create_pars(pars_db, result_pz)
    writelprops(l200.par.rpars.pz[period], run, pars_db)
    writevalidity(l200.par.rpars.pz, filekey)
    @info "Saved pars to disk"

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
    writelreport(get_logfilename(l200, filekey, :decay_time), report)
    @info report
end