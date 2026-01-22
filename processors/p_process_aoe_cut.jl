function p_process_aoe_cut(processing_config::PropDict, l200::LegendData, period::DataPeriod,; reprocess::Bool=false, timeout::Int=0, only_first_period::Bool=true)
    
    @info "Generate AoE cut for all partitions containing period $period"

    rinfo = runinfo(l200, period) |> filterby(@pf $cal.is_analysis_run)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).cal.startkey
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true) |> filterby(@pf $low_aoe_status in [:valid, :present])
    @info "Loaded channel info with $(length(chinfo)) channels"

    if reprocess @info "Reprocess all channels" else @info "Only process channels not in pars_db" end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :Channel, :Partition, :Status, Symbol("Classifier Type"), Symbol("Cut Value"), Symbol("SEP SF"), Symbol("FEP SF"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # get unfolded channel info where each entry is a detector and its partition for all partitions that contain period
    chinfo_unfolded = get_partition_channelinfo(l200, chinfo, period, :cal; unfold_partitions=true)

    # flush stdout
    flush(stdout)
    
    function det_aoe_cut(chinfo_det::NamedTuple)
        
        ch  = chinfo_det.channel
        det = chinfo_det.detector
        part = chinfo_det.partition

        @info "Processing detector $det ($ch)"

        mkpath(joinpath(data_path(l200.par.ppars.aoecut), string(det)))
        pars_db_det = if isfile(joinpath(data_path(l200.par.ppars.aoecut), "$det", "$part.yaml")) && !reprocess
            PropDict(l200.par.ppars.aoecut[det, part])
        else
            mkpath(joinpath(data_path(l200.par.ppars.aoecut), "$det"))
            PropDict()
        end

        partinfo_det = partitioninfo(l200, det, part)
        @debug "Loaded channel partition info with $(length(partinfo_det)) runs"
    
        filekey_det = start_filekey(l200, (first(partinfo_det.period), first(partinfo_det.run), :cal))
        @debug "Found filekey $filekey_det"

        validity_det = get_partitionvalidity(l200, det, part)

        # load config
        aoe_config = dataprod_config(l200).psd(filekey_det).aoe
        aoe_config_det = merge(aoe_config.p_default, get(aoe_config.p, det, PropDict()))
        @debug "Loaded aoe config: $(aoe_config_det)"

        aoe_classifiers = Symbol.(aoe_config_det.aoe_classifiers)
        e_type         = Symbol(aoe_config_det.e_type)

        # sigma_high_sided = ifelse(chinfo_det.high_aoe_status == :valid, aoe_config_det.sigma_high_sided, Inf)
        sigma_high_sided = aoe_config_det.sigma_high_sided

        result_dict = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        if (only_first_period && period != first(partinfo_det.period))
            @info "Only first period in partition $part for $period in $det ($ch)"
            for aoe_classifier in aoe_classifiers
                log_info = log_nt((det, ch, part, ProcessStatus(1), aoe_classifier, fill("-", 3)..., "Only first periods --> skipped."))
                # add results to dict
                log_info_dict[aoe_classifier] = log_info
                processed_dict[aoe_classifier] = false
            end
            return (processed = processed_dict, log = log_info_dict, validity = validity_det, skipped = true)
        end

        if !reprocess && haskey(pars_db_det, det)
            @debug "Detector $(det) already processed, check missing filters"
            for aoe_classifier in aoe_classifiers
                if haskey(pars_db_det[det], aoe_classifier)
                    log_info = log_nt((det, ch, part, ProcessStatus(1), aoe_classifier, pars_db_det[det][aoe_classifier].lowcut, pars_db_det[det][aoe_classifier].peaks.ds[:Tl208SEP].sf, pars_db_det[det][aoe_classifier].peaks.ds[:Tl208FEP].sf, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[aoe_classifier] = log_info
                    processed_dict[aoe_classifier] = false
                end
            end
        end

        e_cal, hit_cal = nothing, nothing
        try
            if !all([haskey(processed_dict, aoe_classifier) for aoe_classifier in aoe_classifiers])
                hit_cal = fast_flatten([begin
                    @debug "Reading from $(pinfo.period)-$(pinfo.run)"
                    calibrate_ged_detector_data(l200, pinfo.cal.startkey, det, read_ldata(:dataQC, l200, :jlhit, :cal, pinfo.period, pinfo.run, det).dataQC; psd_cal_pars_type=:rpars, psd_cal_pars_cat=:aoe) end
                    for pinfo in partinfo_det])
                e_cal = getproperty(hit_cal, e_type)
            end
        catch e
            @error "E data for $det from cannot be loaded"
            throw(LoadError("E data", 154, "E data for $det from partition $(part) cannot be loaded"))
        end

        e_unit = unit(first(e_cal))

        @showprogress desc="Detector: $det" for aoe_classifier in aoe_classifiers
            if haskey(processed_dict, aoe_classifier)
                continue
            end
            try
                @debug "Generate $aoe_classifier cut"

                aoe = nothing
                try
                    aoe = getproperty(hit_cal, aoe_classifier)
                catch e
                    @error "AoE for $det from cannot be loaded"
                    throw(LoadError("AoE", 154, "AoE and E data for $det from partition $(part) cannot be loaded"))
                end

                h_aoe_ctc = fit(Histogram, (ustrip.(e_unit, e_cal), aoe), (0:0.5:3000, -20:0.1:10))
                p = LegendMakie.lhist(h_aoe_ctc, figsize = (670,400), rasterize = true,
                    title = get_plottitle(filekey_det, part, det, ""; additional_type=string(aoe_classifier)),
                    xlabel = "Energy ($e_unit)",
                    ylabel = "A/E",
                    xticks = 0:500:3000,
                    yticks = -20:10:10
                )
                savelfig(LegendMakie.lsavefig, p, l200, part, filekey_det, det, Symbol("aoe_normalized_runcal_$aoe_classifier"))

                result_cut, report_cut = nothing, nothing
                try
                    @debug "Generate AoE cut"
                    result_cut, report_cut = get_low_aoe_cut(aoe, e_cal,; dep=aoe_config_det.dep, window=aoe_config_det.dep_window, 
                                    cut_search_interval=Tuple(aoe_config_det.dep_cut_search_interval), bin_width_window=aoe_config_det.dep_bin_width_window,
                                    rtol=aoe_config_det.dep_cut_search_rtol, maxiters=aoe_config_det.dep_cut_search_maxiters, dep_sf=aoe_config_det.dep_cut_search_target_sf,
                                    fixed_position=aoe_config_det.dep_cut_search_fixed_position, sigma_high_sided=sigma_high_sided,
                                    fit_func=Symbol(aoe_config_det.dep_cut_search_fit_func), uncertainty=true)
                catch e
                    @error "AoE cut for $det cannot be generated"
                    throw(ErrorException("AoE cut for $det from $period-$run cannot be generated"))
                end

                @debug "Found low A/E cut at $(round(result_cut.lowcut, digits=2)) and high A/E cut at $(round(result_cut.highcut, digits=2))"

                # plot spectrum before and after cut
                p = LegendMakie.lplot(report_cut, figsize = (750,400), title = get_plottitle(filekey_det, part, det, "A/E Performance"; additional_type=string(aoe_classifier)))
                savelfig(LegendMakie.lsavefig, p, l200, part, filekey_det, det, Symbol("aoe_energy_afterAoE_zoom_runcal_$aoe_classifier"))

                result_peaks_low, report_peaks_low = nothing, nothing
                try
                    @debug "Generate A/E low Survival Fractions"
                    result_peaks_low, report_peaks_low = get_peaks_survival_fractions(aoe, e_cal, aoe_config_det.aoe_peaks, Symbol.(aoe_config_det.aoe_peaks_names), aoe_config_det.aoe_peaks_windows_left, aoe_config_det.aoe_peaks_windows_right, result_cut.lowcut,; 
                                                    bin_width_window=aoe_config_det.aoe_peaks_bin_width_window, sigma_high_sided=Inf, fit_funcs=Symbol.(aoe_config_det.aoe_peaks_fit_funcs), uncertainty=true)
                catch e
                    @error "AoE peaks low SF for $det cannot be generated"
                    throw(ErrorException("AoE peaks low SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found low SEP Survival Fraction at $(round(u"percent", result_peaks_low[:Tl208SEP].sf, digits=2))"
                @debug "Found low FEP Survival Fraction at $(round(u"percent", result_peaks_low[:Tl208FEP].sf, digits=2))"

                qbb_result_low = nothing
                try
                    qbb_result_low, _ = get_continuum_survival_fraction(aoe, e_cal, aoe_config_det.qbb, aoe_config_det.qbb_window, result_cut.lowcut,; sigma_high_sided=Inf)
                catch e
                    @error "Qbb low SF for $det cannot be generated"
                    throw(ErrorException("Qbb low SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found low Qbb Survival Fraction at $(round(u"percent", qbb_result_low.sf, digits=2))"

                result_peaks_ds, report_peaks_ds = nothing, nothing
                try
                    @debug "Generate A/E DS Survival Fractions"
                    result_peaks_ds, report_peaks_ds = get_peaks_survival_fractions(aoe, e_cal, aoe_config_det.aoe_peaks, Symbol.(aoe_config_det.aoe_peaks_names), aoe_config_det.aoe_peaks_windows_left, aoe_config_det.aoe_peaks_windows_right, result_cut.lowcut,; 
                                                    bin_width_window=aoe_config_det.aoe_peaks_bin_width_window, sigma_high_sided=result_cut.highcut, fit_funcs=Symbol.(aoe_config_det.aoe_peaks_fit_funcs), uncertainty=true)
                catch e
                    @error "AoE peaks DS SF for $det cannot be generated"
                    throw(ErrorException("AoE peaks DS SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found DS SEP Survival Fraction at $(round(u"percent", result_peaks_ds[:Tl208SEP].sf, digits=2))"
                @debug "Found DS FEP Survival Fraction at $(round(u"percent", result_peaks_ds[:Tl208FEP].sf, digits=2))"

                qbb_result_ds = nothing
                try
                    qbb_result_ds, _ = get_continuum_survival_fraction(aoe, e_cal, aoe_config_det.qbb, aoe_config_det.qbb_window, result_cut.lowcut,; sigma_high_sided=result_cut.highcut)
                catch e
                    @error "Qbb DS SF for $det cannot be generated"
                    throw(ErrorException("Qbb DS SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found DS Qbb Survival Fraction at $(round(u"percent", qbb_result_ds.sf, digits=2))"

                p = LegendMakie.lplot(report_peaks_ds, figsize = (600, 400*length(report_peaks_ds)), title = get_plottitle(filekey_det, part, det, "A/E Performance"; additional_type=string(aoe_classifier)))
                savelfig(LegendMakie.lsavefig, p, l200, part, filekey_det, det, Symbol("aoe_peaks_sf_runcal_$aoe_classifier"))

                # save results
                result = merge(result_cut, (peaks = (low = result_peaks_low, ds = result_peaks_ds) , qbb = (low = qbb_result_low, ds = qbb_result_ds)))

                log_info = log_nt((det, ch, part, ProcessStatus(1), aoe_classifier, result_cut.lowcut, result.peaks.ds[:Tl208SEP].sf, result.peaks.ds[:Tl208FEP].sf, "-"))

                # add results to dict
                result_dict[aoe_classifier]   = result
                log_info_dict[aoe_classifier] = log_info
                processed_dict[aoe_classifier] = true

                GC.gc()
            catch e
                @error "Error in $aoe_classifier cut generation: $(truncate_error(e))"
                log_info = log_nt((det, ch, part, ProcessStatus(0), aoe_classifier, "-", "-", "-", truncate_error(e)))
                
                # add results to dict
                log_info_dict[aoe_classifier] = log_info
                processed_dict[aoe_classifier] = false
            end
        end

        result_det = (result = result_dict, processed = processed_dict, log = log_info_dict, validity = validity_det)
        result_aoe_cut_det = Dict{NamedTuple, NamedTuple}(chinfo_det => result_det)

        pars_db_det = create_pars(pars_db_det, result_aoe_cut_det)
        writelprops(l200.par.ppars.aoecut[det], part, pars_db_det)
        writevalidity(l200.par.ppars.aoecut[det], filekey_det, part)

        return result_det
    end

    # get start time
    start_time = now()

    result_aoe = parallel(chinfo_unfolded, det_aoe_cut, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")
    @info "Finished AoE cut generation"

    @info "Write $period validity"
    validity_all = create_validity(result_aoe)
    writevalidity(l200.par.ppars.aoecut, validity_all)

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, aoe_part_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_aoe))

    @info "Write log report"
    writelreport(get_preportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report
    
    # flush stdout
    flush(stdout)

    return any(x -> get(last(x), :skipped, false), values(result_aoe))
end

