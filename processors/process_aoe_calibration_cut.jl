function process_aoe_calibration_cut(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)

    @info "Calibrate AoE for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true) |> filterby(@pf $usability == :on && $low_aoe_status in [:valid, :present])
    chinfo = chinfo[1:10]
    @info "Loaded channel info with $(length(chinfo)) channels"

    aoe_config = dataprod_config(l200).psd(filekey).aoe
    @debug "Loaded aoe config: $(aoe_config)"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.aoe), string(period)))
    pars_db = PropDict(l200.par.rpars.aoe[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" end

    # create log line Tuple
    log_nt_cal = NamedTuple{(:Channel, :Detector, :Status, Symbol("Filter Type"), Symbol("N Compt. Bands"), Symbol("Median norm. Resid."), Symbol("StD norm. Resid."), :CalError)}
    log_nt_cut = NamedTuple{(:Channel, :Detector, :Status, Symbol("Classifier Type"), Symbol("Cut Value"), Symbol("SEP SF"), Symbol("FEP SF"), :CutError)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))
    
    # flush stdout
    flush(stdout)

    function ch_aoe_cut(chinfo_ch::NamedTuple)

        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        @info "Processing channel $ch ($det)"

        pars_db_ch = get(pars_db, det, PropDict())

        result_dict    = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        aoe_config_ch = merge(aoe_config.default, get(aoe_config, det, PropDict()))

        compton_bands  = aoe_config_ch.compton_bands
        compton_window = aoe_config_ch.compton_window
        p_value_cut    = aoe_config_ch.p_value # what is this? p values threshold 
        e_type         = Symbol(aoe_config_ch.e_type)
        aoe_types      = collect(keys(aoe_config_ch.aoe_funcs))
        aoe_funcs      = aoe_config_ch.aoe_funcs

        aoe_classifiers = Symbol.(aoe_config_ch.aoe_classifiers)

        # sigma_high_sided = ifelse(chinfo_ch.high_aoe_status == :valid, aoe_config_ch.sigma_high_sided, Inf)
        sigma_high_sided = aoe_config_ch.sigma_high_sided

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(det) already processed, check missing energy types"
            for aoe_type in aoe_types
                if haskey(pars_db[det], aoe_type)
                    pars_db_det_aoe_type = pars_db[det][aoe_type]
                    log_ch = log_nt_cal(ch, det, ProcessStatus(1), aoe_type, length(pars_db_det_aoe_type.μ_compton.μ), get(pars_db_det_aoe_type.gof, :median_residuals, NaN), get(pars_db_det_aoe_type.gof, :std_residuals, NaN), "Already processed --> skipped.")
                    processed_dict[aoe_type] = false
                    log_info_dict[aoe_type] = log_ch
                end
            end
            for aoe_classifier in aoe_classifiers
                if haskey(pars_db[det], aoe_classifier)
                    log_info = log_nt_cut((ch, det, ProcessStatus(1), aoe_classifier, pars_db[det][aoe_classifier].lowcut, pars_db[det][aoe_classifier].peaks.ds[:Tl208SEP].sf, pars_db[det][aoe_classifier].peaks.ds[:Tl208FEP].sf, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[aoe_classifier] = log_info
                    processed_dict[aoe_classifier] = false
                end
            end
        end

        e_cal, hit_cal = nothing, nothing
        try
            if !all([haskey(processed_dict, aoe_type) for aoe_type in aoe_types]) || !all([haskey(processed_dict, aoe_classifier) for aoe_classifier in aoe_classifiers])
                hit_cal = let dsp=read_ldata(:dataQC, l200, :jlhit, :cal, period, run, ch), e_type_cal=e_type, e_type=Symbol(first(split(string(e_type), "_cal")))
                    @debug "Reading from $(period)-$(run)"
                    # calibrate_ged_channel_data(l200, pinfo.cal.startkey, det, read_ldata(:dataQC, l200, :jlhit, :cal, pinfo.period, pinfo.run, ch); keep_chdata=true) end
                        Table(merge(NamedTuple{(e_type_cal, )}([collect(ljl_propfunc(l200.par.rpars.ecal[period, run][det][e_type].cal.func).(dsp))]), columns(dsp)))
                    end
                e_cal = getproperty(hit_cal, e_type)
            end
        catch e
            @error "Hit data for $det from cannot be loaded: $(truncate_string(string(e)))"
            throw(LoadError("Hit data", 154, "Hit data for $det from $period-$run cannot be loaded: $(truncate_string(string(e)))"))
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

                p = histogram2d(e_cal[isfinite.(aoe)], aoe[isfinite.(aoe)], nbins=(0:0.5:3000, 0.1:5e-3:1.8), xlims=(0, 3000), ylims=(0.1, 1.8), size=(1200, 800), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy", ylabel="A/E (a.u.)", margin=5mm)
                plot!(p, guidefontsize=18, xguidefontsize=18,yguidefontsize = 18,xtickfontsize = 12,ytickfontsize=12)
                xticks!(p, 0:250:3000)
                title!(p, get_plottitle(filekey, det, "AoE uncalibrated"; additiional_type=string(aoe_type)))
                savelfig(savefig, p, l200, filekey, det, Symbol("aoe_uncalibrated_$aoe_type"))

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

                qc_compton_bands = findall(band -> band in keys(result_fit) && result_fit[band].gof.converged && result_fit[band].gof.pvalue >= p_value_cut, compton_bands)
                compton_bands = compton_bands[qc_compton_bands]
                peakhists = compton_band_peakhists.peakhists[qc_compton_bands]
                peakstats = compton_band_peakhists.peakstats[qc_compton_bands]
                μ = [result_fit[band].μ for band in compton_bands]
                σ = [result_fit[band].σ for band in compton_bands]

                # fit μ and σ with correction functions
                result_fit_single, report_fit_single = nothing, nothing
                try
                    result_fit_single, report_fit_single = fit_aoe_corrections(compton_bands, μ, σ,; aoe_expression = aoe_expression, e_expression = e_type)
                catch e
                    @error "AoE corrections cannot be fitted: $(truncate_string(string(e)))"
                    throw(ErrorException("AoE corrections cannot be fitted"))
                end

                # perform A/E combined fit
                if aoe_config_ch.use_combined_fit
                    result_fit_combined, report_fit_combined = nothing, nothing
                    try
                        result_fit_combined, report_fit_combined = fit_aoe_compton_combined(peakhists, peakstats, compton_bands, result_fit_single; 
                                        e_expression = e_type, aoe_expression = aoe_expression, uncertainty = true)
                    catch e
                        @error "AoE compton bands cannot be fitted using a combined fit: $e"
                        throw(ErrorException("AoE compton bands cannot be fitted using a combined fit"))
                    end
                    
                    # create plots
                    p_μ = plot(report_fit_single.report_µ, report_fit_combined.report_µ)
                    p_σ = plot(report_fit_single.report_σ, report_fit_combined.report_σ)
                    
                    # create corrected A/E values
                    aoe_corr = ljl_propfunc(result_fit_combined.func).(hit_cal)

                    # create result
                    result_correction = result_fit_combined
                else
                    # create plots
                    p_μ = plot(report_fit_single.report_µ)
                    p_σ = plot(report_fit_single.report_σ)

                    # create corrected A/E values
                    aoe_corr = ljl_propfunc(result_fit_single.func).(hit_cal)

                    # add GoF to result
                    single_fit_residuals = vcat([result_fit[band].gof.residuals_norm for band in compton_bands]...)
                    result_correction = merge(result_fit_single, (gof = (mean_residuals = mean(single_fit_residuals), median_residuals = median(single_fit_residuals), std_residuals = std(single_fit_residuals)), ))
                end
                    
                title!(p_μ, get_plottitle(filekey, det, "A/E μ"; additiional_type=string(aoe_type)), subplot=1)
                savelfig(savefig, p_μ, l200, filekey, det, Symbol("compton_bands_mu_$aoe_type"))

                title!(p_σ, get_plottitle(filekey, det, "A/E σ"; additiional_type=string(aoe_type)), subplot=1)
                savelfig(savefig, p_σ, l200, filekey, det, Symbol("compton_bands_sigma_$aoe_type"))

                # plot corrected A/E 2D histogram
                p = histogram2d(e_cal, aoe_corr, nbins=(0:0.5:3000, -30:0.1:10), xlims=(0, 3000), ylims=(-30, 10), size=(1300, 700), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel=L"Energy\ (keV)", ylabel=L"A/E\ (\sigma_{A/E})")
                plot!(margin=1mm, thickness_scaling=1.6, dpi=600)
                xticks!(0:250:3000)
                title!(p, get_plottitle(filekey, det, "normalized A/E"; additiional_type=string(aoe_type)))
                savelfig(savefig, p, l200, filekey, det, Symbol("aoe_normalized_$aoe_type"))

                # charge trapping correction
                result_aoe_ctc, report_aoe_ctc = nothing, nothing
                try
                    # determine qdrift/e (TODO: can we use e_cal here ? It should be the same used for A/E)
                    # TODO: define q_drift_expression!!
                    qdrift_e = ljl_propfunc(qdrift_expression).(hit_cal)
                    result_aoe_ctc, report_aoe_ctc = LegendSpecFits.ctc_aoe(aoe_corr, e_cal, qdrift_e, compton_bands,
                        aoe_expression = result_correction.func, qdrift_expression = qdrift_expression)
                catch e
                    @error "AoE classifier cannot be charge-trapping corrected: $(truncate_string(string(e)))"
                    throw(ErrorException("AoE classifier cannot be charge-trapping corrected"))
                end

                # TODO: Add plot code here
                
                log_info = log_nt_cal(ch, det, ProcessStatus(1), aoe_type, length(compton_bands), get(result_correction.gof, :median_residuals, NaN), get(result_correction.gof, :std_residuals, NaN), "-")

                # add results to dict
                # TODO: Decide what to save (result_aoe_ctc ?)
                result_dict[aoe_type]   = result_correction
                log_info_dict[aoe_type] = log_info
                processed_dict[aoe_type] = true

                # free memory
                GC.gc()
            catch e
                @error "Error in $aoe_type calibration: $(truncate_string(string(e)))"
                log_info = log_nt_cal((ch, det, ProcessStatus(0), aoe_type, "-", "-", "-", truncate_string(string(e))))
                # add results to dict
                log_info_dict[aoe_type] = log_info
                processed_dict[aoe_type] = false
            end
        end
        @info "AoE calibration for channel $ch ($det) finished"

        # add calbiration results to pars_db
        result_ch = (result = result_dict, processed = processed_dict, log = log_info_dict)
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
                    throw(LoadError("AoE", 154, "AoE data for $det cannot be loaded"))
                end

                p = histogram2d(e_cal, aoe, nbins=(0:0.5:3000, -20:0.1:10), xlims=(0, 3000), ylims=(-20, 10), size=(1300, 700), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel=L"Energy\ (keV)", ylabel=L"A/E\ (\sigma_{A/E})")
                plot!(margin=1mm, thickness_scaling=1.6, dpi=600)
                title!(p, get_plottitle(filekey, det, "normalized A/E"; additiional_type=string(aoe_classifier)))
                xticks!(0:250:3000)
                savelfig(savefig, p, l200, filekey, det, Symbol("aoe_normalized_$aoe_classifier"))

                result_cut, report_cut = nothing, nothing
                try
                    @debug "Generate AoE cut"
                    result_cut, report_cut = get_low_aoe_cut(aoe, e_cal,; dep=aoe_config_ch.dep, window=aoe_config_ch.dep_window, 
                                    cut_search_interval=Tuple(aoe_config_ch.dep_cut_search_interval), bin_width_window=aoe_config_ch.dep_bin_width_window,
                                    rtol=aoe_config_ch.dep_cut_search_rtol, maxiters=aoe_config_ch.dep_cut_search_maxiters, dep_sf=aoe_config_ch.dep_cut_search_target_sf,
                                    fixed_position=aoe_config_ch.dep_cut_search_fixed_position, sigma_high_sided=sigma_high_sided,
                                    fit_func=Symbol(aoe_config_ch.dep_cut_search_fit_func), uncertainty=true)
                catch e
                    @error "AoE cut for $det cannot be generated"
                    throw(ErrorException("AoE cut for $det from $period-$run cannot be generated"))
                end

                @debug "Found low A/E cut at $(round(result_cut.lowcut, digits=2)) and high A/E cut at $(round(result_cut.highcut, digits=2))"

                # plot spectrum before and after cut
                p = plot(report_cut)
                title!(get_plottitle(filekey, det, "A/E Performance"; additiional_type=string(aoe_classifier)), subplot=1)
                savelfig(savefig, p, l200, filekey, det, Symbol("aoe_energy_afterAoE_zoom_$aoe_classifier"))

                result_peaks_low, report_peaks_low = nothing, nothing
                try
                    @debug "Generate A/E low Survival Fractions"
                    result_peaks_low, report_peaks_low = get_peaks_survival_fractions(aoe, e_cal, aoe_config_ch.aoe_peaks, Symbol.(aoe_config_ch.aoe_peaks_names), aoe_config_ch.aoe_peaks_windows_left, aoe_config_ch.aoe_peaks_windows_right, result_cut.lowcut,; 
                                                    bin_width_window=aoe_config_ch.aoe_peaks_bin_width_window, sigma_high_sided=Inf, fit_funcs=Symbol.(aoe_config_ch.aoe_peaks_fit_funcs), uncertainty=true)
                catch e
                    @error "AoE peaks low SF for $det cannot be generated"
                    throw(ErrorException("AoE peaks low SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found low SEP Survival Fraction at $(round(u"percent", result_peaks_low[:Tl208SEP].sf, digits=2))"
                @debug "Found low FEP Survival Fraction at $(round(u"percent", result_peaks_low[:Tl208FEP].sf, digits=2))"

                qbb_result_low = nothing
                try
                    qbb_result_low, _ = get_continuum_survival_fraction(aoe, e_cal, aoe_config_ch.qbb, aoe_config_ch.qbb_window, result_cut.lowcut,; sigma_high_sided=Inf)
                catch e
                    @error "Qbb low SF for $det cannot be generated"
                    throw(ErrorException("Qbb low SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found low Qbb Survival Fraction at $(round(u"percent", qbb_result_low.sf, digits=2))"

                result_peaks_ds, report_peaks_ds = nothing, nothing
                try
                    @debug "Generate A/E DS Survival Fractions"
                    result_peaks_ds, report_peaks_ds = get_peaks_survival_fractions(aoe, e_cal, aoe_config_ch.aoe_peaks, Symbol.(aoe_config_ch.aoe_peaks_names), aoe_config_ch.aoe_peaks_windows_left, aoe_config_ch.aoe_peaks_windows_right, result_cut.lowcut,; 
                                                    bin_width_window=aoe_config_ch.aoe_peaks_bin_width_window, sigma_high_sided=result_cut.highcut, fit_funcs=Symbol.(aoe_config_ch.aoe_peaks_fit_funcs), uncertainty=true)
                catch e
                    @error "AoE peaks DS SF for $det cannot be generated"
                    throw(ErrorException("AoE peaks DS SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found DS SEP Survival Fraction at $(round(u"percent", result_peaks_ds[:Tl208SEP].sf, digits=2))"
                @debug "Found DS FEP Survival Fraction at $(round(u"percent", result_peaks_ds[:Tl208FEP].sf, digits=2))"

                qbb_result_ds = nothing
                try
                    qbb_result_ds, _ = get_continuum_survival_fraction(aoe, e_cal, aoe_config_ch.qbb, aoe_config_ch.qbb_window, result_cut.lowcut,; sigma_high_sided=result_cut.highcut)
                catch e
                    @error "Qbb DS SF for $det cannot be generated"
                    throw(ErrorException("Qbb DS SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found DS Qbb Survival Fraction at $(round(u"percent", qbb_result_ds.sf, digits=2))"

                p = plot(broadcast(k -> plot(report_peaks_ds[k].after, show_components=false, left_margin=20mm, top_margin=-5mm, bottom_margin=-2mm, peak_name=string(k), ms=2), keys(report_peaks_ds))..., layout=(length(report_peaks_ds), 1), size=(1000,710*length(report_peaks_ds)) , thickness_scaling=1.8, titlefontsize = 10, legendfontsize = 8, yguidefontsize = 9, xguidefontsize=11)
                plot!(plot_title=get_plottitle(filekey, det, "A/E DS Performance"; additiional_type=string(aoe_classifier)), plot_titlelocation=(0.5,0.2), plot_titlefontsize = 9)
                savelfig(savefig, p, l200, filekey, det, Symbol("aoe_peaks_ds_sf_$aoe_classifier"))

                # save results
                result = merge(result_cut, (peaks = (low = result_peaks_low, ds = result_peaks_ds) , qbb = (low = qbb_result_low, ds = qbb_result_ds)))

                log_info = log_nt_cut((ch, det, ProcessStatus(1), aoe_classifier, result_cut.lowcut, result.peaks.ds[:Tl208SEP].sf, result.peaks.ds[:Tl208FEP].sf, "-"))

                # add results to dict
                result_dict[aoe_classifier]   = result
                log_info_dict[aoe_classifier] = log_info
                processed_dict[aoe_classifier] = true

                GC.gc()
            catch e
                @error "Error in $aoe_classifier cut generation: $(truncate_string(string(e)))"
                log_info = log_nt_cut((ch, det, ProcessStatus(0), aoe_classifier, "-", "-", "-", truncate_string(string(e))))
                
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

        return (result = result_dict, log = log_info_dict_cleaned, processed = processed_dict)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_aoe = parallel(chinfo, ch_aoe_cut, merge(log_nt_cal, log_nt_cut), wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished AoE calibration"

    pars_db = create_pars(pars_db, result_aoe)
    writelprops(l200.par.rpars.aoe[period], run, pars_db)
    writevalidity(l200.par.rpars.aoe, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, aoe_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_aoe))

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    # flush stdout
    flush(stdout)
end
