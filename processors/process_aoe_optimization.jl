function process_aoe_optimization(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)

    @info "Optimize PSD filter for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true) |> filterby(@pf $usability == :on && $low_aoe_status in [:valid, :present])
    @info "Loaded channel info with $(length(chinfo)) channels"

    dsp_config_pd = dataprod_config(l200).dsp(filekey)
    @debug "Loaded DSP config: $(dsp_config_pd)"

    f_evaluate_qc = h5open(get_mltrainfilename(l200, filekey)) do train_data
        get_qc_ml_func(Array(train_data["ml_train/dsp/dwt_norm"]), Array(train_data["ml_train/dsp/dc_label"]), l200.par.rpars.ml(filekey))
    end
    @info "Loaded trained SVM model"

    pars_tau = get_values(l200.par.rpars.pz[period, run])
    @debug "Loaded decay times"

    pars_fltoptimization = get_values(l200.par.rpars.fltopt[period, run])
    @debug "Loaded energy optimization parameters"

    optimization_config = dataprod_config(l200).dsp(filekey).aoe_optimization
    @debug "Loaded optimization config: $(optimization_config)"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.aoeopt), string(period)))
    pars_db = PropDict(l200.par.rpars.aoeopt[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" end

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Status, Symbol("Filter Type"), Symbol("Window length"), Symbol("Survival Fraction"), Symbol("Number of DEP"), Symbol("Number of SEP"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))
    
    # flush stdout
    flush(stdout)

    function ch_sg_optimization(chinfo_ch::NamedTuple)
        
        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        @info "Processing channel $ch ($det)"

        dsp_config_ch = DSPConfig(merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict())))
        @debug "Loaded DSP config: $(dsp_config_ch)"

        aoe_config_ch = merge(optimization_config.default, get(optimization_config, det, PropDict()))
        qc_string     = aoe_config_ch.qc
        aoe_filter      = collect(keys(aoe_config_ch.aoe_filter))

        result_wl_dict = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(det) already processed, check missing filters"
            for filter_type in aoe_filter
                if haskey(pars_db[det], filter_type)
                    log_info = log_nt((ch, det, ProcessStatus(1), filter_type, pars_db[det][filter_type].wl, pars_db[det][filter_type].sf, pars_db[det][filter_type].n_dep, pars_db[det][filter_type].n_sep, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[filter_type] = log_info
                    processed_dict[filter_type] = false
                end
            end
        end

        # check if all filters are already processed
        if length(keys(processed_dict)) == length(aoe_filter)
            @debug "All filters already processed, skip channel"
            return (processed = processed_dict, log = log_info_dict)
        end
        
        filename = l200.tier[:jlpeaks, filekey, ch]
        if !isfile(filename)
            @warn "File $filename does not exist, Skip channel $ch"
            throw(LoadError(string(part), 154,"File $(part) does not exist"))
        end
        
        wvfs_ch_sep_wdw, wvfs_ch_sep_pre, wvfs_ch_dep_wdw, wvfs_ch_dep_pre, presum_rate = nothing, nothing, nothing, nothing, nothing
        try
            data = lh5open(filename, "r")

            @debug "Loading Tl208 SEP and DEP data from $(filename)"
            wvfs_ch_dep_bi121fep_wdw = data[ch].jlpeaks.Tl208DEP_Bi212FEP.waveform_windowed[:]
            wvfs_ch_dep_bi121fep_pre = data[ch].jlpeaks.Tl208DEP_Bi212FEP.waveform_presummed[:]
            presum_rate              = data[ch].jlpeaks.Tl208SEP.presum_rate[1]
            e_ch_dep_bi121fep        = data[ch].jlpeaks.Tl208DEP_Bi212FEP.daqenergy[:]
            # wvfs_ch_dep_wdw          = wvfs_ch_dep_bi121fep_wdw[e_ch_dep_bi121fep .< quantile(e_ch_dep_bi121fep, aoe_config_ch.dep_sep_quantile)]
            wvfs_ch_dep_wdw          = wvfs_ch_dep_bi121fep_wdw
            # wvfs_ch_dep_pre          = wvfs_ch_dep_bi121fep_pre[e_ch_dep_bi121fep .< quantile(e_ch_dep_bi121fep, aoe_config_ch.dep_sep_quantile)]
            wvfs_ch_dep_pre          = wvfs_ch_dep_bi121fep_pre
            wvfs_ch_sep_wdw          = data[ch].jlpeaks.Tl208SEP.waveform_windowed[:]
            wvfs_ch_sep_pre          = data[ch].jlpeaks.Tl208SEP.waveform_presummed[:]

            close(data)
        catch e
            @error "DEP and SEP data from $(part) cannot be loaded: $(truncate_error(e))"
            throw(LoadError(string(part), 154,"DEP and SEP data from $(part) cannot be loaded: $(truncate_error(e))"))
        end
        
        @showprogress desc="Computing $det ..." for filter_type in aoe_filter
            if haskey(processed_dict, filter_type)
                continue
            end
            
            try
                @debug "Optimize $filter_type filter"

                aoe_config_flt = aoe_config_ch.aoe_filter[filter_type]

                dsp_sep, dsp_dep = nothing, nothing
                try
                    # DSP
                    @debug "Generating DSP AoE grid for SEP and DEP data"
                    dsp_dep = getfield(Main, Symbol("dsp_$(filter_type)_optimization_compressed"))(wvfs_ch_dep_wdw, wvfs_ch_dep_pre, dsp_config_ch, pars_tau[det].τ, pars_fltoptimization[det]; f_evaluate_qc=f_evaluate_qc, presum_rate=presum_rate)
                    dsp_sep = getfield(Main, Symbol("dsp_$(filter_type)_optimization_compressed"))(wvfs_ch_sep_wdw, wvfs_ch_sep_pre, dsp_config_ch, pars_tau[det].τ, pars_fltoptimization[det]; f_evaluate_qc=f_evaluate_qc, presum_rate=presum_rate)
                catch e
                    @error "Failed DSP for DEP or SEP: $(truncate_error(e))"
                    throw(ErrorException("Error in DSP for DEP or SEP: $(truncate_error(e))"))
                end

                dep_sep_after_qc = nothing
                try
                    # generate simple QC cuts
                    @debug "Apply QC cuts for SEP and DEP"
                    dep_sep_after_qc = (dep = dsp_dep[ljl_propfunc(qc_string).(dsp_dep)], 
                                sep = dsp_sep[ljl_propfunc(qc_string).(dsp_sep)]
                    )
                catch e
                    @error "Failed QC for DEP or SEP: $(truncate_error(e))"
                    throw(ErrorException("QC for DEP or SEP: $(truncate_error(e))"))
                end

                # free memory
                GC.gc()

                result_wl, report_wl = nothing, nothing
                try
                    # fit SG window length
                    @debug "Sweep through window lengths for SEP and DEP and get SEP survival fraction after simple PSD cut on DEP"
                    result_wl, report_wl = fit_sf_wl(dep_sep_after_qc.dep.e, dep_sep_after_qc.dep.aoe, dep_sep_after_qc.sep.e, dep_sep_after_qc.sep.aoe, dsp_config_ch.a_grid_wl_sg;
                                                dep=aoe_config_flt.dep, dep_window=aoe_config_flt.dep_window, sep=aoe_config_flt.sep, sep_window=aoe_config_flt.sep_window, 
                                                sep_rel_cut=aoe_config_flt.sep_rel_cut, 
                                                min_aoe_quantile=aoe_config_flt.min_aoe_quantile, max_aoe_quantile=aoe_config_flt.max_aoe_quantile,
                                                min_aoe_offset=aoe_config_flt.min_aoe_offset, max_aoe_offset=aoe_config_flt.max_aoe_offset,
                                                dep_cut_search_fit_func=Symbol(aoe_config_flt.dep_cut_search_fit_func), sep_cut_search_fit_func=Symbol(aoe_config_flt.sep_cut_search_fit_func)
                                                )
                catch e
                    @error "Failed SG window length optimization: $(truncate_error(e))"
                    throw(ErrorException("SG window length optimization: $(truncate_error(e))"))
                end
                
                p = plot(report_wl)
                title!(p, get_plottitle(filekey, det, "SG Filter Optimization"))
                savelfig(savefig, p, l200, filekey, det, Symbol("sg_sweep"))

                @info """Found optimal window length at $(result_wl.wl) with survival fraction $(round(u"percent", result_wl.sf, digits=2)) for channel $ch ($det)"""

                # write log
                log_info = log_nt((ch, det, ProcessStatus(1), filter_type, result_wl.wl, result_wl.sf, result_wl.n_dep, result_wl.n_sep, "-"))
                
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = true
                result_wl_dict[filter_type] = result_wl

                # free memory
                GC.gc()
                yield()
            catch e
                @error "Filter: $filter_type filter optimization: $(truncate_error(e))"
                log_info = log_nt((ch, det, ProcessStatus(0), filter_type, "-", "-", "-", "-", "$(truncate_error(e))"))
                # add results to dict
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = false
            end
        end

        return (result = result_wl_dict, log = log_info_dict, processed = processed_dict)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_sg = parallel(chinfo, ch_sg_optimization, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished SG filter optimization"

    pars_db = create_pars(pars_db, result_sg)
    writelprops(l200.par.rpars.aoeopt[period], run, pars_db)
    writevalidity(l200.par.rpars.aoeopt, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Time of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, sg_flt_optimization_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_sg))


    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    # flush stdout
    flush(stdout)
end

