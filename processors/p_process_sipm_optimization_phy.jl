function p_process_sipm_optimization_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod,; reprocess::Bool=false, timeout::Int=0, only_first_period::Bool=true)
        
    @info "Process SiPM optimization for all partitions containing period $period"

    rinfo = runinfo(l200, period) |> filterby(@pf $phy.is_analysis_run)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).phy.startkey
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:spms, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) channels"

    if reprocess @info "Reprocess all channels" else @info "Only process channels not in pars_db" end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :Channel, :Partition, :Status, Symbol("Filter Type"), Symbol("Window length"), :Gain, Symbol("Res. 1PE"), Symbol("Trig. Thres."), :Error)}
    
    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # get unfolded channel info where each entry is a detector and its partition for all partitions that contain period
    chinfo_unfolded = get_partition_channelinfo(l200, chinfo, period, :phy; unfold_partitions=true)

    # flush stdout
    flush(stdout)

    # Helper function to resolve data key (detector preferred, fallback to channel)
    function resolve_data_key(ds, ch, det)
        det_key = string(det)
        ch_key = string(ch)
        if haskey(ds, det_key)
            return det_key
        elseif haskey(ds, ch_key)
            return ch_key
        else
            return nothing
        end
    end

    # Helper function to resolve jlpls file path (detector preferred, fallback to channel)
    function resolve_jlpls_path(l200::LegendData, fk, ch_resolve, det_resolve)
        for key in (det_resolve, ch_resolve)
            try
                filename = l200.tier[:jlpls, fk, key]
                return (filename, key)
            catch err
                @debug "jlpls path lookup failed for $(key): $(truncate_error(err))"
            end
        end
        return nothing
    end

    # function to process decay time
    function ch_sipm_optimization(chinfo_ch::NamedTuple)

        ch  = chinfo_ch.channel
        det = chinfo_ch.detector
        part = chinfo_ch.partition

        @info "Processing channel $ch ($det)"

        pars_db_ch = if isfile(joinpath(data_path(l200.par.ppars.sipmopt), "$det", "$part.yaml")) && !reprocess
            PropDict(l200.par.ppars.sipmopt[det, part])
        else
            mkpath(joinpath(data_path(l200.par.ppars.sipmopt), "$det"))
            PropDict()
        end

        partinfo_ch = partitioninfo(l200, ch, part)
        @debug "Loaded channel partition info with $(length(partinfo_ch)) runs"
    
        filekey_ch = first(getproperty(partinfo_ch, :phy)).startkey
        @debug "Found filekey $filekey_ch"

        validity_ch = get_partitionvalidity(l200, det, part)

        dsp_config = dataprod_config(l200).sipm(filekey_ch)
        dsp_config_ch = merge(dsp_config.default, get(dsp_config, det, PropDict()))
        @debug "Loaded DSP config: $(dsp_config_ch)"
    
        optimization_config = dataprod_config(l200).sipm(filekey_ch).optimization
        optimization_config_ch = merge(optimization_config.p_default, get(optimization_config.p, det, PropDict()))
        @debug "Loaded Optimization config: $(optimization_config_ch)"

        qc_config = dataprod_config(l200).qc(filekey_ch)
        pulser_config_ch = merge(qc_config.pulser.default, get(qc_config.pulser, det, PropDict()))
        @debug "Loaded pulser config: $(pulser_config_ch)"

        #  write out pulser events
        chinfo_puls = channelinfo(l200, filekey_ch, Symbol(qc_config.pulser.puls_channel))
        @debug "Loaded pulser channel info: $(chinfo_puls)"

        ch_puls = chinfo_puls.channel
        det_puls = chinfo_puls.detector
        det_puls_label = string(det_puls)

        max_wvfs = optimization_config_ch.max_wvfs

        e_filter = collect(keys(optimization_config_ch.e_filter))

        result_wl_dict    = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        if (only_first_period && period != first(partinfo_ch.period))
            @info "Only first period in partition $part for $period in $det ($ch)"
            for filter_type in e_filter
                log_info = log_nt((det, ch, part, ProcessStatus(1), filter_type, fill("-", 4)..., "Only first periods --> skipped."))
                # add results to dict
                log_info_dict[energy_types] = log_info
                processed_dict[energy_types] = false
            end
            return (processed = processed_dict, log = log_info_dict, validity = validity_ch, skipped = true)
        end

        if !reprocess && haskey(pars_db_ch, det)
            @debug "Channel $(det) already processed, check missing energy types"
            for filter_type in e_filter
                if haskey(pars_db_ch[det], filter_type)
                    @debug "Filter $filter_type already processed, skip"
                    log_info = log_nt((det, ch, part, ProcessStatus(1), filter_type, pars_db_ch[det][filter_type].wl, pars_db_ch[det][filter_type].gain, pars_db_ch[det][filter_type].res_1pe, pars_db_ch[det][filter_type].trig_threshold.bsl_deriv.σ, "Already processed --> skipped."))
                    processed_dict[filter_type] = false
                    log_info_dict[filter_type] = log_info
                end
            end
        end

        # load data - try detector key first, fallback to channel key
        data_ch = nothing
        try
            for dkey in (det, ch)
                try
                    # Try bit-dropped waveform, fall back to raw waveform if not present
                    try
                        data_ch = read_ldata((:waveform_bit_drop, :timestamp), l200, DataTier(:raw), :phy, partinfo_ch, dkey; n_evts=optimization_config_ch.n_evts)
                    catch
                        data_ch = read_ldata((:waveform, :timestamp), l200, DataTier(:raw), :phy, partinfo_ch, dkey; n_evts=optimization_config_ch.n_evts)
                    end
                    @debug "Loading SiPM data from $(part) with key: $dkey"
                    break
                catch e
                    @debug "Failed to load SiPM data with key $dkey: $(truncate_error(e))"
                end
            end
            if data_ch === nothing
                throw(ErrorException("Could not load SiPM data with detector or channel key"))
            end
            if length(data_ch) > max_wvfs
                @warn "SiPM events exceed $max_wvfs, keep only $max_wvfs events"
                sel = rand(1:length(data_ch), max_wvfs)
                data_ch = data_ch[sel]
            end
        catch e
            @error "SiPM data from $(part) cannot be loaded: $(truncate_error(e))"
            throw(LoadError(string("$(part)"), 154,"SiPM data from $(part) cannot be loaded: $(truncate_error(e))"))
        end
        
        wvfs_ch = nothing
        try
            @debug "Get Pulser tags"
            # Load pulser data run-by-run and combine timestamps
            pulser_timestamps = nothing
            pulser_aux_trig = nothing
            for pinfo in partinfo_ch
                @debug "Loading pulser data from $(pinfo.period)-$(pinfo.run)"
                pls_data = nothing
                # Try detector key first, fallback to channel key
                for pkey in (det_puls, ch_puls)
                    try
                        pls_data = read_ldata(:tags, l200, DataTier(:jlpls), :phy, pinfo.period, pinfo.run, pkey)
                        @debug "Loaded pulser data with key: $pkey for $(pinfo.period)-$(pinfo.run)"
                        break
                    catch e
                        @debug "Failed to load pulser data with key $pkey for $(pinfo.period)-$(pinfo.run): $(truncate_error(e))"
                    end
                end
                if pls_data === nothing
                    @warn "Could not load pulser data for $(pinfo.period)-$(pinfo.run), skipping run"
                    continue
                end
                # Access nested tags structure
                pls_tags = hasproperty(pls_data, :tags) ? pls_data.tags : pls_data
                if pulser_timestamps === nothing
                    pulser_timestamps = pls_tags.timestamp[pls_tags.aux_trig]
                else
                    pulser_timestamps = vcat(pulser_timestamps, pls_tags.timestamp[pls_tags.aux_trig])
                end
            end
            if pulser_timestamps === nothing || isempty(pulser_timestamps)
                throw(ErrorException("Could not load pulser data for any run in partition"))
            end
            is_pulser = flag_coincidences(data_ch.timestamp, pulser_timestamps, ts_window = pulser_config_ch.puls_ts_window)
            @debug "Found $(count(is_pulser)) pulser events"
            non_pulser_idx = findall(.!is_pulser)
            wvfs_col = hasproperty(data_ch, :waveform_bit_drop) ? :waveform_bit_drop : :waveform
            waveform_data = getproperty(data_ch[non_pulser_idx], wvfs_col)[:]

            # Convert stored tables into RDWaveform vectors understood by DSP code
            wvfs_ch = LegendHDF5IO.from_table(waveform_data, AbstractVector{<:LegendDataTypes.RDWaveform})
            wvfs_ch = decode_data(wvfs_ch)
        catch e
            @error "Error in Pulser tag for channel $ch: $(truncate_error(e))"
            throw(ErrorException("Error in Pulser tag for channel: $(truncate_error(e))"))
        end

        @showprogress desc="Detector: $det" for filter_type in e_filter
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
                    dsp_grid = getfield(LegendDSP, Symbol("dsp_$(filter_type)_sipm_optimization_compressed"))(1000, decode_data(wvfs_ch), dsp_config_ch, optimization_config_flt)
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

                @debug "Found optimal window length at $(result_wl.wl) for channel $ch ($det)"

                p = LegendMakie.lplot(report_wl, title = get_plottitle(filekey_ch, part, det, "Filter Optimization"; additional_type=string(filter_type)))
                savelfig(LegendMakie.lsavefig, p, l200, part, filekey_ch, det, Symbol("wl_sweep_$(filter_type)"))

                p = LegendMakie.lplot(report_wl.report_simple, cal = true, title = get_plottitle(filekey_ch, part, det, "Opt. Calibration"; additional_type=string(filter_type)))
                savelfig(LegendMakie.lsavefig, p, l200, part, filekey_ch, det, Symbol("wl_sweep_calibration_$(filter_type)"))

                # thresholds for optimized window lengths
                dsp_thresholds = nothing
                try
                    @debug "DSP $filter_type thresholds"
                    dsp_thresholds = getfield(LegendDSP, Symbol("dsp_$(filter_type)_sipm_thresholds_compressed"))(decode_data(wvfs_ch[1:optimization_config_flt.threshold.n_wvfs]), mvalue(result_wl.wl), dsp_config_ch)
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
                    
                    @debug "Found 1-σ $thres trigger threshold at $(round(result_thres.σ, digits=2)) for channel $ch ($det)"
                    
                    p = LegendMakie.lplot(report_thres, title = get_plottitle(filekey, det, "Baseline distribution"; additional_type=string(thres)))
                    savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("trigger_threshold_$(thres)"))

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
                @error "Error in processing channel $ch: $(truncate_error(e))"
                log_info = log_nt((det, ch, part, ProcessStatus(0), filter_type, "-", "-", "-", "-", string(e)))
                # add results to dict
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = false
            end
        end

        result_ch = (result = result_wl_dict, processed = processed_dict, log = log_info_dict, validity = validity_ch)
        result_sipm_ch = Dict{NamedTuple, NamedTuple}(chinfo_ch => result_ch)

        pars_db_ch = create_pars(pars_db_ch, result_sipm_ch)
        writelprops(l200.par.ppars.sipmopt[det], part, pars_db_ch)
        writevalidity(l200.par.ppars.sipmopt[det], filekey_ch, part)

        # return results
        return result_ch
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_sipm_optimization = parallel(chinfo_unfolded, ch_sipm_optimization, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")
    
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