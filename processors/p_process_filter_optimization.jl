function p_process_filter_optimization(processing_config::PropDict, l200::LegendData, period::DataPeriod,; reprocess::Bool=false, timeout::Int=0, max_wvfs::Int=15000, only_first_period::Bool=true)
    
    @info "Optimize filter for all partitions containing period $period"

    rinfo = runinfo(l200, period)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).cal.startkey
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) channels"

    f_evaluate_qc = h5open(get_mltrainfilename(l200, filekey)) do train_data
        get_qc_ml_func(Array(train_data["ml_train/dsp/dwt_norm"]), Array(train_data["ml_train/dsp/dc_label"]), l200.par.rpars.ml(filekey))
    end
    @info "Loaded trained SVM model"

    if reprocess @info "Reprocess all channels" else @info "Only process channels not in pars_db" end

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Partition, :Status, Symbol("Filter Type"), Symbol("Rise Time"), Symbol("Flat-Top Time"), Symbol("Min. FWHM"), :Error)}
    
    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # get unfolded channel info where each entry is a detector and its partition for all partitions that contain period
    chinfo_unfolded = get_partition_channelinfo(l200, chinfo, period; unfold_partitions=true)

    # flush stdout
    flush(stdout)

    function ch_filter_optimization(chinfo_ch::NamedTuple)

        ch  = chinfo_ch.channel
        det = chinfo_ch.detector
        part = chinfo_ch.partition

        @debug "Processing channel $ch ($det)"
        
        mkpath(joinpath(data_path(l200.par.ppars.fltopt), string(det)))
        pars_db_ch = if isfile(joinpath(data_path(l200.par.ppars.fltopt[det]), "$part.json"))
            PropDict(l200.par.ppars.fltopt[det, part])
        else
            PropDict()
        end

        partinfo_ch = partitioninfo(l200, ch, part)
        @debug "Loaded channel partition info with $(length(partinfo_ch)) runs"
    
        filekey_ch = start_filekey(l200, (first(partinfo_ch.period), first(partinfo_ch.run), :cal))
        @debug "Found filekey $filekey_ch"

        validity_ch = get_partitionvalidity(l200, ch, det, part, :cal)

        pars_tau = get_values(l200.par.ppars.pz[det, part])
        @debug "Loaded decay times"

        dsp_config_pd = dataprod_config(l200).dsp(filekey_ch)
        dsp_config_ch = DSPConfig(merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict())))
        @debug "Loaded DSP config: $(dsp_config_ch)"

        optimization_config = dataprod_config(l200).dsp(filekey_ch).flt_optimization
        optimization_config_ch = merge(optimization_config.p_default, get(optimization_config.p, det, PropDict()))
        @debug "Loaded optimization config: $(optimization_config_ch)"
        
        # extract config
        n_evts        = optimization_config_ch.n_evts
        select_random = optimization_config_ch.select_random
        qc_string     = optimization_config_ch.qc
        peakname      = Symbol(optimization_config_ch.peakname)
        e_filter      = collect(keys(optimization_config_ch.e_filter))

        result_rt_ft_dict = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        if (only_first_period && period != first(partinfo_ch.period))
            @info "Only first period in partition $part for $period in $ch ($det)"
            for filter_type in e_filter
                log_info = log_nt((ch, det, part, ProcessStatus(1), filter_type, fill("-", 3)..., "Only first periods --> skipped."))
                # add results to dict
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = false
            end
            return (processed = processed_dict, log = log_info_dict, validity = validity_ch, skipped = true)
        end

        if !reprocess && haskey(pars_db_ch, det)
            @debug "Channel $(det) already processed, check missing filters"
            for filter_type in e_filter
                if haskey(pars_db_ch[det], filter_type)
                    @debug "Filter $filter_type already processed, skip"
                    log_info = log_nt((ch, det, part, ProcessStatus(1), filter_type, pars_db_ch[det][filter_type].rt, pars_db_ch[det][filter_type].ft, pars_db_ch[det][filter_type].min_fwhm, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[filter_type] = log_info
                    processed_dict[filter_type] = false
                end
            end
        end

        # check if all filters are already processed
        if length(keys(processed_dict)) == length(e_filter)
            @debug "All filters already processed, skip channel"
            return (processed = processed_dict, log = log_info_dict, validity = validity_ch)
        end

        # load data
        wvfs_ch_pre, wvfs_ch_wdw, presum_rate = nothing, nothing, nothing
        try
            @debug "Loading $peakname data from $(part), select $(ifelse(select_random, "randomly", "")) $n_evts events from each run"
            data = load_partition_ch(lh5open, fast_flatten, l200, partinfo_ch, :jlpeaks, :cal, ch; data_keys=(peakname, ), n_evts=n_evts, select_random=select_random)
            wvfs_ch_pre = getproperty(data, peakname).waveform_presummed[:]
            wvfs_ch_wdw = getproperty(data, peakname).waveform_windowed[:]
            presum_rate = getproperty(data, peakname).presum_rate[:]
            if length(wvfs_ch_pre) > max_wvfs
                @warn "$peakname events exceed $max_wvfs, keep only $max_wvfs events"
                sel = rand(1:max_wvfs, max_wvfs)
                wvfs_ch_pre = wvfs_ch_pre[sel]
                wvfs_ch_wdw = wvfs_ch_wdw[sel]
                presum_rate = presum_rate[sel]
            end
        catch e
            @error "$peakname data from $(basename(filename)) cannot be loaded: $(truncate_string(string(e)))"
            throw(LoadError(string(basename(filename)), 154,"$peakname data from $(basename(filename)) cannot be loaded: $(truncate_string(string(e)))"))
        end
        yield()

        # get QC cuts
        blmean_wdw = nothing
        try
            @debug "Get QC cuts"
            dsp_qc = dsp_qc_flt_optimization_compressed(wvfs_ch_pre, dsp_config_ch, pars_tau[det].τ, f_evaluate_qc)
            qc = ljl_propfunc(qc_string).(dsp_qc)
            blmean_wdw = dsp_qc.blmean ./ presum_rate
            wvfs_ch_pre = wvfs_ch_pre[qc]
            wvfs_ch_wdw = wvfs_ch_wdw[qc]
            blmean_wdw = blmean_wdw[qc]
            @debug "Surrival Fraction: $(round(count(qc) / length(qc) * 100, digits=2))%"
        catch e
            @error "Failed QC cuts: $(truncate_string(string(e)))"
            throw(ErrorException("Error in QC cuts: $(truncate_string(string(e)))"))
        end

        # get qdrift
        qdrift = nothing
        try
            @debug "Get QDrift"
            qdrift = dsp_qdrift_flt_optimization(wvfs_ch_wdw, blmean_wdw, dsp_config_ch, pars_tau[det].τ)
        catch e
            @error "Failed QDrift: $(truncate_string(string(e)))"
            throw(ErrorException("Error in QDrift: $(truncate_string(string(e)))"))
        end
        GC.gc()

        @showprogress desc="Computing $det ..." for filter_type in e_filter
            if haskey(processed_dict, filter_type)
                continue
            end
            
            try
                @debug "Optimize $filter_type filter"

                optimization_config_flt = optimization_config_ch.e_filter[filter_type]
                # unpack config
                e_grid_rt            = getproperty(dsp_config_ch, Symbol("e_grid_rt_$(filter_type)"))
                e_grid_ft            = getproperty(dsp_config_ch, Symbol("e_grid_ft_$(filter_type)"))

                # optimize RT
                enc_grid = nothing
                try
                    @debug "Generate $filter_type ENC filter grid"
                    enc_grid = getfield(Main, Symbol("dsp_$(filter_type)_rt_optimization"))(wvfs_ch_pre, dsp_config_ch, pars_tau[det].τ; ft=optimization_config_flt.ft_fixed)
                catch e
                    @error "Filter: $filter_type RT DSP for FEP: $(truncate_string(string(e)))"
                    throw(ErrorException("Error in $filter_type RT DSP for FEP: $(truncate_string(string(e)))"))
                end
                yield()
                GC.gc()
                result_rt, report_rt = nothing, nothing
                try
                    result_rt, report_rt = fit_enc_sigmas(enc_grid, e_grid_rt, optimization_config_flt.min_enc, optimization_config_flt.max_enc, optimization_config_flt.nbins_enc_sigmas, optimization_config_flt.rel_cut_fit_enc_sigmas)
                catch e
                    @error "Failed $filter_type rise time extraction: $(truncate_string(string(e)))"
                    throw(ErrorException("Error in $filter_type rise time extraction: $(truncate_string(string(e)))"))
                end
                @debug format("Found optimal $filter_type RT at $(result_rt.rt) with ENC {:.2f} ADC", result_rt.min_enc)
                yield()

                p = plot(report_rt)
                title!(p, get_plottitle(filekey_ch, part, det, "Noise Sweep"; additiional_type=string(filter_type)))
                savelfig(savefig, p, l200, part, filekey_ch, det, Symbol("noise_sweep_$(filter_type)"))

                # optimize FT
                yield()
                GC.gc()
                e_grid = nothing
                try
                    @debug "Generate $filter_type FT energy grid"
                    e_grid = getfield(Main, Symbol("dsp_$(filter_type)_ft_optimization"))(wvfs_ch_pre, dsp_config_ch, pars_tau[det].τ, mvalue(result_rt.rt))
                catch e
                    @error "Filter: $filter_type FT DSP for FEP: $(truncate_string(string(e)))"
                    throw(ErrorException("Error in $filter_type FT DSP for FEP: $(truncate_string(string(e)))"))
                end
                yield()
                GC.gc()
                result_ft, report_ft = nothing, nothing
                try
                    result_ft, report_ft = fit_fwhm_ft(e_grid, e_grid_ft, qdrift, result_rt.rt, optimization_config_flt.min_e_fep, optimization_config_flt.max_e_fep, optimization_config_flt.rel_cut_fit_e_fep, optimization_config_ch.apply_ctc; n_bins=optimization_config_flt.nbins_e_fep, peak=optimization_config_ch.peak, window=(optimization_config_ch.left_window_size, optimization_config_ch.right_window_size))
                catch e
                    @error "Failed $filter_type flat-top time extraction: $(truncate_string(string(e)))"
                    throw(ErrorException("Error in $filter_type flat-top time extraction: $(truncate_string(string(e)))"))
                end
                @debug "Found optimal $filter_type FT at $(result_ft.ft) with FWHM $(round(u"keV", result_ft.min_fwhm, digits=2))"
                yield()
                
                p = plot(report_ft)
                title!(p, get_plottitle(filekey_ch, part, det, "FEP FT Scan"; additiional_type=string(filter_type)))
                savelfig(savefig, p, l200, part, filekey_ch, det, Symbol("fwhm_ft_scan_$(filter_type)"))

                log_info = log_nt((ch, det, part, ProcessStatus(1), filter_type, result_rt.rt, result_ft.ft, result_ft.min_fwhm, "-"))

                # add results to dict
                result_rt_ft_dict[filter_type] = merge(result_rt, result_ft)
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = true

                # call garbage collector
                GC.gc()
                yield()
            catch e
                @error "Filter: $filter_type filter optimization: $(truncate_string(string(e)))"
                log_info = log_nt((ch, det, part, ProcessStatus(0), filter_type, "-", "-", "-", "$(truncate_string(string(e)))"))
                # add results to dict
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = false
            end
        end

        # generate channel result
        result_ch = (result = result_rt_ft_dict, processed = processed_dict, log = log_info_dict, validity = validity_ch)
        result_flt_ch = Dict{NamedTuple, NamedTuple}(chinfo_ch => result_ch)
        
        pars_db_ch = create_pars(pars_db_ch, result_flt_ch)
        writelprops(l200.par.ppars.fltopt[det], part, pars_db_ch)
        writevalidity(l200.par.ppars.fltopt[det], filekey_ch, part)

        # return results
        return result_ch
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_flt = parallel(chinfo_unfolded, ch_filter_optimization, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")
    @info "Finished filter optimization"

    @info "Write $period validity"
    validity_all = create_validity(result_flt)
    writevalidity(l200.par.ppars.fltopt, validity_all)

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, flt_optimization_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_flt))

    @info "Write log report"
    writelreport(get_preportfilename(l200, filekey, :filter_optimization), report)
    @info report
    
    # flush stdout
    flush(stdout)

    return any(x -> get(last(x), :skipped, false), values(result_flt))
end

