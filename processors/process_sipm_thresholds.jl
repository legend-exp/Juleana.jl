function process_sipm_thresholds(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0, max_wvfs::Int=15000)
        
    @info "Process SiPM thresholds for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:spms, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) channels"

    dsp_config = dataprod_config(l200).sipm(filekey)
    @debug "Loaded DSP config: $(dsp_config)"

    optimization_config = dataprod_config(l200).sipm(filekey).optimization
    @debug "Loaded Optimization config: $(optimization_config)"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.sipmopt), string(period)))
    pars_db = PropDict(l200.par.rpars.sipmopt[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" end

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Status, Symbol("σ Trigger"), Symbol("σ DC Trigger"), :Error)}
    
    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    # function to process decay time
    function ch_sipm_threshold(chinfo_ch::NamedTuple)

        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $det already processed, skip"
            log_ch = log_nt((ch, det, ProcessStatus(1), pars_db[det].τ, pars_db[det].n_tau, "Already processed --> skipped."))
            return (processed = false, log = log_ch)
        end

        @debug "Processing channel $ch ($det)"

        dsp_config_ch = merge(dsp_config.default, get(dsp_config, det, PropDict()))
        optimization_config_ch = merge(optimization_config.default, get(optimization_config, det, PropDict()))

        filename = l200.tier[:raw, filekey]
        if !isfile(filename)
            @warn "File $filename does not exist, Skip channel $ch"
            throw(LoadError(string(basename(filename)), 154,"File $(basename(filename)) does not exist"))
        end

        # load data
        wvfs_ch = nothing
        try
            wvfs_ch = lh5open(filename, "r")[ch, :raw].waveform_bit_drop[:]
            @debug "Loading SiPM data from $(filename)"
            if length(wvfs_ch) > max_wvfs
                @warn "SiPM events exceed $max_wvfs, keep only $max_wvfs events"
                sel = rand(1:max_wvfs, max_wvfs)
                wvfs_ch = wvfs_ch[sel]
            end
        catch e
            @error "SiPM data from $(basename(filename)) cannot be loaded: $(truncate_string(string(e)))"
            throw(LoadError(string(basename(filename)), 154,"SiPM data from $(basename(filename)) cannot be loaded: $(truncate_string(string(e)))"))
        end
        yield()

        # DSP
        bsl, bsl_flipped = nothing, nothing
        try
            @debug "Generating DSP for SiPMs waveform"
            dsp_sipm = dsp_sipm_thresholds_compressed(wvfs_ch, dsp_config_ch)
            bsl, bsl_flipped = dsp_sipm.bsl, dsp_sipm.bsl_flipped
        catch e
            @error "Errorin SiPM DSP: $(truncate_string(string(e)))"
            throw(ErrorException("Error in SiPM DSP: $(truncate_string(string(e)))"))
        end
        yield()

        # get trigger threshold
        result_trig, report_trig =  nothing, nothing
        try
            cuts_bsl = cut_single_peak(bsl, optimization_config_ch.threshold.min_cut, optimization_config_ch.threshold.max_cut; n_bins=optimization_config_ch.threshold.nbins, relative_cut=optimization_config_ch.threshold.rel_cut)
            result_trig, report_trig = fit_single_trunc_gauss(bsl, cuts_bsl)
        catch e
            @error "Failed trigger threshold extraction: $(truncate_string(string(e)))"
            throw(ErrorException("Error in trigger threshold extraction: $(truncate_string(string(e)))"))
        end
        yield()
        
        p = plot(report_trig)
        title!(p, get_plottitle(filekey, det, "Baseline distribution"), subplot=1)

        savelfig(savefig, p, l200, filekey, det, :trigger_threshold)

        @info "Found 1-σ trigger threshold at $(round(result_trig.σ, digits=2)) for channel $ch ($det)"
        
        # get DC trigger threshold
        result_trig_dc, report_trig_dc =  nothing, nothing
        try
            cuts_bsl_flipped = cut_single_peak(bsl_flipped, optimization_config_ch.dc_threshold.min_cut, optimization_config_ch.dc_threshold.max_cut; n_bins=optimization_config_ch.dc_threshold.nbins, relative_cut=optimization_config_ch.dc_threshold.rel_cut)
            result_trig_dc, report_trig_dc = fit_single_trunc_gauss(bsl_flipped, cuts_bsl_flipped)
        catch e
            @error "Failed DC trigger threshold extraction: $(truncate_string(string(e)))"
            throw(ErrorException("Error in DC trigger threshold extraction: $(truncate_string(string(e)))"))
        end
        yield()
        
        p = plot(report_trig_dc)
        title!(p, get_plottitle(filekey, det, "Flipped Baseline distribution"), subplot=1)

        savelfig(savefig, p, l200, filekey, det, :dc_trigger_threshold)

        @info "Found 1-σ DC trigger threshold at $(round(result_trig_dc.σ, digits=2)) for channel $ch ($det)"

        log_ch = log_nt((ch, det, ProcessStatus(1), result_trig.σ, result_trig_dc.σ, "-"))
        return (result = (trig = result_trig, dc = result_trig_dc), processed = true, log = log_ch)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_sipm_threshold = parallel(chinfo, ch_sipm_threshold, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")
    @info "Finished SiPM threshold extraction"

    pars_db = create_pars(pars_db, result_sipm_threshold)
    writelprops(l200.par.rpars.sipmopt[period], run, pars_db)
    writevalidity(l200.par.rpars.sipmopt, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, sipm_opt_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_sipm_threshold))

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, :sipm_threshold), report)
    @info report
    
    # flush stdout
    flush(stdout)
end