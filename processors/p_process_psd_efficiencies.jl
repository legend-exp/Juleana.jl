function p_process_psd_efficiencies(processing_config::PropDict, l200::LegendData, period::DataPeriod,; reprocess::Bool=false, timeout::Int=0, only_first_period::Bool=true)
    
    @info "Generate PSD efficiencies for all partitions containing period $period"

    rinfo = runinfo(l200, period) |> filterby(@pf $cal.is_analysis_run)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).cal.startkey
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true) |> filterby(@pf $low_aoe_status in [:valid, :present])
    @info "Loaded channel info with $(length(chinfo)) channels"

    if reprocess @info "Reprocess all channels" else @info "Only process channels not in pars_db" end

    # create log line Tuple
    log_nt_cut = NamedTuple{(:Channel, :Detector, :Partition, :Status, Symbol("Classifier Type"), Symbol("Cut Value"), Symbol("SEP SF"), Symbol("FEP SF"), :CutError)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # get unfolded channel info where each entry is a detector and its partition for all partitions that contain period
    chinfo_unfolded = get_partition_channelinfo(l200, chinfo, period; unfold_partitions=true)

    # flush stdout
    flush(stdout)
    
    function ch_psd_sf(chinfo_ch::NamedTuple)
        
        ch  = chinfo_ch.channel
        det = chinfo_ch.detector
        part = chinfo_ch.partition

        @info "Processing channel $ch ($det)"

        mkpath(joinpath(data_path(l200.par.ppars.psd), string(det)))
        pars_db_ch = if isfile(joinpath(data_path(l200.par.ppars.psd), "$det", "$part.json")) && !reprocess
            PropDict(l200.par.ppars.psd[det, part])
        else
            mkpath(joinpath(data_path(l200.par.ppars.psd), "$det"))
            PropDict()
        end

        partinfo_ch = partitioninfo(l200, ch, part)
        @debug "Loaded channel partition info with $(length(partinfo_ch)) runs"
    
        filekey_ch = start_filekey(l200, (first(partinfo_ch.period), first(partinfo_ch.run), :cal))
        @debug "Found filekey $filekey_ch"

        validity_ch = get_partitionvalidity(l200, ch, det, part, :cal)

        # load config
        psd_config = dataprod_config(l200).psd(filekey_ch).psd
        psd_config_ch = merge(psd_config.default, get(psd_config, det, PropDict()))
        @debug "Loaded psd config: $(psd_config_ch)"

        e_type = Symbol(psd_config_ch.e_type)
        psd_classifiers = collect(keys(psd_config_ch.psd_classifiers))
        psd_classifiers_dict = psd_config_ch.psd_classifiers

        result_dict = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        if (only_first_period && period != first(partinfo_ch.period))
            @info "Only first period in partition $part for $period in $ch ($det)"
            for psd_classifier in psd_classifiers
                log_info = log_nt_cut((ch, det, part, ProcessStatus(1), psd_classifier, fill("-", 3)..., "Only first periods --> skipped."))
                # add results to dict
                log_info_dict[psd_classifier] = log_info
                processed_dict[psd_classifier] = false
            end
            return (processed = processed_dict, log = log_info_dict, validity = validity_ch, skipped = true)
        end

        if !reprocess && haskey(pars_db_ch, det)
            @debug "Channel $(det) already processed, check missing filters"
            for psd_classifier in psd_classifiers
                if haskey(pars_db_ch[det], psd_classifier)
                    log_info = log_nt_cut((ch, det, part, ProcessStatus(1), psd_classifier, pars_db_ch[det][psd_classifier].cuts.lowcut, pars_db_ch[det][psd_classifier].peaks.ds[:Tl208SEP].sf, pars_db_ch[det][psd_classifier].peaks.ds[:Tl208FEP].sf, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[psd_classifier] = log_info
                    processed_dict[psd_classifier] = false
                end
            end
        end

        e_cal, hit_cal = nothing, nothing
        try
            hpge_kwargs = get_ged_evt_kwargs(l200, filekey_ch)
            if !all([haskey(processed_dict, psd_classifier) for psd_classifier in psd_classifiers])
                hit_cal = fast_flatten([
                    let dsp=read_ldata(:dataQC, l200, :jlhit, :cal, pinfo.period, pinfo.run, ch)
                        @debug "Calibrating $(pinfo.period)-$(pinfo.run)"
                        calibrate_ged_channel_data(l200, pinfo.cal.startkey, det, dsp; keep_chdata=true, hpge_kwargs...)
                    end
                    for pinfo in partinfo_ch])
                e_cal = getproperty(hit_cal, e_type)
            end
        catch e
            @error "E data for $det from cannot be loaded"
            throw(LoadError("E data", 154, "E data for $det from partition $(part) cannot be loaded: $(truncate_error(e))"))
        end

        e_unit = unit(eltype(e_cal))
        ones_vec = ones(length(e_cal))

        @showprogress desc="Detector: $det" for psd_classifier in psd_classifiers
            if haskey(processed_dict, psd_classifier)
                continue
            end
            try
                @debug "Generate $psd_classifier cut"

                aoe_classifier = Symbol(psd_classifiers_dict[psd_classifier][1])
                aoe_high_cut = psd_classifiers_dict[psd_classifier][2]
                lq_classifier = Symbol(psd_classifiers_dict[psd_classifier][3])

                aoe_low_cut_vec, aoe_high_cut_vec, aoe_ds_cut_vec = nothing, nothing, nothing
                try
                    aoe_low_cut_vec = .!getproperty(hit_cal, Symbol("$(aoe_classifier)_low_cut"))
                    aoe_high_cut_vec = .!(getproperty(hit_cal, Symbol("$(aoe_classifier)")) .> aoe_high_cut)
                    aoe_ds_cut_vec = .!(getproperty(hit_cal, Symbol("$(aoe_classifier)_low_cut")) .|| getproperty(hit_cal, Symbol("$(aoe_classifier)")) .> aoe_high_cut)
                catch e
                    @error "AoE for $det from cannot be loaded"
                    throw(LoadError("AoE", 154, "AoE and E data for $det from partition $(part) cannot be loaded"))
                end

                lq_high_cut_vec = nothing
                try
                    lq_high_cut_vec = .!getproperty(hit_cal, Symbol("$(lq_classifier)_high_cut"))
                catch e
                    @error "LQ for $det from cannot be loaded"
                    throw(LoadError("LQ", 154, "LQ data for $det from partition $(part) cannot be loaded"))
                end

                ## low A/E cut
                result_peaks_low, report_peaks_low = nothing, nothing
                try
                    @debug "Generate A/E low Survival Fractions"
                    result_peaks_low, report_peaks_low = get_peaks_survival_fractions(ones_vec, e_cal, psd_config_ch.psd_peaks, Symbol.(psd_config_ch.psd_peaks_names), psd_config_ch.psd_peaks_windows_left, psd_config_ch.psd_peaks_windows_right, -Inf, aoe_low_cut_vec; 
                                                    bin_width_window=psd_config_ch.psd_peaks_bin_width_window, sigma_high_sided=Inf, fit_funcs=Symbol.(psd_config_ch.psd_peaks_fit_funcs), uncertainty=true)
                catch e
                    @error "AoE peaks low SF for $det cannot be generated"
                    throw(ErrorException("AoE peaks low SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found low SEP Survival Fraction at $(round(u"percent", result_peaks_low[:Tl208SEP].sf, digits=2))"
                @debug "Found low FEP Survival Fraction at $(round(u"percent", result_peaks_low[:Tl208FEP].sf, digits=2))"

                qbb_result_low = nothing
                try
                    qbb_result_low, _ = get_continuum_survival_fraction(ones_vec, e_cal, psd_config_ch.qbb, psd_config_ch.qbb_window, -Inf, aoe_low_cut_vec,; sigma_high_sided=Inf)
                catch e
                    @error "Qbb low SF for $det cannot be generated"
                    throw(ErrorException("Qbb low SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found low Qbb Survival Fraction at $(round(u"percent", qbb_result_low.sf, digits=2))"



                ## high A/E cut
                result_peaks_high, report_peaks_high = nothing, nothing
                try
                    @debug "Generate A/E high Survival Fractions"
                    result_peaks_high, report_peaks_high = get_peaks_survival_fractions(ones_vec, e_cal, psd_config_ch.psd_peaks, Symbol.(psd_config_ch.psd_peaks_names), psd_config_ch.psd_peaks_windows_left, psd_config_ch.psd_peaks_windows_right, -Inf, aoe_high_cut_vec;
                                                    bin_width_window=psd_config_ch.psd_peaks_bin_width_window, sigma_high_sided=Inf, fit_funcs=Symbol.(psd_config_ch.psd_peaks_fit_funcs), uncertainty=true)
                catch e
                    @error "AoE peaks high SF for $det cannot be generated"
                    throw(ErrorException("AoE peaks high SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found high SEP Survival Fraction at $(round(u"percent", result_peaks_high[:Tl208SEP].sf, digits=2))"
                @debug "Found high FEP Survival Fraction at $(round(u"percent", result_peaks_high[:Tl208FEP].sf, digits=2))"

                qbb_result_high = nothing
                try
                    qbb_result_high, _ = get_continuum_survival_fraction(ones_vec, e_cal, psd_config_ch.qbb, psd_config_ch.qbb_window, -Inf, aoe_high_cut_vec,; sigma_high_sided=Inf)
                catch e
                    @error "Qbb high SF for $det cannot be generated"
                    throw(ErrorException("Qbb high SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found high Qbb Survival Fraction at $(round(u"percent", qbb_result_high.sf, digits=2))"



                ### low A/E cut & high A/E cut
                result_peaks_ds, report_peaks_ds = nothing, nothing
                try
                    @debug "Generate A/E DS Survival Fractions"
                    result_peaks_ds, report_peaks_ds = get_peaks_survival_fractions(ones_vec, e_cal, psd_config_ch.psd_peaks, Symbol.(psd_config_ch.psd_peaks_names), psd_config_ch.psd_peaks_windows_left, psd_config_ch.psd_peaks_windows_right, -Inf, aoe_ds_cut_vec; 
                                                    bin_width_window=psd_config_ch.psd_peaks_bin_width_window, fit_funcs=Symbol.(psd_config_ch.psd_peaks_fit_funcs), uncertainty=true)
                catch e
                    @error "AoE peaks DS SF for $det cannot be generated"
                    throw(ErrorException("AoE peaks DS SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found DS SEP Survival Fraction at $(round(u"percent", result_peaks_ds[:Tl208SEP].sf, digits=2))"
                @debug "Found DS FEP Survival Fraction at $(round(u"percent", result_peaks_ds[:Tl208FEP].sf, digits=2))"

                qbb_result_ds = nothing
                try
                    qbb_result_ds, _ = get_continuum_survival_fraction(ones_vec, e_cal, psd_config_ch.qbb, psd_config_ch.qbb_window, -Inf, aoe_ds_cut_vec)
                catch e
                    @error "Qbb DS SF for $det cannot be generated"
                    throw(ErrorException("Qbb DS SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found DS Qbb Survival Fraction at $(round(u"percent", qbb_result_ds.sf, digits=2))"




                ### low A/E cut & LQ cut
                result_peaks_low_lq, report_peaks_low_lq = nothing, nothing
                try
                    @debug "Generate A/E DS Survival Fractions"
                    result_peaks_low_lq, report_peaks_low_lq = get_peaks_survival_fractions(ones_vec, e_cal, psd_config_ch.psd_peaks, Symbol.(psd_config_ch.psd_peaks_names), psd_config_ch.psd_peaks_windows_left, psd_config_ch.psd_peaks_windows_right, -Inf, aoe_low_cut_vec .&& lq_high_cut_vec; 
                                                    bin_width_window=psd_config_ch.psd_peaks_bin_width_window, sigma_high_sided=Inf, fit_funcs=Symbol.(psd_config_ch.psd_peaks_fit_funcs), uncertainty=true)
                catch e
                    @error "AoE peaks DS SF for $det cannot be generated"
                    throw(ErrorException("AoE peaks DS SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found LQ DS SEP Survival Fraction at $(round(u"percent", result_peaks_low_lq[:Tl208SEP].sf, digits=2))"
                @debug "Found LQ DS FEP Survival Fraction at $(round(u"percent", result_peaks_low_lq[:Tl208FEP].sf, digits=2))"

                qbb_result_low_lq = nothing
                try
                    qbb_result_low_lq, _ = get_continuum_survival_fraction(ones_vec, e_cal, psd_config_ch.qbb, psd_config_ch.qbb_window, -Inf, aoe_low_cut_vec .&& lq_high_cut_vec; sigma_high_sided=Inf)
                catch e
                    @error "Qbb DS SF for $det cannot be generated"
                    throw(ErrorException("Qbb DS SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found DS Qbb Survival Fraction at $(round(u"percent", qbb_result_low_lq.sf, digits=2))"





                ### low A/E cut & high A/E cut & LQ cut
                result_peaks_lq_ds, report_peaks_lq_ds = nothing, nothing
                try
                    @debug "Generate A/E DS Survival Fractions"
                    result_peaks_lq_ds, report_peaks_lq_ds = get_peaks_survival_fractions(ones_vec, e_cal, psd_config_ch.psd_peaks, Symbol.(psd_config_ch.psd_peaks_names), psd_config_ch.psd_peaks_windows_left, psd_config_ch.psd_peaks_windows_right, -Inf, aoe_ds_cut_vec .&& lq_high_cut_vec; 
                                                    bin_width_window=psd_config_ch.psd_peaks_bin_width_window, sigma_high_sided=Inf, fit_funcs=Symbol.(psd_config_ch.psd_peaks_fit_funcs), uncertainty=true)
                catch e
                    @error "AoE peaks DS SF for $det cannot be generated"
                    throw(ErrorException("AoE peaks DS SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found LQ DS SEP Survival Fraction at $(round(u"percent", result_peaks_lq_ds[:Tl208SEP].sf, digits=2))"
                @debug "Found LQ DS FEP Survival Fraction at $(round(u"percent", result_peaks_lq_ds[:Tl208FEP].sf, digits=2))"

                qbb_result_lq_ds = nothing
                try
                    qbb_result_lq_ds, _ = get_continuum_survival_fraction(ones_vec, e_cal, psd_config_ch.qbb, psd_config_ch.qbb_window, -Inf, aoe_ds_cut_vec .&& lq_high_cut_vec; sigma_high_sided=Inf)
                catch e
                    @error "Qbb DS SF for $det cannot be generated"
                    throw(ErrorException("Qbb DS SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found DS Qbb Survival Fraction at $(round(u"percent", qbb_result_lq_ds.sf, digits=2))"

                # p = LegendMakie.lplot(report_peaks_ds, titlesize = 17, figsize = (600, 400*length(report_peaks_ds)), title = get_plottitle(filekey_ch, part, det, "A/E Performance"; additional_type=string(psd_classifier)))
                # savelfig(LegendMakie.lsavefig, p, l200, part, filekey_ch, det, Symbol("aoe_peaks_sf_$psd_classifier"))

                # save results
                result = merge((cuts = (lowcut = NaN, highcut = aoe_high_cut, lq = NaN), ), (peaks = (low = result_peaks_low, high = result_peaks_high, ds = result_peaks_ds, low_lq = result_peaks_low_lq, lq_ds = result_peaks_lq_ds) , qbb = (low = qbb_result_low, high = qbb_result_high, ds = qbb_result_ds, low_lq = qbb_result_low_lq, lq_ds = qbb_result_lq_ds)))

                log_info = log_nt_cut((ch, det, part, ProcessStatus(1), psd_classifier, NaN, result.peaks.ds[:Tl208SEP].sf, result.peaks.ds[:Tl208FEP].sf, "-"))

                # add results to dict
                result_dict[psd_classifier]   = result
                log_info_dict[psd_classifier] = log_info
                processed_dict[psd_classifier] = true

                GC.gc()
            catch e
                @error "Error in $psd_classifier cut generation: $(truncate_error(e))"
                log_info = log_nt_cut((ch, det, part, ProcessStatus(0), psd_classifier, "-", "-", "-", truncate_error(e)))
                
                # add results to dict
                log_info_dict[psd_classifier] = log_info
                processed_dict[psd_classifier] = false
            end
        end
        # cleanup log and combine
        result_ch = (result = result_dict, processed = processed_dict, log = log_info_dict, validity = validity_ch)
        result_psd_ch = Dict{NamedTuple, NamedTuple}(chinfo_ch => result_ch)

        pars_db_ch = create_pars(pars_db_ch, result_psd_ch)
        if !isempty(pars_db_ch)
            writelprops(l200.par.ppars.psd[det], part, pars_db_ch)
            writevalidity(l200.par.ppars.psd[det], filekey_ch, part)
        end

        return result_ch
    end

    # get start time
    start_time = now()

    result_psd = parallel(chinfo_unfolded, ch_psd_sf, log_nt_cut, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")
    @info "Finished AoE cut generation"

    @info "Write $period validity"
    validity_all = create_validity(result_psd)
    writevalidity(l200.par.ppars.psd, validity_all)


    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, aoe_part_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_psd))

    @info "Write log report"
    writelreport(get_preportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    # flush stdout
    flush(stdout)

    return any(x -> get(last(x), :skipped, false), values(result_psd))
end

