function process_filter_optimization(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)
    
    @info "Optimize filter for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    dsp_config_pd = dataprod_config(l200).dsp(filekey)
    @debug "Loaded DSP config: $(dsp_config_pd)"

    pars_tau = get_values(l200.par.rpars.pz[period, run])
    @debug "Loaded decay times"

    optimization_config = dataprod_config(l200).dsp(filekey).flt_optimization
    @debug "Loaded optimization config: $(optimization_config)"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.fltopt), string(period)))
    pars_db = PropDict(l200.par.rpars.fltopt[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all detectors" else @info "Only process detectors not in pars_db" end

    f_evaluate_qc = load_qc_evaluator(l200, filekey)

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :Channel, :Status, Symbol("Filter Type"), Symbol("Rise Time"), Symbol("Flat-Top Time"), Symbol("Min. FWHM"), :Error)}
    
    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    function det_filter_optimization(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector

        @debug "Processing detector $det ($ch)"

        dsp_config_det = DSPConfig(merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict())))
        @debug "Loaded DSP config: $(dsp_config_det)"

        optimization_config_det = merge(optimization_config.default, get(optimization_config, det, PropDict()))
        qc_string     = optimization_config_det.qc
        peakname      = Symbol(optimization_config_det.peakname)
        e_filter      = collect(keys(optimization_config_det.e_filter))

        result_rt_ft_dict = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        if !reprocess && haskey(pars_db, det)
            @debug "Detector $(det) already processed, check missing filters"
            for filter_type in e_filter
                if haskey(pars_db[det], filter_type)
                    @debug "Filter $filter_type already processed, skip"
                    log_info = log_nt((det, ch, ProcessStatus(1), filter_type, pars_db[det][filter_type].rt, pars_db[det][filter_type].ft, pars_db[det][filter_type].min_fwhm, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[filter_type] = log_info
                    processed_dict[filter_type] = false
                end
            end
        end

        # check if all filters are already processed
        if length(keys(processed_dict)) == length(e_filter)
            @debug "All filters already processed, skip detector"
            return (processed = processed_dict, log = log_info_dict)
        end

        filename = l200.tier[:jlpeaks, filekey, det]
        if !isfile(filename)
            @warn "File $filename does not exist, Skip detector $det"
            throw(LoadError(string(basename(filename)), 154,"File $(basename(filename)) does not exist"))
        end
        yield()

        max_wvfs = optimization_config_det.max_wvfs

        # load data
        wvfs_det_pre, wvfs_det_wdw, presum_rate = nothing, nothing, nothing
        try
            data = lh5open(filename, "r")
            @debug "Loading Tl208 FEP data from $(filename)"
            wvfs_det_pre = data[det, :jlpeaks, peakname].waveform_presummed[:]
            wvfs_det_wdw = data[det, :jlpeaks, peakname].waveform_windowed[:]
            presum_rate = data[det, :jlpeaks, peakname].presum_rate[:]
            close(data)
            if length(wvfs_det_pre) > max_wvfs
                @warn "$peakname events exceed $max_wvfs, keep only $max_wvfs events"
                sel = rand(1:max_wvfs, max_wvfs)
                wvfs_det_pre = wvfs_det_pre[sel]
                wvfs_det_wdw = wvfs_det_wdw[sel]
                presum_rate = presum_rate[sel]
            end
        catch e
            @error "$peakname data from $(basename(filename)) cannot be loaded: $(truncate_error(e))"
            throw(LoadError(string(basename(filename)), 154,"$peakname data from $(basename(filename)) cannot be loaded: $(truncate_error(e))"))
        end
        yield()

        # get QC cuts
        blmean_wdw = nothing
        try
            @debug "Get QC cuts"
            dsp_qc = dsp_qc_flt_optimization_compressed(wvfs_det_pre, dsp_config_det, pars_tau[det].τ, f_evaluate_qc)
            qc = ljl_propfunc(qc_string).(dsp_qc)
            blmean_wdw = dsp_qc.blmean ./ presum_rate
            wvfs_det_pre = wvfs_det_pre[findall(qc)]
            wvfs_det_wdw = wvfs_det_wdw[findall(qc)]
            blmean_wdw = blmean_wdw[findall(qc)]
            @debug "Survival Fraction: $(round(count(qc) / length(qc) * 100, digits=2))%"
        catch e
            @error "Failed QC cuts: $(truncate_error(e))"
            throw(ErrorException("Error in QC cuts: $(truncate_error(e))"))
        end

        # get qdrift
        qdrift = nothing
        try
            @debug "Get QDrift"
            qdrift = dsp_qdrift_flt_optimization(wvfs_det_wdw, blmean_wdw, dsp_config_det, pars_tau[det].τ)
        catch e
            @error "Failed QDrift: $(truncate_error(e))"
            throw(ErrorException("Error in QDrift: $(truncate_error(e))"))
        end

        GC.gc()

        @showprogress desc="Computing $det ..." for filter_type in e_filter
            if haskey(processed_dict, filter_type)
                continue
            end
            
            try
                @debug "Optimize $filter_type filter"

                optimization_config_flt = optimization_config_det.e_filter[filter_type]
                # unpack config
                e_grid_rt            = getproperty(dsp_config_det, Symbol("e_grid_rt_$(filter_type)"))
                e_grid_ft            = getproperty(dsp_config_det, Symbol("e_grid_ft_$(filter_type)"))

                # optimize RT
                enc_grid = nothing
                try
                    @debug "Generate $filter_type ENC filter grid"
                    enc_grid = getfield(LegendDSP, Symbol("dsp_$(filter_type)_rt_optimization"))(wvfs_det_pre, dsp_config_det, pars_tau[det].τ; ft=optimization_config_flt.ft_fixed)
                catch e
                    @error "Filter: $filter_type RT DSP for FEP: $(truncate_error(e))"
                    throw(ErrorException("Error in $filter_type RT DSP for FEP: $(truncate_error(e))"))
                end
                yield()
                GC.gc()
                result_rt, report_rt = nothing, nothing
                try
                    result_rt, report_rt = fit_enc_sigmas(enc_grid, e_grid_rt, optimization_config_flt.min_enc, optimization_config_flt.max_enc, optimization_config_flt.nbins_enc_sigmas, optimization_config_flt.rel_cut_fit_enc_sigmas)
                catch e
                    @error "Failed $filter_type rise time extraction: $(truncate_error(e))"
                    throw(ErrorException("Error in $filter_type rise time extraction: $(truncate_error(e))"))
                end
                @debug format("Found optimal $filter_type RT at $(result_rt.rt) with ENC {:.2f} ADC", result_rt.min_enc)
                yield()

                p = LegendMakie.lplot(report_rt, title = get_plottitle(filekey, det, "Noise Sweep"; additional_type=string(filter_type)))
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("noise_sweep_$(filter_type)"))

                # optimize FT
                yield()
                GC.gc()
                e_grid = nothing
                try
                    @debug "Generate $filter_type FT energy grid"
                    e_grid = getfield(LegendDSP, Symbol("dsp_$(filter_type)_ft_optimization"))(wvfs_det_pre, dsp_config_det, pars_tau[det].τ, mvalue(result_rt.rt))
                catch e
                    @error "Filter: $filter_type FT DSP for FEP: $(truncate_error(e))"
                    throw(ErrorException("Error in $filter_type FT DSP for FEP: $(truncate_error(e))"))
                end
                yield()
                GC.gc()
                result_ft, report_ft = nothing, nothing
                try
                    result_ft, report_ft = fit_fwhm_ft(e_grid, e_grid_ft, qdrift, result_rt.rt, optimization_config_flt.min_e_fep, optimization_config_flt.max_e_fep, optimization_config_flt.rel_cut_fit_e_fep, optimization_config_det.apply_ctc; 
                                            n_bins=optimization_config_flt.nbins_e_fep, peak=optimization_config_det.peak, window=(optimization_config_det.left_window_size, optimization_config_det.right_window_size), ft_fwhm_tol=optimization_config_det.ft_fwhm_tol)
                catch e
                    @error "Failed $filter_type flat-top time extraction: $(truncate_error(e))"
                    throw(ErrorException("Error in $filter_type flat-top time extraction: $(truncate_error(e))"))
                end
                @debug "Found optimal $filter_type FT at $(result_ft.ft) with FWHM $(round(u"keV", result_ft.min_fwhm, digits=2))"
                yield()
                p = LegendMakie.lplot(report_ft, title = get_plottitle(filekey, det, "FEP FT Scan"; additional_type=string(filter_type)))
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("fwhm_ft_scan_$(filter_type)"))

                log_info = log_nt((det, ch, ProcessStatus(1), filter_type, result_rt.rt, result_ft.ft, result_ft.min_fwhm, "-"))

                # add results to dict
                result_rt_ft_dict[filter_type] = merge(result_rt, result_ft)
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = true

                # call garbage collector
                GC.gc()
                yield()
            catch e
                @error "Filter: $filter_type filter optimization: $(truncate_error(e))"
                log_info = log_nt((det, ch, ProcessStatus(0), filter_type, "-", "-", "-", "$(truncate_error(e))"))
                # add results to dict
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = false
            end
        end
        # return results
        return (result = result_rt_ft_dict, log = log_info_dict, processed = processed_dict)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_flt = parallel(chinfo, det_filter_optimization, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished filter optimization"

    pars_db = create_pars(pars_db, result_flt)
    writelprops(l200.par.rpars.fltopt[period], run, pars_db)
    writevalidity(l200.par.rpars.fltopt, filekey, (period, run))
    @info "Saved pars to disk"

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
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report
    
    # flush stdout
    flush(stdout)
end

