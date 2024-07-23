function process_decay_time(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Union{Int, Bool}=false, max_wvfs::Int=15000)
        
    @info "Process decay time for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) channels"

    dsp_config = DSPConfig(dataprod_config(l200).dsp(filekey).default)
    @debug "Loaded DSP config: $(dsp_config)"

    pz_config = dataprod_config(l200).dsp(filekey).pz
    @debug "Loaded PZ config: $(pz_config)"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.pz), string(period)))
    pars_db = PropDict(l200.par.rpars.pz[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" end

    f_evaluate_qc = h5open(get_mltrainfilename(l200, filekey)) do train_data
        get_qc_ml_func(Array(train_data["ml_train/dsp/dwt_norm"]), Array(train_data["ml_train/dsp/dc_label"]), l200.par.rpars.ml(filekey))
    end
    @info "Loaded trained SVM model"

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Status, Symbol("Decay Time"), Symbol("σ"), :Error)}
    
    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    # function to process decay time
    function ch_decay_time(chinfo_ch::NamedTuple)

        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $det already processed, skip"
            log_ch = log_nt((ch, det, ProcessStatus(1), pars_db[det].τ, pars_db[det].n_tau, "Already processed --> skipped."))
            return (processed = false, log = log_ch)
        end

        @debug "Processing channel $ch ($det)"

        pz_config_ch = merge(pz_config.default, get(pz_config, det, PropDict()))

        # unpack config
        min_τ, max_τ = pz_config_ch.min_tau, pz_config_ch.max_tau
        nbins        = pz_config_ch.nbins
        rel_cut_fit  = pz_config_ch.rel_cut_fit
        peakname     = Symbol(pz_config_ch.peakname)
        qc_string    = pz_config_ch.qc

        filename = l200.tier[:jlpeaks, filekey, ch]
        if !isfile(filename)
            @warn "File $filename does not exist, Skip channel $ch"
            throw(LoadError(string(basename(filename)), 154,"File $(basename(filename)) does not exist"))
        end

        # load data
        wvfs_ch = nothing
        try
            data = lh5open(filename, "r")
            @debug "Loading $peakname data from $(filename)"
            wvfs_ch = data[ch, :jlpeaks, peakname].waveform_presummed[:]
            close(data)
            if length(wvfs_ch) > max_wvfs
                @warn "$peakname events exceed $max_wvfs, keep only $max_wvfs events"
                sel = rand(1:max_wvfs, max_wvfs)
                wvfs_ch = wvfs_ch[sel]
            end
        catch e
            @error "$peakname data from $(basename(filename)) cannot be loaded: $(truncate_string(string(e)))"
            throw(LoadError(string(basename(filename)), 154,"$peakname data from $(basename(filename)) cannot be loaded: $(truncate_string(string(e)))"))
        end
        yield()

        # get QC cuts
        try
            @debug "Get QC cuts"
            dsp_qc = dsp_qc_flt_optimization_compressed(wvfs_ch, dsp_config, 400.0u"µs", f_evaluate_qc)
            qc = ljl_propfunc(qc_string).(dsp_qc)
            wvfs_ch = wvfs_ch[qc]
            @debug "Surrival Fraction: $(round(count(qc) / length(qc) * 100, digits=2))%"
        catch e
            @error "Failed QC cuts: $(truncate_string(string(e)))"
            throw(ErrorException("Error in QC cuts: $(truncate_string(string(e)))"))
        end
        GC.gc()

        # DSP
        decay_times = nothing
        try
            @debug "Generating DSP for $peakname decay times"
            decay_times = dsp_decay_times(wvfs_ch, dsp_config)
        catch e
            @error "Error in DSP for $peakname: $(truncate_string(string(e)))"
            throw(ErrorException("Error in DSP for $peakname: $(truncate_string(string(e)))"))
        end
        yield()

        # get decay time
        cuts_τ, result, report =  nothing, nothing, nothing
        try
            cuts_τ = cut_single_peak(decay_times, min_τ, max_τ,; n_bins=nbins, relative_cut=rel_cut_fit)
            result, report = fit_single_trunc_gauss(decay_times, cuts_τ)
        catch e
            @error "Failed decay time extraction: $(truncate_string(string(e)))"
            throw(ErrorException("Error in decay time extraction: $(truncate_string(string(e)))"))
        end
        yield()
        
        p = plot(report)
        title!(p, get_plottitle(filekey, det, "Decay Time Distribution"), subplot=1)

        savelfig(savefig, p, l200, filekey, det, :decay_time)

        @info "Found decay time at $(round(u"µs", result.µ, digits=2)) for channel $ch ($det)"

        log_ch = log_nt((ch, det, ProcessStatus(1), result.μ, result.σ, "-"))
        return (result = (τ = result.μ, fit = result), processed = true, log = log_ch)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_pz = parallel(chinfo, ch_decay_time, log_nt, wpool; timeout=timeout)
    @info "Finished decay time extraction"

    pars_db = create_pars(pars_db, result_pz)
    writelprops(l200.par.rpars.pz[period], run, pars_db)
    writevalidity(l200.par.rpars.pz, filekey, (period, run))
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
    writelreport(get_rreportfilename(l200, filekey, :decay_time), report)
    @info report
    
    # flush stdout
    flush(stdout)
end