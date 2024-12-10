function p_process_aoe_optimization(processing_config::PropDict, l200::LegendData, period::DataPeriod,; reprocess::Bool=false, timeout::Int=0, max_wvfs::Int=15000, only_first_period::Bool=true)

    @info "Optimize PSD filter for all partitions containing period $period"

    rinfo = runinfo(l200, period)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).cal.startkey
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true) |> filterby(@pf $usability == :on && $low_aoe_status in [:valid, :present])
    @info "Loaded channel info with $(length(chinfo)) channels"

    f_evaluate_qc = h5open(get_mltrainfilename(l200, filekey)) do train_data
        get_qc_ml_func(Array(train_data["ml_train/dsp/dwt_norm"]), Array(train_data["ml_train/dsp/dc_label"]), l200.par.rpars.ml(filekey))
    end
    @info "Loaded trained SVM model"

    if reprocess @info "Reprocess all channels" else @info "Only process channels not in pars_db" end

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Partition, :Status, :Usability, Symbol("Filter Type"), Symbol("Window length"), Symbol("Surrival Fraction"), Symbol("Number of DEP"), Symbol("Number of SEP"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))
    
    # get unfolded channel info where each entry is a detector and its partition for all partitions that contain period
    chinfo_unfolded = get_partition_channelinfo(l200, chinfo, period; unfold_partitions=true)

    # flush stdout
    flush(stdout)

    function ch_sg_optimization(chinfo_ch::NamedTuple)
        
        ch  = chinfo_ch.channel
        det = chinfo_ch.detector
        part = chinfo_ch.partition

        @info "Processing channel $ch ($det)"

        pars_db_ch = if isfile(joinpath(data_path(l200.par.ppars.aoeopt), "$det", "$part.json"))
            PropDict(l200.par.ppars.aoeopt[det, part])
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

        pars_fltoptimization = get_values(l200.par.ppars.fltopt[det, part])
        @debug "Loaded energy optimization parameters"

        dsp_config_pd = dataprod_config(l200).dsp(filekey_ch)
        dsp_config_ch = DSPConfig(merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict())))
        @debug "Loaded DSP config: $(dsp_config_ch)"

        optimization_config = dataprod_config(l200).dsp(filekey_ch).aoe_optimization
        aoe_config_ch = merge(optimization_config.p_default, get(optimization_config.p, det, PropDict()))
        @debug "Loaded optimization config: $(optimization_config)"
        
        # extract config
        qc_string       = aoe_config_ch.qc
        aoe_filter      = collect(keys(aoe_config_ch.aoe_filter))
        n_evts          = aoe_config_ch.n_evts
        select_random   = aoe_config_ch.select_random

        result_wl_dict = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        if (only_first_period && period != first(partinfo_ch.period))
            @info "Only first period in partition $part for $period in $ch ($det)"
            for filter_type in aoe_filter
                log_info = log_nt((ch, det, part, ProcessStatus(1), chinfo_ch.usability, filter_type, fill("-", 4)..., "Only first periods --> skipped."))
                # add results to dict
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = false
            end
            return (processed = processed_dict, log = log_info_dict, validity = validity_ch, skipped = true)
        end

        if !reprocess && haskey(pars_db_ch, det)
            @debug "Channel $(det) already processed, check missing filters"
            for filter_type in aoe_filter
                if haskey(pars_db_ch[det], filter_type)
                    log_info = log_nt((ch, det, part, ProcessStatus(1), chinfo_ch.usability, filter_type, pars_db_ch[det][filter_type].wl, pars_db_ch[det][filter_type].sf, pars_db_ch[det][filter_type].n_dep, pars_db_ch[det][filter_type].n_sep, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[filter_type] = log_info
                    processed_dict[filter_type] = false
                end
            end
        end

        # check if all filters are already processed
        if length(keys(processed_dict)) == length(aoe_filter)
            @debug "All filters already processed, skip channel"
            return (processed = processed_dict, log = log_info_dict, validity = validity_ch)
        end
        
        # load data
        wvfs_ch_sep_wdw, wvfs_ch_sep_pre, wvfs_ch_dep_wdw, wvfs_ch_dep_pre, presum_rate = nothing, nothing, nothing, nothing, nothing
        try
            @debug "Loading Tl208 SEP and DEP data from $(part), select $(ifelse(select_random, "randomly", "")) $n_evts events from each run"
            data = load_partition_ch(lh5open, fast_flatten, l200, partinfo_ch, :jlpeaks, :cal, ch; data_keys=(:Tl208DEP_Bi212FEP, :Tl208SEP), n_evts=n_evts, select_random=select_random)
            wvfs_ch_dep_bi121fep_wdw = data.Tl208DEP_Bi212FEP.waveform_windowed[:]
            wvfs_ch_dep_bi121fep_pre = data.Tl208DEP_Bi212FEP.waveform_presummed[:]
            presum_rate              = data.Tl208SEP.presum_rate[1]
            e_ch_dep_bi121fep        = data.Tl208DEP_Bi212FEP.daqenergy[:]
            # DEP
            # wvfs_ch_dep_wdw          = wvfs_ch_dep_bi121fep_wdw[e_ch_dep_bi121fep .< quantile(e_ch_dep_bi121fep, aoe_config_ch.dep_sep_quantile)]
            wvfs_ch_dep_wdw          = wvfs_ch_dep_bi121fep_wdw
            # wvfs_ch_dep_pre          = wvfs_ch_dep_bi121fep_pre[e_ch_dep_bi121fep .< quantile(e_ch_dep_bi121fep, aoe_config_ch.dep_sep_quantile)]
            wvfs_ch_dep_pre          = wvfs_ch_dep_bi121fep_pre
            if length(wvfs_ch_dep_pre) > max_wvfs
                @warn "DEP events exceed $max_wvfs, keep only $max_wvfs events"
                sel = rand(1:max_wvfs, max_wvfs)
                wvfs_ch_dep_pre = wvfs_ch_dep_pre[sel]
                wvfs_ch_dep_wdw = wvfs_ch_dep_wdw[sel]
            end
            # SEP
            wvfs_ch_sep_wdw          = data.Tl208SEP.waveform_windowed[:]
            wvfs_ch_sep_pre          = data.Tl208SEP.waveform_presummed[:]
            if length(wvfs_ch_sep_pre) > max_wvfs
                @warn "SEP events exceed $max_wvfs, keep only $max_wvfs events"
                sel = rand(1:max_wvfs, max_wvfs)
                wvfs_ch_sep_pre = wvfs_ch_sep_pre[sel]
                wvfs_ch_sep_wdw = wvfs_ch_sep_wdw[sel]
            end
        catch e
            @error "DEP and SEP data from $(basename(filename)) cannot be loaded: $(truncate_string(string(e)))"
            throw(LoadError(string(basename(filename)), 154,"DEP and SEP data from $(basename(filename)) cannot be loaded: $(truncate_string(string(e)))"))
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
                    @error "Failed DSP for DEP or SEP: $(truncate_string(string(e)))"
                    throw(ErrorException("Error in DSP for DEP or SEP: $(truncate_string(string(e)))"))
                end

                dep_sep_after_qc = nothing
                try
                    # generate simple QC cuts
                    @debug "Apply QC cuts for SEP and DEP"
                    dep_sep_after_qc = (dep = dsp_dep[ljl_propfunc(qc_string).(dsp_dep)],
                                sep = dsp_sep[ljl_propfunc(qc_string).(dsp_sep)]
                    )
                catch e
                    @error "Failed QC for DEP or SEP: $(truncate_string(string(e)))"
                    throw(ErrorException("QC for DEP or SEP: $(truncate_string(string(e)))"))
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
                    @error "Failed SG window length optimization: $(truncate_string(string(e)))"
                    throw(ErrorException("SG window length optimization: $(truncate_string(string(e)))"))
                end
                
                p = plot(report_wl)
                title!(p, get_plottitle(filekey_ch, part, det, "Filter Optimization"; additiional_type=string(filter_type)))
                savelfig(savefig, p, l200, part, filekey_ch, det, Symbol("aoe_sweep_$(filter_type)"))

                @info """Found optimal window length at $(result_wl.wl) with survival fraction $(round(u"percent", result_wl.sf; digits=2)) for channel $ch ($det)"""

                # write log
                log_info = log_nt((ch, det, part, ProcessStatus(1), chinfo_ch.usability, filter_type, result_wl.wl, result_wl.sf, result_wl.n_dep, result_wl.n_sep, "-"))
                
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = true
                result_wl_dict[filter_type] = result_wl

                # free memory
                GC.gc()
                yield()
            catch e
                @error "Filter: $filter_type filter optimization: $(truncate_string(string(e)))"
                log_info = log_nt((ch, det, part, ProcessStatus(0), chinfo_ch.usability, filter_type, "-", "-", "-", "-", "$(truncate_string(string(e)))"))
                # add results to dict
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = false
            end
        end
        # generate channel result
        result_ch = (result = result_wl_dict, processed = processed_dict, log = log_info_dict, validity = validity_ch)
        result_sg_ch = Dict{NamedTuple, NamedTuple}(chinfo_ch => result_ch)
        
        pars_db_ch = create_pars(pars_db_ch, result_sg_ch)
        writelprops(l200.par.ppars.aoeopt[det], part, pars_db_ch)
        writevalidity(l200.par.ppars.aoeopt[det], filekey_ch, part)

        # return results
        return result_ch
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_sg = parallel(chinfo_unfolded, ch_sg_optimization, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished SG filter optimization"

    @info "Write $period validity"
    validity_all = create_validity(result_sg)
    writevalidity(l200.par.ppars.aoeopt, validity_all)

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
    writelreport(get_preportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    # flush stdout
    flush(stdout)

    # return if any channel was skipped so that the partition is not valid until the lower period is finished
    return any(x -> get(last(x), :skipped, false), values(result_sg))
end

