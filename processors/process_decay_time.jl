function process_decay_time(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)
        
    @info "Process decay time for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    dsp_config_pd = dataprod_config(l200).dsp(filekey)
    @debug "Loaded DSP config: $(lstring(dsp_config_pd))"

    pz_config = dataprod_config(l200).dsp(filekey).pz
    @debug "Loaded PZ config: $(lstring(pz_config))"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.pz), string(period)))
    pars_db = PropDict(l200.par.rpars.pz[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all detectors" end

    f_evaluate_qc = load_qc_evaluator(l200, filekey)

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :Channel, :Status, Symbol("Decay Time"), Symbol("σ"), :Error)}
    
    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    # function to process decay time
    function det_decay_time(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector

        if !reprocess && haskey(pars_db, det)
            @debug "Detector $det already processed, skip"
            log_det = log_nt((det, ch, ProcessStatus(1), pars_db[det].τ, pars_db[det].fit.σ , "Already processed --> skipped."))
            return (processed = false, log = log_det)
        end

        @debug "Processing detector $det ($ch)"

        dsp_config_det = DSPConfig(merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict())))
        @debug "Loaded DSP config: $(lstring(dsp_config_det))"

        pz_config_det = merge(pz_config.default, get(pz_config, det, PropDict()))
        
        # unpack config
        min_τ, max_τ = pz_config_det.min_tau, pz_config_det.max_tau
        nbins        = pz_config_det.nbins
        rel_cut_fit  = pz_config_det.rel_cut_fit
        peakname     = Symbol(pz_config_det.peakname)
        qc_string    = pz_config_det.qc
        max_wvfs     = pz_config_det.max_wvfs

        filename = l200.tier[:jlpeaks, filekey, det]
        if !isfile(filename)
            @warn "File $filename does not exist, Skip detector $det"
            throw(LoadError(string(basename(filename)), 154,"File $(basename(filename)) does not exist"))
        end

        # load data
        wvfs_det = nothing
        try
            @debug "Loading $peakname data via read_ldata"
            # load only the needed column of the needed peak; n_evts caps to a random subsample
            wvfs_det = read_ldata((:waveform_presummed,), l200, DataTier(:jlpeaks), filekey, det; subgroup=peakname, n_evts=max_wvfs).waveform_presummed
        catch e
            @error "$peakname data from $(basename(filename)) cannot be loaded: $(truncate_error(e))"
            throw(LoadError(string(basename(filename)), 154,"$peakname data from $(basename(filename)) cannot be loaded: $(truncate_error(e))"))
        end
        yield()

        # get QC cuts
        try
            @debug "Get QC cuts"
            dsp_qc = dsp_qc_flt_optimization_compressed(wvfs_det, dsp_config_det, 400.0u"µs", f_evaluate_qc)
            qc = ljl_propfunc(qc_string).(dsp_qc)
            wvfs_det = wvfs_det[findall(qc)]
            @debug "Survival Fraction: $(round(count(qc) / length(qc) * 100, digits=2))%"
        catch e
            @error "Failed QC cuts: $(truncate_error(e))"
            throw(ErrorException("Error in QC cuts: $(truncate_error(e))"))
        end
        GC.gc()

        # DSP
        decay_times = nothing
        try
            @debug "Generating DSP for $peakname decay times"
            decay_times = dsp_decay_times(wvfs_det, dsp_config_det)
        catch e
            @error "Error in DSP for $peakname: $(truncate_error(e))"
            throw(ErrorException("Error in DSP for $peakname: $(truncate_error(e))"))
        end
        yield()

        # get decay time
        cuts_τ, result, report =  nothing, nothing, nothing
        try
            cuts_τ = cut_single_peak(decay_times, min_τ, max_τ,; n_bins=nbins, relative_cut=rel_cut_fit)
            result, report = fit_single_trunc_gauss(decay_times, cuts_τ)
            # physics guard: a fit escaping the search window has no usable τ peak
            min_τ <= mvalue(result.μ) <= max_τ || throw(ErrorException("fitted τ = $(round(u"µs", mvalue(result.μ), digits=1)) outside ($min_τ, $max_τ) — no usable τ peak, consider a det-specific pz override or usability change"))
        catch e
            @error "Failed decay time extraction: $(truncate_error(e))"
            throw(ErrorException("Error in decay time extraction: $(truncate_error(e))"))
        end
        yield()
        
        p = LegendMakie.lplot(report, xlabel = "Decay time ($(unit(result.μ)))", title = get_plottitle(filekey, det, "Decay Time Distribution"))
        savelfig(LegendMakie.lsavefig, p, l200, filekey, det, :decay_time)

        @info "Found decay time at $(round(u"µs", result.µ, digits=2)) for detector $det ($ch)"

        log_det = log_nt((det, ch, ProcessStatus(1), result.μ, result.σ, "-"))
        return (result = (τ = result.μ, fit = result), processed = true, log = log_det)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_pz = parallel(chinfo, det_decay_time, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")
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
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report
    
    # flush stdout
    flush(stdout)
end