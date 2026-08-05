function p_process_decay_time(processing_config::PropDict, l200::LegendData, period::DataPeriod,; reprocess::Bool=false, timeout::Int=0, only_first_period::Bool=true)
    @info "Process decay time for all partitions containing period $period"

    rinfo = runinfo(l200, period) |> filterby(@pf $cal.is_analysis_run)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).cal.startkey
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    f_evaluate_qc = load_qc_evaluator(l200, filekey)

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :Channel, :Partition, :Status, Symbol("Decay Time"), Symbol("σ"), :Error)}
    
    if reprocess @info "Reprocess all detectors" else @info "Only process detectors not in pars_db" end

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # get unfolded channel info where each entry is a detector and its partition for all partitions that contain period
    chinfo_unfolded = get_partition_channelinfo(l200, chinfo, period, :cal; unfold_partitions=true)

    # flush stdout
    flush(stdout)
    
    # function to process decay time
    function det_decay_time(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector
        part = chinfo_det.partition

        mkpath(joinpath(data_path(l200.par.ppars.pz), string(det)))
        pars_db_det = if isfile(joinpath(data_path(l200.par.ppars.pz), "$det", "$part.yaml"))
            PropDict(l200.par.ppars.pz[det, part])
        else
            mkpath(joinpath(data_path(l200.par.ppars.pz), "$det"))
            PropDict()
        end

        partinfo_det = partitioninfo(l200, det, part)
        @debug "Loaded detector partition info with $(length(partinfo_det)) runs"
    
        filekey_det = start_filekey(l200, (first(partinfo_det.period), first(partinfo_det.run), :cal))
        @debug "Found filekey $filekey_det"

        validity_det = get_partitionvalidity(l200, det, part)

        if only_first_period && period != first(partinfo_det.period)
            @info "Only first period in partition $part for $period in $det ($ch)"
            log_det = log_nt((det, ch, part, ProcessStatus(1), fill("-", 2)..., "Only first periods --> skipped."))
            return (processed = false, log = log_det, validity = validity_det, skipped = true)
        end 

        if !reprocess && haskey(pars_db_det, det)
            @debug "Detector $det already processed, skip"
            log_det = log_nt((det, ch, part, ProcessStatus(1), pars_db_det[det].τ, pars_db_det[det].fit.σ, "Already processed --> skipped."))
            return (processed = false, log = log_det, validity = validity_det)
        end

        @debug "Processing detector $det ($ch)"

        dsp_config_pd = dataprod_config(l200).dsp(filekey_det)
        dsp_config_det = DSPConfig(merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict())))
        @debug "Loaded DSP config: $(lstring(dsp_config_det))"

        pz_config = dataprod_config(l200).dsp(filekey_det).pz
        pz_config_det = merge(pz_config.p_default, get(pz_config.p, det, PropDict()))
        @debug "Loaded PZ config: $(lstring(pz_config_det))"

        # unpack config
        min_τ, max_τ  = pz_config_det.min_tau, pz_config_det.max_tau
        nbins         = pz_config_det.nbins
        rel_cut_fit   = pz_config_det.rel_cut_fit
        n_evts        = pz_config_det.n_evts
        max_wvfs      = pz_config_det.max_wvfs
        select_random = pz_config_det.select_random
        peakname      = Symbol(pz_config_det.peakname)
        qc_string     = pz_config_det.qc

        # load data
        wvfs_det = nothing
        try
            @debug "Loading $peakname data from $(part), select $(ifelse(select_random, "randomly", "")) $n_evts events from each run"
            data = read_ldata((:waveform_presummed,), l200, DataTier(:jlpeaks), :cal, partinfo_det, det; subgroup=peakname, n_evts=n_evts)
            wvfs_det = data.waveform_presummed[:]
            if length(wvfs_det) > max_wvfs
                @warn "$peakname events exceed $max_wvfs, keep only $max_wvfs events"
                wvfs_det = wvfs_det[sort!(sample(eachindex(wvfs_det), max_wvfs; replace=false))]
            end
        catch e
            @error "$peakname data from $(part) cannot be loaded: $(truncate_error(e))"
            throw(LoadError(string(part), 154,"$peakname data from $(part) cannot be loaded: $(truncate_error(e))"))
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

        # DSP
        decay_times = nothing
        try
            @debug "Generating DSP for FEP decay times"
            decay_times = dsp_decay_times(wvfs_det, dsp_config_det)
        catch e
            @error "Error in DSP for FEP: $(truncate_error(e))"
            throw(ErrorException("Error in DSP for FEP: $(truncate_error(e))"))
        end
        yield()

        # get decay time
        cuts_τ, result, report =  nothing, nothing, nothing
        try
            cuts_τ = cut_single_peak(decay_times, min_τ, max_τ,; n_bins=nbins, relative_cut=rel_cut_fit)
            result, report = fit_single_trunc_gauss(decay_times, cuts_τ; uncertainty=true)
        catch e
            @error "Failed decay time extraction: $(truncate_error(e))"
            throw(ErrorException("Error in decay time extraction: $(truncate_error(e))"))
        end
        yield()
        
        p = LegendMakie.lplot(report, xlabel = "Decay time ($(unit(result.μ)))", title = get_plottitle(filekey_det, part, det, "Decay Time Distribution"))
        savelfig(LegendMakie.lsavefig, p, l200, part, filekey_det, det, :decay_time)

        @info "Found decay time at $(round(u"µs", result.µ, digits=2)) for detector $det ($ch)"

        log_det = log_nt((det, ch, part, ProcessStatus(1), result.μ, result.σ, "-"))

        # generate detector result
        result_det = (result = (τ = result.μ, fit = result), processed = true, log = log_det, validity = validity_det)
        result_pz_det = Dict{NamedTuple, NamedTuple}(chinfo_det => result_det)
        
        pars_db_det = create_pars(pars_db_det, result_pz_det)
        writelprops(l200.par.ppars.pz[det], part, pars_db_det)
        writevalidity(l200.par.ppars.pz[det], filekey_det, part)
        @info "Saved pars to disk for detector $det ($ch)"

        return result_det
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_pz = parallel(chinfo_unfolded, det_decay_time, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished decay time extraction"

    @info "Write $period validity"
    validity_all = create_validity(result_pz)
    writevalidity(l200.par.ppars.pz, validity_all)

    # create log report
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
    writelreport(get_preportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report
    
    # flush stdout
    flush(stdout)

    # return if any channel was skipped so that the partition is not valid until the lower period is finished
    return any(x -> get(last(x), :skipped, false), values(result_pz))
end