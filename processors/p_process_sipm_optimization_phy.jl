function p_process_sipm_optimization_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod,; reprocess::Bool=false, timeout::Int=0, only_first_period::Bool=true)
        
    @info "Process SiPM optimization for all partitions containing period $period"

    rinfo = runinfo(l200, period) |> filterby(@pf $phy.is_analysis_run)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).phy.startkey
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:spms, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    if reprocess @info "Reprocess all detectors" else @info "Only process detectors not in pars_db" end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :Channel, :Partition, :Status, Symbol("Filter Type"), Symbol("Window length"), :Gain, Symbol("Res. 1PE"), Symbol("Trig. Thres."), :Error)}
    
    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # get unfolded channel info where each entry is a detector and its partition for all partitions that contain period
    chinfo_unfolded = get_partition_channelinfo(l200, chinfo, period, :phy; unfold_partitions=true)

    # flush stdout
    flush(stdout)

    # function to process decay time
    function det_sipm_optimization(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector
        part = chinfo_det.partition

        @info "Processing detector $det ($ch)"

        pars_db_det = if isfile(joinpath(data_path(l200.par.ppars.sipmopt), "$det", "$part.yaml")) && !reprocess
            PropDict(l200.par.ppars.sipmopt[det, part])
        else
            mkpath(joinpath(data_path(l200.par.ppars.sipmopt), "$det"))
            PropDict()
        end

        partinfo_det = partitioninfo(l200, det, part)
        @debug "Loaded detector partition info with $(length(partinfo_det)) runs"

        filekeys = reduce(vcat, [filter(!in(bad_filekeys(l200; load_key=:unprocessable)), search_disk(FileKey, l200.tier[:raw, :phy, r.period, r.run])) for r in partinfo_det])
    
        filekey_det = first(getproperty(partinfo_det, :phy)).startkey
        @debug "Found filekey $filekey_det"

        validity_det = get_partitionvalidity(l200, det, part)

        dsp_config = dataprod_config(l200).sipm(filekey_det)
        dsp_config_det = merge(dsp_config.default, get(dsp_config, det, PropDict()))
        @debug "Loaded DSP config: $(dsp_config_det)"
    
        optimization_config = dataprod_config(l200).sipm(filekey_det).optimization
        optimization_config_det = merge(optimization_config.p_default, get(optimization_config.p, det, PropDict()))
        @debug "Loaded Optimization config: $(optimization_config_det)"

        qc_config = dataprod_config(l200).qc(filekey_det)
        pulser_config_det = merge(qc_config.pulser.default, get(qc_config.pulser, det, PropDict()))
        @debug "Loaded pulser config: $(pulser_config_det)"

        #  write out pulser events
        chinfo_puls = channelinfo(l200, filekey_det, Symbol(qc_config.pulser.puls_detector))
        @info "Loaded pulser channel info: $(chinfo_puls)"

        ch_puls = chinfo_puls.channel
        det_puls = chinfo_puls.detector

        max_wvfs = optimization_config_det.max_wvfs

        e_filter = collect(keys(optimization_config_det.e_filter))

        result_wl_dict    = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        if (only_first_period && period != first(partinfo_det.period))
            @info "Only first period in partition $part for $period in $det ($ch)"
            for filter_type in e_filter
                log_info = log_nt((det, ch, part, ProcessStatus(1), filter_type, fill("-", 4)..., "Only first periods --> skipped."))
                # add results to dict
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = false
            end
            return (processed = processed_dict, log = log_info_dict, validity = validity_det, skipped = true)
        end

        if !reprocess && haskey(pars_db_det, det)
            @debug "Detector $(det) already processed, check missing energy types"
            for filter_type in e_filter
                if haskey(pars_db_det[det], filter_type)
                    @debug "Filter $filter_type already processed, skip"
                    log_info = log_nt((det, ch, part, ProcessStatus(1), filter_type, pars_db_det[det][filter_type].wl, pars_db_det[det][filter_type].gain, pars_db_det[det][filter_type].res_1pe, pars_db_det[det][filter_type].trig_threshold.bsl_deriv.σ, "Already processed --> skipped."))
                    processed_dict[filter_type] = false
                    log_info_dict[filter_type] = log_info
                end
            end
        end

        # load data
        data_det = nothing
        try
            data_det = read_ldata((:waveform_bit_drop, :timestamp), l200, DataTier(:raw), filekeys, det; n_evts=optimization_config_det.n_evts)
            @debug "Loading SiPM data from $(part)"
            if length(data_det) > max_wvfs
                @warn "SiPM events exceed $max_wvfs, keep only $max_wvfs events"
                sel = rand(1:max_wvfs, max_wvfs)
                data_det = data_det[sel]
            end
        catch e
            @error "SiPM data from $(part) cannot be loaded: $(truncate_error(e))"
            throw(LoadError(string("$(part)"), 154,"SiPM data from $(part) cannot be loaded: $(truncate_error(e))"))
        end
        
        wvfs_det = nothing
        try
            @debug "Get Pulser tags"
            data_pulser = read_ldata(:tags, l200, DataTier(:jlpls), :phy, partinfo_det, det_puls).tags
            is_pulser = flag_coincidences(data_det.timestamp, data_pulser.timestamp[data_pulser.aux_trig], ts_window = pulser_config_det.puls_ts_window)
            @debug "Found $(count(is_pulser)) pulser events"
            wvfs_det = data_det[findall(.!is_pulser)].waveform_bit_drop[:]
        catch e
            @error "Error in Pulser tag for detector $det: $(truncate_error(e))"
            throw(ErrorException("Error in Pulser tag for detector: $(truncate_error(e))"))
        end

        @showprogress desc="Detector: $det" for filter_type in e_filter
            if haskey(processed_dict, filter_type)
                continue
            end
            try
                @debug "Optimize $filter_type filter"

                optimization_config_flt = optimization_config_det.e_filter[filter_type]
                # unpack config
                optimization_config_flt.e_grid_wl = optimization_config_flt.e_grid_wl.start:optimization_config_flt.e_grid_wl.step:optimization_config_flt.e_grid_wl.stop

                # optimize WL
                trig_max_grid, thresholds_grid = nothing, nothing
                try
                    @debug "Generate $filter_type DSP filter grid"
                    dsp_grid = getfield(LegendDSP, Symbol("dsp_$(filter_type)_sipm_optimization_compressed"))(1000, decode_data(wvfs_det), dsp_config_det, optimization_config_flt)
                    trig_max_grid = dsp_grid.trig_max_grid
                    thresholds_grid = dsp_grid.thresholds_grid
                catch e
                    @error "Filter: $filter_type DSP: $(truncate_error(e))"
                    throw(ErrorException("Error in $filter_type SP: $(truncate_error(e))"))
                end

                result_wl, report_wl = nothing, nothing
                try
                    # fit SG window length
                    @debug "Sweep through window lengths to get optimal gain, resolution and position of 1pe peak"
                    result_wl, report_wl = fit_sipm_wl(trig_max_grid, optimization_config_flt.e_grid_wl, thresholds_grid; NamedTuple(optimization_config_flt.kwargs)...)
                catch e
                    @error "Failed  $filter_type window length optimization: $(truncate_error(e))"
                    throw(ErrorException("$filter_type Window length optimization: $(truncate_error(e))"))
                end

                @debug "Found optimal window length at $(result_wl.wl) for detector $det ($ch)"

                p = LegendMakie.lplot(report_wl, title = get_plottitle(filekey_det, part, det, "Filter Optimization"; additional_type=string(filter_type)))
                savelfig(LegendMakie.lsavefig, p, l200, part, filekey_det, det, Symbol("wl_sweep_$(filter_type)"))

                p = LegendMakie.lplot(report_wl.report_simple, cal = true, title = get_plottitle(filekey_det, part, det, "Opt. Calibration"; additional_type=string(filter_type)))
                savelfig(LegendMakie.lsavefig, p, l200, part, filekey_det, det, Symbol("wl_sweep_calibration_$(filter_type)"))

                # thresholds for optimized window lengths
                dsp_thresholds = nothing
                try
                    @debug "DSP $filter_type thresholds"
                    dsp_thresholds = getfield(LegendDSP, Symbol("dsp_$(filter_type)_sipm_thresholds_compressed"))(decode_data(wvfs_det[1:optimization_config_flt.threshold.n_wvfs]), mvalue(result_wl.wl), dsp_config_det)
                catch e
                    @error "DSP $filter_type thresholds: $(truncate_error(e))"
                    throw(ErrorException("Error in DSP $filter_type thresholds: $(truncate_error(e))"))
                end

                # get trigger threshold
                result_trig = NamedTuple()
                for thres in collect(columnnames(dsp_thresholds))
                    result_thres, report_thres =  nothing, nothing
                    try
                        @debug "Extract trigger threshold for $thres"
                        result_thres, report_thres = fit_sipm_threshold(getproperty(dsp_thresholds, thres), optimization_config_flt.threshold.min_cut, optimization_config_flt.threshold.max_cut; 
                                                        n_bins=optimization_config_flt.threshold.nbins, relative_cut=optimization_config_flt.threshold.rel_cut, fit_thresholds=optimization_config_flt.threshold.fit_thresholds, uncertainty=true)
                    catch e
                        @error "Failed trigger threshold extraction for $thres: $(truncate_error(e))"
                        throw(ErrorException("Error in trigger threshold extraction for $thres: $(truncate_error(e))"))
                    end
                    
                    @debug "Found 1-σ $thres trigger threshold at $(round(result_thres.σ, digits=2)) for detector $det ($ch)"
                    
                    p = LegendMakie.lplot(report_thres, title = get_plottitle(filekey_det, det, "Baseline distribution"; additional_type=string(thres)))
                    savelfig(LegendMakie.lsavefig, p, l200, filekey_det, det, Symbol("trigger_threshold_$(thres)"))

                    result_trig = merge(result_trig, NamedTuple{(thres, )}([result_thres]))
                end

                log_info = log_nt((det, ch, part, ProcessStatus(1), filter_type, result_wl.wl, result_wl.gain, result_wl.res_1pe, result_trig.bsl_deriv.σ, "-"))

                # add results to dict
                result_wl_dict[filter_type] = merge(result_wl, (trig_threshold = result_trig, ))
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = true

                # call garbage collector
                GC.gc()
            catch e
                @error "Error in processing detector $det: $(truncate_error(e))"
                log_info = log_nt((det, ch, part, ProcessStatus(0), filter_type, "-", "-", "-", "-", string(e)))
                # add results to dict
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = false
            end
        end

        result_det = (result = result_wl_dict, processed = processed_dict, log = log_info_dict, validity = validity_det)
        result_sipm_det = Dict{NamedTuple, NamedTuple}(chinfo_det => result_det)

        pars_db_det = create_pars(pars_db_det, result_sipm_det)
        writelprops(l200.par.ppars.sipmopt[det], part, pars_db_det)
        writevalidity(l200.par.ppars.sipmopt[det], filekey_det, part)

        # return results
        return result_det
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_sipm_optimization = parallel(chinfo_unfolded, det_sipm_optimization, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")
    
    @info "Finished SiPM partition optimization"

    @info "Write $period validity"
    validity_all = create_validity(result_sipm_optimization)
    writevalidity(l200.par.ppars.sipmopt, validity_all)

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, sipm_opt_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_sipm_optimization))

    @info "Write log report"
    writelreport(get_preportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report
    
    # flush stdout
    flush(stdout)

    return any(x -> get(last(x), :skipped, false), values(result_sipm_optimization))
end