function p_process_decay_time(processing_config::PropDict, l200::LegendData, period::DataPeriod,; reprocess::Bool=false, timeout::Int=0, max_wvfs::Int=15000, only_first_period::Bool=true)
    @info "Process decay time for all partitions containing period $period"

    rinfo = runinfo(l200, period)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).cal.startkey
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) channels"

    dsp_config = DSPConfig(dataprod_config(l200).dsp(filekey).default)
    @debug "Loaded DSP config: $(dsp_config)"

    f_evaluate_qc = h5open(get_mltrainfilename(l200, filekey)) do train_data
        get_qc_ml_func(Array(train_data["ml_train/dsp/dwt_norm"]), Array(train_data["ml_train/dsp/dc_label"]), l200.par.rpars.ml(filekey))
    end
    @info "Loaded trained SVM model"

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Partition, :Status, Symbol("Decay Time"), Symbol("σ"), :Error)}
    
    if reprocess @info "Reprocess all channels" else @info "Only process channels not in pars_db" end

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # get unfolded channel info where each entry is a detector and its partition for all partitions that contain period
    chinfo_unfolded = get_partition_channelinfo(l200, chinfo, period; unfold_partitions=true)

    # flush stdout
    flush(stdout)
    
    # function to process decay time
    function ch_decay_time(chinfo_ch::NamedTuple)

        ch  = chinfo_ch.channel
        det = chinfo_ch.detector
        part = chinfo_ch.partition

        mkpath(joinpath(data_path(l200.par.ppars.pz), string(det)))
        pars_db_ch = if isfile(joinpath(data_path(l200.par.ppars.pz[det]), "$part.json"))
            PropDict(l200.par.ppars.pz[det, part])
        else
            PropDict()
        end

        partinfo_ch = partitioninfo(l200, ch, part)
        @debug "Loaded channel partition info with $(length(partinfo_ch)) runs"
    
        filekey_ch = start_filekey(l200, (first(partinfo_ch.period), first(partinfo_ch.run), :cal))
        @debug "Found filekey $filekey_ch"

        validity_ch = get_partitionvalidity(l200, ch, det, part, :cal)

        if only_first_period && period != first(partinfo_ch.period)
            @info "Only first period in partition $part for $period in $ch ($det)"
            log_ch = log_nt((ch, det, part, ProcessStatus(1), fill("-", 2)..., "Only first periods --> skipped."))
            return (processed = false, log = log_ch, validity = validity_ch, skipped = true)
        end 

        if !reprocess && haskey(pars_db_ch, det)
            @debug "Channel $det already processed, skip"
            log_ch = log_nt((ch, det, part, ProcessStatus(1), pars_db_ch[det].τ, pars_db_ch[det].n_tau, "Already processed --> skipped."))
            return (processed = false, log = log_ch, validity = validity_ch)
        end

        @debug "Processing channel $ch ($det)"

        pz_config = dataprod_config(l200).dsp(filekey_ch).pz
        pz_config_ch = merge(pz_config.p_default, get(pz_config.p, det, PropDict()))
        @debug "Loaded PZ config: $(pz_config_ch)"

        # unpack config
        min_τ, max_τ  = pz_config_ch.min_tau, pz_config_ch.max_tau
        nbins         = pz_config_ch.nbins
        rel_cut_fit   = pz_config_ch.rel_cut_fit
        n_evts        = pz_config_ch.n_evts
        select_random = pz_config_ch.select_random
        peakname      = Symbol(pz_config_ch.peakname)
        qc_string     = pz_config_ch.qc

        # load data
        wvfs_ch = nothing
        try
            @debug "Loading $peakname data from $(part), select $(ifelse(select_random, "randomly", "")) $n_evts events from each run"
            data = load_partition_ch(lh5open, fast_flatten, l200, partinfo_ch, :jlpeaks, :cal, ch; data_keys=(peakname, ), n_evts=n_evts, select_random=select_random)
            wvfs_ch = getproperty(data, peakname).waveform_presummed[:]
            if length(wvfs_ch) > max_wvfs
                @warn "$peakname events exceed $max_wvfs, keep only $max_wvfs events"
                wvfs_ch = wvfs_ch[rand(1:max_wvfs, max_wvfs)]
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

        # DSP
        decay_times = nothing
        try
            @debug "Generating DSP for FEP decay times"
            decay_times = dsp_decay_times(wvfs_ch, dsp_config)
        catch e
            @error "Error in DSP for FEP: $(truncate_string(string(e)))"
            throw(ErrorException("Error in DSP for FEP: $(truncate_string(string(e)))"))
        end
        yield()

        # get decay time
        cuts_τ, result, report =  nothing, nothing, nothing
        try
            cuts_τ = cut_single_peak(decay_times, min_τ, max_τ,; n_bins=nbins, relative_cut=rel_cut_fit)
            result, report = fit_single_trunc_gauss(decay_times, cuts_τ; uncertainty=true)
        catch e
            @error "Failed decay time extraction: $(truncate_string(string(e)))"
            throw(ErrorException("Error in decay time extraction: $(truncate_string(string(e)))"))
        end
        yield()
        
        p = plot(report)
        title!(p, get_plottitle(filekey_ch, part, det, "Decay Time Distribution"), subplot=1)

        savelfig(savefig, p, l200, part, filekey_ch, det, :decay_time)

        @info "Found decay time at $(round(u"µs", result.µ, digits=2)) for channel $ch ($det)"

        log_ch = log_nt((ch, det, part, ProcessStatus(1), result.μ, result.σ, "-"))

        # generate channel result
        result_ch = (result = (τ = result.μ, fit = result), processed = true, log = log_ch, validity = validity_ch)
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
    result_pz = parallel(chinfo_unfolded, ch_decay_time, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

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
    writelreport(get_preportfilename(l200, filekey, :decay_time), report)
    @info report
    
    # flush stdout
    flush(stdout)

    # return if any channel was skipped so that the partition is not valid until the lower period is finished
    return any(x -> get(last(x), :skipped, false), values(result_pz))
end