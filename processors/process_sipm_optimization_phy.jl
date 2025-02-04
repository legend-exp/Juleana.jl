function process_sipm_optimization_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0, max_wvfs::Int=1000000, max_wvfs_parallel::Int=1000)
        
    @info "Process SiPM optimization for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:spms, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) channels"

    dsp_config = dataprod_config(l200).sipm(filekey)
    @debug "Loaded DSP config: $(dsp_config)"

    optimization_config = dataprod_config(l200).sipm(filekey).optimization
    @debug "Loaded Optimization config: $(optimization_config)"

    qc_config = dataprod_config(l200).qc(filekey)
    @debug "Loaded QC config: $(qc_config)"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.sipmopt), string(period)))
    pars_db = PropDict(l200.par.rpars.sipmopt[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" end

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Status, Symbol("Filter Type"), Symbol("Window length"), :Gain, Symbol("Res. 1PE"), Symbol("Trig. Thres."), :Error)}
    log_nt_puls = NamedTuple{(:Channel, :Detector, :Status, Symbol("Number Pulser Events"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    #  write out pulser events
    chinfo_puls = channelinfo(l200, filekey, Symbol(qc_config.pulser.puls_channel))
    @info "Loaded pulser channel info: $(chinfo_puls)"

    # get information about pulser events from raw trigger
    function ch_puls_phy(chinfo_puls::NamedTuple)
        
        ch_puls = chinfo_puls.channel
        det_puls = chinfo_puls.detector
        
        # get pulser filename
        pulserfilename = l200.tier[:jlpls, filekey, ch_puls]

        if !reprocess && isfile(pulserfilename)
            return (processed = false, log = log_nt_puls((ch_puls, det_puls, ProcessStatus(1), length(lh5open(pulserfilename)[ch_puls, :jlpls, :tags]), "Already processed --> skipped.")))
        end
        # extract pulser events by loading data from raw files
        @info "Get pulser events from raw data"
        raw_pls = read_ldata(l200, DataTier(:raw), :phy, period, run, ch_puls)
        
        dsp_config_pd = dataprod_config(l200).dsp(filekey)
        dsp_config_pd_ch = merge(dsp_config_pd.default, get(dsp_config_pd, det_puls, PropDict()))
        dsp_config_ch = DSPConfig(dsp_config_pd_ch)
        @debug "Loaded DSP config: $(dsp_config_ch)"

        # get pulser events DSP
        @debug "Generate DSP for Pulser events"
        dsp_pls = getfield(Main, Symbol(dsp_config_pd.additional_channel[det_puls]))(raw_pls, dsp_config_ch)

        # get pulser events data
        @debug "Calibrate Pulser events"
        data_puls = calibrate_aux_channel_data(l200, filekey, det_puls, dsp_pls)

        @info "Write Pulser events to disk"
        write_files(pulserfilename, use_cache=true, mode = CreateOrReplace()) do outfilename
            lh5open(outfilename, "w") do outdata
                @info "Save Pulser Tags"
                outdata[ch_puls, :jlpls, :tags] = data_puls;
            end
        end
        return (processed = false, log = log_nt_puls((ch_puls, det_puls, ProcessStatus(1), length(data_puls), "Already processed --> skipped.")))
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_puls = parallel([chinfo_puls], ch_puls_phy, log_nt_puls, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished Pulser channel processing"
    pulser_processing_time = now() - start_time

    # function to process filter optimization
    function ch_sipm_optimization(chinfo_ch::NamedTuple)

        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        ch_puls = chinfo_puls.channel
        det_puls = chinfo_puls.detector

        @debug "Processing channel $ch ($det)"

        dsp_config_ch          = merge(dsp_config.default, get(dsp_config, det, PropDict()))
    
        optimization_config_ch = merge(optimization_config.default, get(optimization_config, det, PropDict()))
        pulser_config_ch       = merge(qc_config.pulser.default, get(qc_config.pulser, det, PropDict()))
        e_filter               = collect(keys(optimization_config_ch.e_filter))

        result_wl_dict = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(det) already processed, check missing filters"
            for filter_type in e_filter
                if haskey(pars_db[det], filter_type)
                    @debug "Filter $filter_type already processed, skip"
                    log_info = log_nt((ch, det, ProcessStatus(1), filter_type, pars_db[det][filter_type].wl, pars_db[det][filter_type].gain, pars_db[det][filter_type].res_1pe, pars_db[det][filter_type].trig_threshold.bsl_deriv.σ, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[filter_type] = log_info
                    processed_dict[filter_type] = false
                end
            end
        end

        # check if all filters are already processed
        if length(keys(processed_dict)) == length(e_filter)
            @debug "All filters already processed, skip channel"
            return (processed = processed_dict, log = log_info_dict)
        end

        # load data
        data_ch = nothing
        try
            data_ch = read_ldata((:waveform_bit_drop, :timestamp), l200, DataTier(:raw), :phy, period, run, chinfo_ch.channel)
            @debug "Loading SiPM data from $(period)-$(run)"
            if length(data_ch) > max_wvfs
                @warn "SiPM events exceed $max_wvfs, keep only $max_wvfs events"
                sel = rand(1:max_wvfs, max_wvfs)
                data_ch = data_ch[sel]
            end
        catch e
            @error "SiPM data from $(period)-$(run) cannot be loaded: $(truncate_string(string(e)))"
            throw(LoadError(string("$(period)-$(run)"), 154,"SiPM data from $(period)-$(run) cannot be loaded: $(truncate_string(string(e)))"))
        end
        
        wvfs_ch = nothing
        try
            @debug "Get Pulser tags"
            pulserfilename = l200.tier[:jlpls, filekey, ch_puls]
            data_pulser = lh5open(pulserfilename)[ch_puls, :jlpls, :tags][:]
            is_pulser = flag_coincidences(data_ch.timestamp, data_pulser.timestamp[data_pulser.aux_trig], ts_window = pulser_config_ch.puls_ts_window)
            @debug "Found $(count(is_pulser)) pulser events"
            wvfs_ch = data_ch[findall(.!is_pulser)].waveform_bit_drop[:]
        catch e
            @error "Error in Pulser tag for channel $ch: $(truncate_string(string(e)))"
            throw(ErrorException("Error in Pulser tag for channel: $(truncate_string(string(e)))"))
        end

        @showprogress desc="Computing $det ..." for filter_type in e_filter
            if haskey(processed_dict, filter_type)
                continue
            end
            
            try
                @debug "Optimize $filter_type filter"

                optimization_config_flt = optimization_config_ch.e_filter[filter_type]
                # unpack config
                optimization_config_flt.e_grid_wl = optimization_config_flt.e_grid_wl.start:optimization_config_flt.e_grid_wl.step:optimization_config_flt.e_grid_wl.stop

                # optimize WL
                trig_max_grid, thresholds_grid = nothing, nothing
                try
                    @debug "Generate $filter_type DSP filter grid"
                    dsp_grid = getfield(Main, Symbol("dsp_$(filter_type)_sipm_optimization_compressed"))(1000, decode_data(wvfs_ch), dsp_config_ch, optimization_config_flt)
                    trig_max_grid = dsp_grid.trig_max_grid
                    thresholds_grid = dsp_grid.thresholds_grid
                catch e
                    @error "Filter: $filter_type DSP: $(truncate_string(string(e)))"
                    throw(ErrorException("Error in $filter_type SP: $(truncate_string(string(e)))"))
                end

                
                result_wl, report_wl = nothing, nothing
                try
                    # fit SG window length
                    @debug "Sweep through window lengths to get optimal gain, resolution and position of 1pe peak"
                    result_wl, report_wl = fit_sipm_wl(trig_max_grid, optimization_config_flt.e_grid_wl, thresholds_grid; NamedTuple(optimization_config_flt.kwargs)...)
                catch e
                    @error "Failed  $filter_type window length optimization: $(truncate_string(string(e)))"
                    throw(ErrorException("$filter_type Window length optimization: $(truncate_string(string(e)))"))
                end

                @debug "Found optimal window length at $(result_wl.wl) for channel $ch ($det)"

                p = plot(report_wl, framestyle=:box)
                title!(p, get_plottitle(filekey, det, "Filter Optimization"; additiional_type=string(filter_type)))
                savelfig(savefig, p, l200, filekey, det, Symbol("wl_sweep_$(filter_type)"))

                p = plot(report_wl.report_simple, yscale=:log10; cal=true)
                title!(p, get_plottitle(filekey, det, "Opt. Calibration"; additiional_type=string(filter_type)))
                savelfig(savefig, p, l200, filekey, det, Symbol("wl_sweep_calibration_$(filter_type)"))

                # thresholds for optimized window lengths
                dsp_thresholds = nothing
                try
                    @debug "DSP $filter_type thresholds"
                    dsp_thresholds = getfield(Main, Symbol("dsp_$(filter_type)_sipm_thresholds_compressed"))(decode_data(wvfs_ch[1:optimization_config_flt.threshold.n_wvfs]), mvalue(result_wl.wl), dsp_config_ch)
                catch e
                    @error "DSP $filter_type thresholds: $(truncate_string(string(e)))"
                    throw(ErrorException("Error in DSP $filter_type thresholds: $(truncate_string(string(e)))"))
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
                        @error "Failed trigger threshold extraction for $thres: $(truncate_string(string(e)))"
                        throw(ErrorException("Error in trigger threshold extraction for $thres: $(truncate_string(string(e)))"))
                    end
                    
                    @debug "Found 1-σ $thres trigger threshold at $(round(result_thres.σ, digits=2)) for channel $ch ($det)"
                    
                    p = plot(report_thres, legend=:topright)
                    title!(p, get_plottitle(filekey, det, "Baseline distribution"; additiional_type=string(thres)), subplot=1)
                    savelfig(savefig, p, l200, filekey, det, Symbol("trigger_threshold_$(thres)"))

                    result_trig = merge(result_trig, NamedTuple{(thres, )}([result_thres]))
                end
                
                log_info = log_nt((ch, det, ProcessStatus(1), filter_type, result_wl.wl, result_wl.gain, result_wl.res_1pe, result_trig.bsl_deriv.σ, "-"))

                # add results to dict
                result_wl_dict[filter_type] = merge(result_wl, (trig_threshold = result_trig, ))
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = true

                # call garbage collector
                GC.gc()
                yield()
            catch e
                @error "Filter: $filter_type filter optimization: $(truncate_string(string(e)))"
                log_info = log_nt((ch, det, ProcessStatus(0), filter_type, "-", "-", "-", "-", "$(truncate_string(string(e)))"))
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
    result_sipm_optimization = parallel(chinfo, ch_sipm_optimization, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")
    @info "Finished SiPM optimization extraction"

    pars_db = create_pars(pars_db, result_sipm_optimization)
    writelprops(l200.par.rpars.sipmopt[period], run, pars_db)
    writevalidity(l200.par.rpars.sipmopt, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Pulser Processing time: $(canonicalize(pulser_processing_time))")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, sipm_opt_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results Pulser")
    lreport!(report, create_logtbl(result_puls))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_sipm_optimization))

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report
    
    # flush stdout
    flush(stdout)
end