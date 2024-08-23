function p_process_aoe_calibration_cut(processing_config::PropDict, l200::LegendData, period::DataPeriod,; reprocess::Bool=false, timeout::Int=0, only_first_period::Bool=true)
    
    @info "Generate AoE cut for all partitions containing period $period"

    rinfo = runinfo(l200, period)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).cal.startkey
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true) |> filterby(@pf $low_aoe_status .== :valid)
    @info "Loaded channel info with $(length(chinfo)) channels"

    if reprocess @info "Reprocess all channels" else @info "Only process channels not in pars_db" end

    # create log line Tuple
    log_nt_cal = NamedTuple{(:Channel, :Detector, :Partition, :Status, Symbol("Filter Type"), Symbol("Number of fitted Bands"), Symbol("μ Correction Mean normalized Residuals"), Symbol("σ Correction Mean normalized Residuals"), :CalError)}
    log_nt_cut = NamedTuple{(:Channel, :Detector, :Partition, :Status, Symbol("Classifier Type"), Symbol("Cut Value"), Symbol("SEP SF"), Symbol("FEP SF"), :CutError)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # get unfolded channel info where each entry is a detector and its partition for all partitions that contain period
    chinfo_unfolded = get_partition_channelinfo(l200, chinfo, period; unfold_partitions=true)

    # flush stdout
    flush(stdout)
    
    function ch_aoe_cut(chinfo_ch::NamedTuple)
        
        ch  = chinfo_ch.channel
        det = chinfo_ch.detector
        part = chinfo_ch.partition

        @info "Processing channel $ch ($det)"

        mkpath(joinpath(data_path(l200.par.ppars.aoe), string(det)))
        pars_db_ch = if isfile(joinpath(data_path(l200.par.ppars.aoe[det]), "$part.json"))
            PropDict(l200.par.ppars.aoe[det, part])
        else
            PropDict()
        end

        partinfo_ch = partitioninfo(l200, ch, part)
        @debug "Loaded channel partition info with $(length(partinfo_ch)) runs"
    
        filekey_ch = start_filekey(l200, (first(partinfo_ch.period), first(partinfo_ch.run), :cal))
        @debug "Found filekey $filekey_ch"

        validity_ch = get_partitionvalidity(l200, ch, det, part, :cal)

        # load config
        aoe_config = dataprod_config(l200).psd(filekey_ch).aoe
        aoe_config_ch = merge(aoe_config.p_default, get(aoe_config.p, det, PropDict()))
        @debug "Loaded aoe config: $(aoe_config_ch)"

        compton_bands  = aoe_config_ch.compton_bands
        compton_window = aoe_config_ch.compton_window
        p_value_cut    = aoe_config_ch.p_value # what is this? p values threshold 
        e_type         = Symbol(aoe_config_ch.e_type)
        aoe_types      = collect(keys(aoe_config_ch.aoe_funcs))
        aoe_funcs      = aoe_config_ch.aoe_funcs

        aoe_classifiers = Symbol.(aoe_config_ch.aoe_classifiers)
        e_type         = Symbol(aoe_config_ch.e_type)

        sigma_high_sided = ifelse(chinfo_ch.high_aoe_status == :valid, aoe_config_ch.sigma_high_sided, NaN)

        result_dict = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        if (only_first_period && period != first(partinfo_ch.period))
            @info "Only first period in partition $part for $period in $ch ($det)"
            for aoe_type in aoe_types
                log_info = log_nt_cal((ch, det, part, ProcessStatus(1), aoe_type, fill("-", 3)..., "Only first periods --> skipped."))
                # add results to dict
                log_info_dict[aoe_type] = log_info
                processed_dict[aoe_type] = false
            end
            for aoe_classifier in aoe_classifiers
                log_info = log_nt_cut((ch, det, part, ProcessStatus(1), aoe_classifier, fill("-", 3)..., "Only first periods --> skipped."))
                # add results to dict
                log_info_dict[aoe_classifier] = log_info
                processed_dict[aoe_classifier] = false
            end
            return (processed = processed_dict, log = log_info_dict, validity = validity_ch, skipped = true)
        end

        if !reprocess && haskey(pars_db_ch, det)
            @debug "Channel $(det) already processed, check missing filters"
            for aoe_type in aoe_types
                if !haskey(pars_db[det], aoe_type)
                    pars_db_det_aoe_type = pars_db[det][aoe_type]
                    log_ch = log_nt_cal(ch, det, part, ProcessStatus(1), aoe_type, length(pars_db_det_aoe_type.μ_compton.μ), mean(pars_db_det_aoe_type.µ_compton.gof.residuals_norm), mean(pars_db_det_aoe_type.σ_compton.gof.residuals_norm), "Already processed --> skipped.")
                    processed_dict[aoe_type] = false
                    log_info_dict[aoe_type] = log_ch
                end
            end
            for aoe_classifier in aoe_classifiers
                if haskey(pars_db_ch[det], aoe_classifier)
                    log_info = log_nt((ch, det, part, ProcessStatus(1), aoe_classifier, pars_db_ch[det][aoe_classifier].lowcut, pars_db_ch[det][aoe_classifier].peaks[:Tl208SEP].sf, pars_db_ch[det][aoe_classifier].peaks[:Tl208FEP].sf, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[aoe_classifier] = log_info
                    processed_dict[aoe_classifier] = false
                end
            end
        end

        e_cal, hit_cal = nothing, nothing
        try
            hit_cal = fast_flatten([begin
                @debug "Reading from $(pinfo.period)-$(pinfo.run)"
                calibrate_ged_channel_data(l200, pinfo.cal.startkey, det, read_ldata(:dataQC, l200, :jlhit, :cal, pinfo.period, pinfo.run, ch); keep_chdata=true) end
                for pinfo in partinfo_ch])
            e_cal = getproperty(hit_cal, e_type)
        catch e
            @error "E data for $det from cannot be loaded"
            throw(LoadError("E data", 154, "E data for $det from partition $(part) cannot be loaded"))
        end

        @showprogress desc="Detector: $det" for aoe_type in aoe_types
            if haskey(processed_dict, aoe_type)
                continue
            end
            try
                @debug "Calibrate $aoe_type"

                # get data
                aoe, aoe_expression = nothing, nothing
                try
                    aoe = ljl_propfunc(aoe_funcs[aoe_type]).(hit_cal)
                    cuts_aoe = cut_single_peak(aoe, 0.0, quantile(filter(isfinite, aoe), 0.99); n_bins=-1)
                    aoe ./= cuts_aoe.max
                    aoe_expression = "$(aoe_funcs[aoe_type]) / $(cuts_aoe.max)"
                catch e
                    @error "Error in $aoe_type simple normalization for channel $ch: $(truncate_string(string(e)))"
                    throw(ErrorException("Error in $aoe_type simple normalization"))
                end
                GC.gc()

                p = histogram2d(e_cal, aoe, nbins=(0:0.5:3000, 0.1:5e-3:1.8), xlims=(0, 3000), ylims=(0.1, 1.8), size=(1200, 800), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy", ylabel="A/E (a.u.)", margin=5mm)
                plot!(p, guidefontsize=18, xguidefontsize=18,yguidefontsize = 18,xtickfontsize = 12,ytickfontsize=12)
                xticks!(p, 0:250:3000)
                title!(p, get_plottitle(filekey_ch, part, det, "AoE uncalibrated"; additiional_type=string(aoe_type)))
                savelfig(savefig, p, l200, part, filekey_ch, det, Symbol("aoe_uncalibrated_$aoe_type"))

                result_fit, report_fit, compton_band_peakhists = nothing, nothing, nothing
                try
                    # get compton band peak histograms with generated peakstats
                    compton_band_peakhists = generate_aoe_compton_bands(aoe, e_cal, compton_bands, compton_window)

                    result_fit, report_fit = fit_aoe_compton(compton_band_peakhists.peakhists, compton_band_peakhists.peakstats, compton_bands,; uncertainty=true)
                catch e
                    @error "AoE compton bands cannot be fitted: $(truncate_string(string(e)))"
                    throw(ErrorException("AoE compton bands cannot be fitted"))
                end
                GC.gc()

                compton_bands = filter(band -> result_fit[band].gof.pvalue >= p_value_cut, [band for band in keys(result_fit) if result_fit[band].gof.converged])
                μ = [result_fit[band].μ for band in compton_bands]
                σ = [result_fit[band].σ for band in compton_bands]

                # fit μ and σ with correction functions
                result_correction, report_correction = nothing, nothing
                try
                    result_correction, report_correction = fit_aoe_corrections(compton_bands, μ, σ,; aoe_expression = aoe_expression, e_expression = e_type)
                catch e
                    @error "AoE corrections cannot be fitted: $(truncate_string(string(e)))"
                    throw(ErrorException("AoE corrections cannot be fitted"))
                end
                
                p = plot(report_correction.report_µ)
                title!(p, get_plottitle(filekey_ch, part, det, "A/E μ"; additiional_type=string(aoe_type)), subplot=1)
                savelfig(savefig, p, l200, part, filekey_ch, det, Symbol("compton_bands_mu_$aoe_type"))

                p = plot(report_correction.report_σ)
                title!(p, get_plottitle(filekey_ch, part, det, "A/E σ"; additiional_type=string(aoe_type)), subplot=1)
                savelfig(savefig, p, l200, part, filekey_ch, det, Symbol("compton_bands_sigma_$aoe_type"))

                # correct aoe
                aoe_corr = ljl_propfunc(result_correction.func).(hit_cal)
                p = histogram2d(e_cal, aoe_corr, nbins=(0:0.5:3000, -30:0.1:10), xlims=(0, 3000), ylims=(-30, 10), size=(1300, 700), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy", ylabel=L"A/E\ (\sigma_{A/E})")
                plot!(margin=1mm, thickness_scaling=1.6, dpi=300, framestyle=:box)
                xticks!(0:250:3000)
                title!(p, get_plottitle(filekey, det, "normalized A/E"; additiional_type=string(aoe_type)))
                savelfig(savefig, p, l200, part, filekey_ch, det, Symbol("aoe_normalized_$aoe_type"))

                log_info = log_nt_cal(ch, det, part, ProcessStatus(1), aoe_type, length(compton_bands), mean(result_correction.µ_compton.gof.residuals_norm), mean(result_correction.σ_compton.gof.residuals_norm), "-")

                # add results to dict
                result_dict[aoe_type]   = result_correction
                log_info_dict[aoe_type] = log_info
                processed_dict[aoe_type] = true

                # free memory
                GC.gc()
            catch e
                @error "Error in $aoe_type calibration: $(truncate_string(string(e)))"
                log_info = log_nt_cal((ch, det, part, ProcessStatus(0), aoe_type, "-", "-", "-", truncate_string(string(e))))
                # add results to dict
                log_info_dict[aoe_type] = log_info
                processed_dict[aoe_type] = false
            end
        end

        # add calbiration results to pars_db
        result_ch = (result = result_dict, processed = processed_dict, log = log_info_dict, validity = validity_ch)
        result_aoe_ch = Dict{NamedTuple, NamedTuple}(chinfo_ch => result_ch)

        pars_db_ch = create_pars(pars_db_ch, result_aoe_ch)

        @showprogress desc="Detector: $det" for aoe_classifier in aoe_classifiers
            if haskey(processed_dict, aoe_classifier)
                continue
            end
            try
                @debug "Generate $aoe_classifier cut"

                aoe = nothing                
                try
                    aoe = ljl_propfunc(pars_db_ch[det][Symbol(first(split(string(aoe_classifier), "_classifier")))].func).(hit_cal)
                catch e
                    @error "AoE for $det from cannot be loaded"
                    throw(LoadError("AoE", 154, "AoE and E data for $det from partition $(part) cannot be loaded"))
                end

                p = histogram2d(e_cal, aoe, nbins=(0:0.5:3000, -20:0.1:10), xlims=(0, 3000), ylims=(-20, 10), size=(1300, 700), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel=L"Energy\ (keV)", ylabel=L"A/E\ (\sigma_{A/E})")
                plot!(margin=1mm, thickness_scaling=1.6, dpi=600)
                title!(p, get_plottitle(filekey_ch, part, det, "normalized A/E"; additiional_type=string(aoe_classifier)))
                xticks!(0:250:3000)
                savelfig(savefig, p, l200, part, filekey_ch, det, Symbol("aoe_normalized_$aoe_classifier"))

                result_cut = nothing
                try
                    @debug "Generate AoE cut"
                    result_cut = get_aoe_cut(aoe, e_cal,; dep=aoe_config_ch.dep, window=aoe_config_ch.dep_window, cut_search_interval=Tuple(aoe_config_ch.dep_cut_search_interval), rtol=aoe_config_ch.dep_cut_search_rtol, bin_width_window=aoe_config_ch.dep_bin_width_window, fixed_position=aoe_config_ch.dep_cut_search_fixed_position, sigma_high_sided=sigma_high_sided)
                catch e
                    @error "AoE cut for $det cannot be generated"
                    throw(ErrorException("AoE cut for $det from partition $(part) cannot be generated"))
                end

                @debug "Found low A/E cut at $(round(result_cut.lowcut, digits=2)) and high A/E cut at $(round(result_cut.highcut, digits=2))"

                result_peaks, report_peaks = nothing, nothing
                try
                    @debug "Generate AoE Surrival Fractions"
                    result_peaks, report_peaks = get_peaks_surrival_fractions(aoe, e_cal, aoe_config_ch.aoe_peaks, Symbol.(aoe_config_ch.aoe_peaks_names), aoe_config_ch.aoe_peaks_windows_left, aoe_config_ch.aoe_peaks_windows_right, result_cut.lowcut,; bin_width_window=3.0u"keV", low_e_tail=true, sigma_high_sided=sigma_high_sided)
                catch e
                    @error "AoE peaks SF for $det cannot be generated"
                    throw(ErrorException("AoE peaks SF for $det from partition $(part) cannot be generated"))
                end

                @debug "Found SEP Surrival Fraction at $(round(u"percent", result_peaks[:Tl208SEP].sf, digits=2))"
                @debug "Found FEP Surrival Fraction at $(round(u"percent", result_peaks[:Tl208FEP].sf, digits=2))"

                p = plot(broadcast(k -> plot(report_peaks[k].after, show_components=false, left_margin=20mm, top_margin=-5mm, bottom_margin=-2mm, peak_name=string(k), ms=2), keys(report_peaks))..., layout=(length(report_peaks), 1), size=(1000,710*length(report_peaks)) , thickness_scaling=1.8, titlefontsize = 10, legendfontsize = 8, yguidefontsize = 9, xguidefontsize=11)
                plot!(plot_title=get_plottitle(filekey_ch, part, det, "A/E Performance"; additiional_type=string(aoe_classifier)), plot_titlelocation=(0.5,0.2), plot_titlefontsize = 9)
                savelfig(savefig, p, l200, part, filekey_ch, det, Symbol("aoe_peaks_sf_$aoe_classifier"))

                qbb_result = nothing
                try
                    qbb_result = get_continuum_surrival_fraction(aoe, e_cal, aoe_config_ch.qbb, aoe_config_ch.qbb_window, result_cut.lowcut,; sigma_high_sided=sigma_high_sided)
                catch e
                    @error "Qbb SF for $det cannot be generated"
                    throw(ErrorException("Qbb SF for $det from partition $(part) cannot be generated"))
                end

                p = stephist(e_cal, nbins=2039-35:0.5:2039+35, label="Before", xlabel="Energy", ylabel="Counts / 0.5 keV", yscale=:log10)
                stephist!(e_cal[aoe .> result_cut.lowcut], nbins=2039-35:0.5:2039+35, label="After", xlabel="Energy", ylabel="Counts / 0.5 keV", yscale=:log10)
                plot!(margin=1mm, thickness_scaling=1.5, dpi=600, size=(1000, 700), framestyle=:box)
                title!("Qbb CC ($(qbb_result.window)) - SF: $(qbb_result.sf)", titlefontisze=8)
                plot!(plot_title=get_plottitle(filekey_ch, part, det, "A/E Performance"; additiional_type=string(aoe_classifier)), plot_titlefontsize = 12)
                savelfig(savefig, p, l200, part, filekey_ch, det, Symbol("aoe_qbb_sf_$aoe_classifier"))

                # plot spectrum before and after cut
                p = stephist(e_cal, nbins=0:0.5:3000, yscale=:log10, xlabel="Energy", label="Before AoE", ylabel="Counts / 0.5 keV", framestyle=:box)
                stephist!(e_cal[result_cut.lowcut .< aoe .< result_cut.highcut], nbins=0:0.5:3000, yscale=:log10, label="After AoE")
                stephist!(e_cal, nbins=1550:0.5:1700, inset = (1, bbox(0.2, 0.72, 0.4, 0.2, :top)), subplot = 2, framestyle=:box)
                stephist!(e_cal[result_cut.lowcut .< aoe .< result_cut.highcut], nbins=1550:0.5:1700, subplot = 2, legend=:none, ylabel="Counts / 0.5 keV", xlabel="")
                xticks!(0:250:3000, subplot = 1)
                xticks!(1500:20:1700, subplot = 2)
                title!(get_plottitle(filekey_ch, part, det, "A/E Performance"; additiional_type=string(aoe_classifier)), subplot=1)
                plot!(margin=1mm, thickness_scaling=1.2, dpi=600, size=(1000, 600))
                plot!(ylabelfontsize=8, subplot=2)
                savelfig(savefig, p, l200, part, filekey_ch, det, Symbol("aoe_energy_afterAoE_zoom_$aoe_classifier"))

                # save results
                result = merge(result_cut, (peaks = result_peaks, ), qbb_result)

                log_info = log_nt_cut((ch, det, part, ProcessStatus(1), aoe_classifier, result_cut.lowcut, result.peaks[:Tl208SEP].sf, result.peaks[:Tl208FEP].sf, "-"))

                # add results to dict
                result_dict[aoe_classifier]   = result
                log_info_dict[aoe_classifier] = log_info
                processed_dict[aoe_classifier] = true

                GC.gc()
            catch e
                @error "Error in $aoe_classifier cut generation: $(truncate_string(string(e)))"
                log_info = log_nt_cut((ch, det, part, ProcessStatus(0), aoe_classifier, "-", "-", "-", truncate_string(string(e))))
                
                # add results to dict
                log_info_dict[aoe_classifier] = log_info
                processed_dict[aoe_classifier] = false
            end
        end
        # cleanup log and combine
        log_info_dict_cleaned = Dict{Symbol, NamedTuple}()
        for aoe_type in aoe_types
            log_info_dict_cleaned[aoe_type] = merge(log_info_dict[aoe_type], log_info_dict[Symbol("$(string(aoe_type))_classifier")])
        end
        result_ch = (result = result_dict, processed = processed_dict, log = log_info_dict_cleaned, validity = validity_ch)
        result_aoe_ch = Dict{NamedTuple, NamedTuple}(chinfo_ch => result_ch)

        pars_db_ch = create_pars(pars_db_ch, result_aoe_ch)
        writelprops(l200.par.ppars.aoe[det], part, pars_db_ch)
        writevalidity(l200.par.ppars.aoe[det], filekey_ch, part)

        return result_ch
    end

    # get start time
    start_time = now()

    result_aoe = parallel(chinfo_unfolded, ch_aoe_cut, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")
    @info "Finished AoE cut generation"

    @info "Write $period validity"
    validity_all = create_validity(result_aoe)
    writevalidity(l200.par.ppars.aoe, validity_all)


    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, aoe_part_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey, part))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_aoe))

    @info "Write log report"
    writelreport(get_preportfilename(l200, filekey, :aoe), report)
    @info report

    # flush stdout
    flush(stdout)
end

