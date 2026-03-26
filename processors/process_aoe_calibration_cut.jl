function process_aoe_calibration_cut(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)

    @info "Calibrate AoE for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true) |> filterby(@pf $usability == :on && $low_aoe_status in [:valid, :present])
    @info "Loaded channel info with $(length(chinfo)) detectors"

    aoe_config = dataprod_config(l200).psd(filekey).aoe
    @debug "Loaded aoe config: $(lstring(aoe_config))"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.aoe), string(period)))
    pars_db = PropDict(l200.par.rpars.aoe[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all detectors" end

    # create log line Tuple
    log_nt_cal = NamedTuple{(:Detector, :Channel, :Status, Symbol("Filter Type"), Symbol("N Compt. Bands"), Symbol("Median norm. Resid."), Symbol("StD norm. Resid."), Symbol("FCT"), :CalError)}
    log_nt_cut = NamedTuple{(:Detector, :Channel, :Status, Symbol("Classifier Type"), Symbol("Cut Value"), Symbol("SEP SF"), Symbol("FEP SF"), :CutError)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))
    
    # flush stdout
    flush(stdout)

    function det_aoe_cut(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector

        @info "Processing detector $det ($ch)"

        pars_db_ch = get(pars_db, det, PropDict())

        result_dict    = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        aoe_config_det = merge(aoe_config.default, get(aoe_config, det, PropDict()))

        compton_bands  = aoe_config_det.compton_bands
        compton_window = aoe_config_det.compton_window
        p_value_cut    = aoe_config_det.p_value # what is this? p values threshold 
        e_type         = Symbol(aoe_config_det.e_type)
        aoe_types      = collect(keys(aoe_config_det.aoe_funcs))
        aoe_funcs      = aoe_config_det.aoe_funcs
        qdrift_expression = aoe_config_det.qdrift_expression

        aoe_classifiers = Symbol.(aoe_config_det.aoe_classifiers)

        # sigma_high_sided = ifelse(chinfo_det.high_aoe_status == :valid, aoe_config_det.sigma_high_sided, Inf)
        sigma_high_sided = aoe_config_det.sigma_high_sided

        if !reprocess && haskey(pars_db, det)
            @debug "Detector $(det) already processed, check missing energy types"
            for aoe_type in aoe_types
                if haskey(pars_db[det], aoe_type)
                    pars_db_det_aoe_type = pars_db[det][aoe_type]
                    log_ch = log_nt_cal(det, ch, ProcessStatus(1), aoe_type, length(pars_db_det_aoe_type.μ_compton.μ), get(pars_db_det_aoe_type.gof, :median_residuals, NaN), get(pars_db_det_aoe_type.gof, :std_residuals, NaN), get(pars_db_det_aoe_type.ctc, :fct, NaN), "Already processed --> skipped.")
                    processed_dict[aoe_type] = false
                    log_info_dict[aoe_type] = log_ch
                end
            end
            for aoe_classifier in aoe_classifiers
                if haskey(pars_db[det], aoe_classifier)
                    log_info = log_nt_cut((det, ch, ProcessStatus(1), aoe_classifier, pars_db[det][aoe_classifier].lowcut, pars_db[det][aoe_classifier].peaks.ds[:Tl208SEP].sf, pars_db[det][aoe_classifier].peaks.ds[:Tl208FEP].sf, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[aoe_classifier] = log_info
                    processed_dict[aoe_classifier] = false
                end
            end
        end

        e_cal, hit_cal = nothing, nothing
        try
            if !all([haskey(processed_dict, aoe_type) for aoe_type in aoe_types]) || !all([haskey(processed_dict, aoe_classifier) for aoe_classifier in aoe_classifiers])
                hit_cal = let dsp=read_ldata(:dataQC, l200, :jlhit, :cal, period, run, det).dataQC, e_type_cal=e_type, e_type=Symbol(first(split(string(e_type), "_cal")))
                    @debug "Reading from $(period)-$(run)"
                    # calibrate_ged_detector_data(l200, pinfo.cal.startkey, det, read_ldata(:dataQC, l200, :jlhit, :cal, pinfo.period, pinfo.run, det); keep_detdata=true) end
                        Table(merge(NamedTuple{(e_type_cal, )}([collect(ljl_propfunc(l200.par.rpars.ecal[period, run][det][e_type].cal.func).(dsp))]), columns(dsp)))
                    end
                e_cal = getproperty(hit_cal, e_type)
            end
        catch e
            @error "Hit data for $det from cannot be loaded: $(truncate_error(e))"
            throw(LoadError("Hit data", 154, "Hit data for $det from $period-$run cannot be loaded: $(truncate_error(e))"))
        end

        e_unit = unit(eltype(e_cal))

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
                    @error "Error in $aoe_type simple normalization for detector $det: $(truncate_error(e))"
                    throw(ErrorException("Error in $aoe_type simple normalization"))
                end
                GC.gc()


                h_aoe_uncal = fit(Histogram, (ustrip.(e_unit, e_cal[isfinite.(aoe)]), aoe[isfinite.(aoe)]), (0:0.5:3000, 0.1:5e-3:1.8))
                p = LegendMakie.lhist(h_aoe_uncal, figsize = (670,400), rasterize = true,
                    title = get_plottitle(filekey, det, "uncalibrated"; additional_type=string(aoe_type)),
                    xlabel = "Energy ($e_unit)",
                    titlesize = 14,
                    ylabel = Makie.rich("A/E", Makie.subscript(" norm")),
                    xticks = 0:500:3000,
                    yticks = 0.25:0.25:1.75
                )
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("aoe_uncalibrated_$aoe_type"))

                result_fit, report_fit, compton_band_peakhists = nothing, nothing, nothing
                try
                    # get compton band peak histograms with generated peakstats
                    compton_band_peakhists = generate_aoe_compton_bands(aoe, e_cal, compton_bands, compton_window)

                    result_fit, report_fit = fit_aoe_compton(compton_band_peakhists.peakhists, compton_band_peakhists.peakstats, compton_bands,; uncertainty=true)
                catch e
                    @error "AoE compton bands cannot be fitted: $(truncate_error(e))"
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
                    @error "AoE corrections cannot be fitted: $(truncate_error(e))"
                    throw(ErrorException("AoE corrections cannot be fitted"))
                end

                # perform A/E combined fit
                if aoe_config_det.use_combined_fit
                    result_fit_combined, report_fit_combined = nothing, nothing
                    try
                        result_fit_combined, report_fit_combined = fit_aoe_compton_combined(peakhists, peakstats, compton_bands, result_fit_single; 
                                        e_expression = e_type, aoe_expression = aoe_expression, uncertainty = true)
                    catch e
                        @error "AoE compton bands cannot be fitted using a combined fit: $e"
                        throw(ErrorException("AoE compton bands cannot be fitted using a combined fit"))
                    end
                    
                    # create plots
                    p_μ = LegendMakie.lplot(report_fit_single.report_μ, report_fit_combined.report_µ, legend_position = :lb, figsize = (600,420), title = get_plottitle(filekey, det, "A/E μ"; additional_type=string(aoe_type)))
                    p_σ = LegendMakie.lplot(report_fit_single.report_σ, report_fit_combined.report_σ, legend_position = :rt, figsize = (600,420), title = get_plottitle(filekey, det, "A/E σ"; additional_type=string(aoe_type)))
                    
                    # create corrected A/E values
                    aoe_corr = ljl_propfunc(result_fit_combined.func).(hit_cal)

                    # create result
                    result_correction = result_fit_combined
                else
                    # create plots
                    p_μ = LegendMakie.lplot(report_fit_single.report_μ, legend_position = :lb, figsize = (600,420), title = get_plottitle(filekey, det, "A/E μ"; additional_type=string(aoe_type)))
                    p_σ = LegendMakie.lplot(report_fit_single.report_σ, legend_position = :rt, figsize = (600,420), title = get_plottitle(filekey, det, "A/E σ"; additional_type=string(aoe_type)))

                    # create corrected A/E values
                    aoe_corr = ljl_propfunc(result_fit_single.func).(hit_cal)

                    # add GoF to result
                    single_fit_residuals = vcat([result_fit[band].gof.residuals_norm for band in compton_bands]...)
                    result_correction = merge(result_fit_single, (gof = (mean_residuals = mean(single_fit_residuals), median_residuals = median(single_fit_residuals), std_residuals = std(single_fit_residuals)), ))
                end
                    
                savelfig(LegendMakie.lsavefig, p_μ, l200, filekey, det, Symbol("compton_bands_mu_$aoe_type"))
                savelfig(LegendMakie.lsavefig, p_σ, l200, filekey, det, Symbol("compton_bands_sigma_$aoe_type"))

                # charge trapping correction
                result_aoe_ctc, report_aoe_ctc = NamedTuple(), NamedTuple()
                if aoe_config_det.apply_ctc
                    try
                        qdrift_e = ljl_propfunc(qdrift_expression).(hit_cal)
                        result_aoe_ctc, report_aoe_ctc = LegendSpecFits.ctc_aoe(aoe_corr, e_cal, qdrift_e, compton_bands,
                            aoe_expression = result_correction.func, qdrift_expression = qdrift_expression)
                    catch e
                        @error "AoE classifier cannot be charge-trapping corrected: $(truncate_error(e))"
                        throw(ErrorException("AoE classifier cannot be charge-trapping corrected"))
                    end

                    # plot A/E ctc correlation plot
                    p = LegendMakie.lplot(report_aoe_ctc, figsize = (600,600), title = get_plottitle(filekey, det, "A/E CT Correction"; additional_type=string(aoe_type)))
                    savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("aoe_ctc_$aoe_type"))
                    
                    aoe_corr = ljl_propfunc(result_aoe_ctc.func).(hit_cal)
                end

                # plot corrected A/E 2D histogram 

                h_aoe_ec = fit(Histogram, (ustrip.(u"keV", e_cal), aoe_corr), (0:0.5:3000, -30:0.1:10))
                p = LegendMakie.lhist(h_aoe_ec, figsize = (670,400), rasterize = true,
                    title = get_plottitle(filekey, det, "normalized"; additional_type=string(aoe_type)),
                    xlabel = "Energy ($e_unit)",
                    titlesize = 14,
                    ylabel = Makie.rich("A/E", Makie.subscript(" ec")),
                    xticks = 0:500:3000,
                    yticks = -30:10:10
                )
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("aoe_normalized_$aoe_type"))

                log_info = log_nt_cal(det, ch, ProcessStatus(1), aoe_type, length(compton_bands), get(result_correction.gof, :median_residuals, NaN), get(result_correction.gof, :std_residuals, NaN), get(result_aoe_ctc, :fct, NaN), "-")

                # create result
                result = (
                            func = get(result_aoe_ctc, :func, result_correction.func),
                            ctc = result_aoe_ctc,
                            correction = result_correction,
                            apply_ctc = aoe_config_det.apply_ctc,
                            use_combined_fit = aoe_config_det.use_combined_fit,
                        )
                # add results to dict
                result_dict[aoe_type]   = result
                log_info_dict[aoe_type] = log_info
                processed_dict[aoe_type] = true

                # free memory
                GC.gc()
            catch e
                @error "Error in $aoe_type calibration: $(truncate_error(e))"
                log_info = log_nt_cal((det, ch, ProcessStatus(0), aoe_type, fill("-", 4)..., truncate_error(e)))
                # add results to dict
                log_info_dict[aoe_type] = log_info
                processed_dict[aoe_type] = false
            end
        end
        @info "AoE calibration for detector $det ($ch) finished"

        # add calbiration results to pars_db
        result_det = (result = result_dict, processed = processed_dict, log = log_info_dict)
        result_aoe_det = Dict{NamedTuple, NamedTuple}(chinfo_det => result_det)

        pars_db_ch = create_pars(pars_db_ch, result_aoe_det)

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

                h_aoe_ctc = fit(Histogram, (ustrip.(e_unit, e_cal), aoe), (0:0.5:3000, -20:0.1:10))
                p = LegendMakie.lhist(h_aoe_ctc, figsize = (670,400), rasterize = true,
                    title = get_plottitle(filekey, det, ""; additional_type=string(aoe_classifier)),
                    xlabel = "Energy ($e_unit)",
                    ylabel = Makie.rich("A/E", Makie.subscript(" ctc")),
                    xticks = 0:500:3000,
                    yticks = -20:10:10
                )
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("aoe_normalized_$aoe_classifier"))

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
                p = LegendMakie.lplot(report_cut, figsize = (750,400), title = get_plottitle(filekey, det, "A/E Performance"; additional_type=string(aoe_classifier)))
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("aoe_energy_afterAoE_zoom_$aoe_classifier"))

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

                p = LegendMakie.lplot(report_peaks_ds, figsize = (600, 400*length(report_peaks_ds)), titlesize = 17, title = get_plottitle(filekey, det, "A/E Performance"; additional_type=string(aoe_classifier)))
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("aoe_peaks_ds_sf_$aoe_classifier"))

                # save results
                result = merge(result_cut, (peaks = (low = result_peaks_low, ds = result_peaks_ds) , qbb = (low = qbb_result_low, ds = qbb_result_ds)))

                log_info = log_nt_cut((det, ch, ProcessStatus(1), aoe_classifier, result_cut.lowcut, result.peaks.ds[:Tl208SEP].sf, result.peaks.ds[:Tl208FEP].sf, "-"))

                # add results to dict
                result_dict[aoe_classifier]   = result
                log_info_dict[aoe_classifier] = log_info
                processed_dict[aoe_classifier] = true

                GC.gc()
            catch e
                @error "Error in $aoe_classifier cut generation: $(truncate_error(e))"
                log_info = log_nt_cut((det, ch, ProcessStatus(0), aoe_classifier, "-", "-", "-", truncate_error(e)))
                
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
    result_aoe = parallel(chinfo, det_aoe_cut, merge(log_nt_cal, log_nt_cut), wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

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
