function process_lq_calibration_cut(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)

    @info "Calibrate LQ for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true) |> filterby(@pf $usability == :on && $lq_status in [:valid, :present])
    @info "Loaded channel info with $(length(chinfo)) channels"

    pars_energy = get_values(l200.par.rpars.ecal[period, run])
    @debug "Loaded energy calibration pars"

    lq_config = dataprod_config(l200).psd(filekey).lq
    @debug "Loaded LQ config: $(lq_config)"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.lq), string(period)))
    pars_db = PropDict(l200.par.rpars.lq[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" end

    # create log line Tuple
    log_nt_cal = NamedTuple{(:Channel, :Detector, :Status, Symbol("Classifier Type"), Symbol("DT Corr. Type"), Symbol("Correction Slope"), :CalError)}
    log_nt_cut = NamedTuple{(:Channel, :Detector, :Status, Symbol("Classifier Type"), Symbol("Cut Value"), Symbol("DEP SF"), Symbol("CC SF"), :CutError)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    function ch_lq_cut(chinfo_ch::NamedTuple)
        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        @info "Processing channel $ch ($det)"

        pars_db_ch = get(pars_db, det, PropDict())

        result_dict    = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        # load lq config
        lq_config_ch = merge(lq_config.default, get(lq_config, det, PropDict()))

        e_type                      = Symbol(lq_config_ch.e_type)
        lq_types                    = collect(keys(lq_config_ch.lq_funcs))
        lq_funcs                    = lq_config_ch.lq_funcs
        lq_classifiers              = Symbol.(lq_config_ch.lq_classifiers)
        qdrift_expression           = lq_config_ch.qdrift_expression

        #for lq_ctc_correction
        dep_µ                       = lq_config_ch.dep_mu
        ctc_dep_edgesigma           = lq_config_ch.ctc_dep_edgesigma
        ctc_lq_precut_relative_cut  = lq_config_ch.ctc_lq_precut_relative_cut
        ctc_driftime_cutoff_method  = Symbol(lq_config_ch.ctc_driftime_cutoff_method)
        lq_outlier_sigma            = lq_config_ch.lq_outlier_sigma
        dt_eff_outlier_sigma        = lq_config_ch.dt_eff_outlier_sigma
        ctc_dt_eff_low_quantile     = lq_config_ch.ctc_dt_eff_low_quantile
        ctc_dt_eff_high_quantile    = lq_config_ch.ctc_dt_eff_high_quantile
        pol_fit_order               = lq_config_ch.pol_fit_order
        ctc_uncertainty             = lq_config_ch.ctc_uncertainty

        #for lq_cut
        cut_sigma                   = lq_config_ch.cut_sigma
        dep_sideband_sigma          = lq_config_ch.dep_sideband_sigma
        cut_truncation_sigma        = lq_config_ch.cut_truncation_sigma
        cut_uncertainty             = lq_config_ch.cut_uncertainty

        #for get_peaks_survival_fractions
        lq_peaks_names              = Symbol.(lq_config_ch.lq_peaks_names)
        lq_peaks                    = lq_config_ch.lq_peaks
        lq_peaks_windows_left       = lq_config_ch.lq_peaks_windows_left
        lq_peaks_windows_right      = lq_config_ch.lq_peaks_windows_right
        lq_peaks_fit_funcs          = Symbol.(lq_config_ch.lq_peaks_fit_funcs)
        qbb_pos                     = lq_config_ch.qbb
        qbb_window                  = lq_config_ch.qbb_window

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(det) already processed, check missing lq_classifiers"
            for lq_type in lq_types
                if !haskey(pars_db[det], lq_type)
                    log_ch = log_nt_cal(ch, det, ProcessStatus(1), lq_type, ctc_driftime_cutoff_method, pars_db[det][lq_type].fit_result.par[1], "Already processed --> skipped.")
                    processed_dict[lq_type] = false
                    log_info_dict[lq_type] = log_ch
                end
            end
            for lq_classifier in lq_classifiers
                if haskey(pars_db[det], lq_classifier)
                    log_info = log_nt_cut((ch, det, ProcessStatus(1), lq_classifier, pars_db[det][lq_classifier].cut, pars_db[det][lq_classifier].peaks[:Tl208DEP].sf, pars_db[det][lq_classifier].qbb.sf, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[lq_classifier] = log_info
                    processed_dict[lq_classifier] = false
                end
            end
        end

        hit_cal, e_cal, dep_σ = nothing, nothing, nothing
        try 
            if !all([haskey(processed_dict, lq_type) for lq_type in lq_types]) || !all([haskey(processed_dict, lq_classifier) for lq_classifier in lq_classifiers])
                hit_cal = let dsp=read_ldata(:dataQC, l200, :jlhit, :cal, period, run, ch), e_type_cal=e_type, e_type=Symbol(first(split(string(e_type), "_cal")))
                    @debug "Reading from $(period)-$(run)"
                    # calibrate_ged_channel_data(l200, pinfo.cal.startkey, det, read_ldata(:dataQC, l200, :jlhit, :cal, pinfo.period, pinfo.run, ch); keep_chdata=true) end
                        Table(merge(NamedTuple{(e_type_cal, )}([collect(ljl_propfunc(l200.par.rpars.ecal[period, run][det][e_type].cal.func).(dsp))]), columns(dsp)))
                    end
                e_cal = getproperty(hit_cal, e_type)
                dep_σ = mvalue(pars_energy[det].e_cusp_ctc.fit.Tl208DEP.fwhm / (2 * sqrt(2 * log(2))))
            end
        catch e
            @error "E data for $det cannot be loaded: $(truncate_error(e))"
            throw(LoadError("E data", 154, "E data for $det from $period-$run cannot be loaded: $(truncate_error(e))"))
        end

        @showprogress desc="Detector: $det" for lq_type in lq_types
            if haskey(processed_dict, lq_type)
                continue
            end
            try
                @debug "Calculate energy corrected and normalized lq and effective drift time"
                lq_e_corr, dt_eff = nothing, nothing
                lq_e_corr_expression, dt_eff_expression = nothing, nothing
                mean_lq, std_lq, median_lq = nothing, nothing, nothing
                try
                    lq_e_corr = ljl_propfunc(lq_funcs[lq_type]).(hit_cal)
                    dt_eff = ljl_propfunc(qdrift_expression).(hit_cal)

                    mean_lq = mean(filter(isfinite, lq_e_corr))
                    std_lq = std(filter(isfinite, lq_e_corr))
                    median_lq = median(filter(isfinite, lq_e_corr))

                    #normalization
                    cuts_lq = cut_single_peak(lq_e_corr, 0.0, quantile(filter(isfinite, lq_e_corr), 0.99); n_bins=-1)
                    lq_e_corr ./= cuts_lq.max

                    lq_e_corr_expression = "$(lq_funcs[lq_type]) / $(cuts_lq.max)"
                    dt_eff_expression = qdrift_expression
                catch e
                    @error "Error in energy correction and normalization: $e"
                    throw(ErrorException("Error in energy correction and normalization: $e"))
                end

                @debug "Calibrate $lq_type"
                drift_result, drift_report = nothing, nothing
                try 
                    drift_result, drift_report = lq_ctc_correction(lq_e_corr, dt_eff, e_cal, dep_µ, dep_σ;
                        ctc_dep_edgesigma, ctc_lq_precut_relative_cut, lq_outlier_sigma, ctc_driftime_cutoff_method, dt_eff_outlier_sigma, lq_e_corr_expression, dt_eff_expression, ctc_dt_eff_low_quantile, ctc_dt_eff_high_quantile, pol_fit_order, uncertainty=ctc_uncertainty)
                catch e
                    @error "Error in drift time correction: $e"
                    throw(ErrorException("Error in drift time correction: $e"))
                end

                #create and save plots
                p = LegendMakie.lplot(drift_report, e_cal, dt_eff, lq_e_corr, :DEP, title = get_plottitle(filekey, det, "LQ"), figsize = (620,400))
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("drift_time_vs_lq_plot_DEP_$lq_type"))

                p = LegendMakie.lplot(drift_report, e_cal, dt_eff, lq_e_corr, :whole, title = get_plottitle(filekey, det, "LQ"), figsize = (620,400))
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("drift_time_vs_lq_plot_$lq_type"))

                #create log entry
                log_info = log_nt_cal(ch, det, ProcessStatus(1), lq_type, ctc_driftime_cutoff_method, drift_result.fit_result.par[1], "-")

                # add results to dict
                result_dict[lq_type]    = merge(drift_result, (mean_lq = mean_lq, std_lq = std_lq, median_lq = median_lq))
                log_info_dict[lq_type]  = log_info
                processed_dict[lq_type] = true

                # free memory
                GC.gc()
            catch e
                @error "Error in $lq_type calibration: $(truncate_error(e))"
                log_info = log_nt_cal((ch, det, ProcessStatus(0), lq_type, "-", "-", truncate_error(e)))

                # add results to dict
                log_info_dict[lq_type] = log_info
                processed_dict[lq_type] = false
            end
        end
        @debug "LQ calibration for channel $ch ($det) finished"

        # add lq constructor results to pars_db
        result_ch = (result = result_dict, processed = processed_dict, log = log_info_dict)
        result_lq_cons = Dict{NamedTuple, NamedTuple}(chinfo_ch => result_ch)
        pars_db_ch = create_pars(pars_db_ch, result_lq_cons)

        # continue with lq cut
        @showprogress desc="Detector: $det" for lq_classifier in lq_classifiers
            if haskey(processed_dict, lq_classifier)
                continue
            end
            try
                @debug "Generate lq cut"

                #get lq classifier
                lq_class = nothing
                try
                    lq_class = ljl_propfunc(pars_db_ch[det][Symbol(first(split(string(lq_classifier), "_classifier")))].func).(hit_cal)
                catch e
                    @error "lq classifier for $det cannot be loaded: $(truncate_error(e))"
                    throw(LoadError("lq", 154, "lq classifier data for $det from $period-$run cannot be loaded: $(truncate_error(e))"))
                end
                
                #calculate LQ cut parameter value
                result, report = nothing, nothing
                try
                    result, report = lq_cut(dep_µ, dep_σ, e_cal, lq_class; cut_sigma, dep_sideband_sigma, cut_truncation_sigma, uncertainty=cut_uncertainty)
                catch e
                    @error "Error in LQ cut calculation: $e"
                    throw(ErrorException("Error in LQ cut calculation: $e"))
                end

                #create and save plots
                p = LegendMakie.lplot(report.fit_report, xlabel = Makie.rich("LQ", Makie.subscript(" ctc")), digits = 3, figsize = (600,450), 
                    legend_position = :none, title = get_plottitle(filekey, det, "LQ Cut", additional_type=string(lq_classifier)))
                Makie.vlines!(Measurements.value(report.cut), color = LegendMakie.CoaxGreen, label = "Cut Value", linewidth = 4)
                Makie.axislegend(position = :lt)
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("lq_cut_fit_$lq_classifier"))

                p = LegendMakie.lplot(report.temp_hists, 
                    title = get_plottitle(filekey, det, "LQ sidebands", additional_type=string(lq_classifier)), 
                    xlims = (StatsBase.quantile.(Ref(filter(isfinite, lq_class),), (0.05, 0.95)))
                )
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("sideband_$lq_classifier"))

                p = LegendMakie.lplot((; e_cal, edges = report.edges, dep_σ = report.dep_σ),
                    title = get_plottitle(filekey, det, "LQ side bands", additional_type=string(lq_classifier)))
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("energy_spectrum_$lq_classifier"))

                sel = isfinite.(e_cal) #.&& drift_report.dep_left .< e_cal .< drift_report.dep_right
                p = LegendMakie.lhist(StatsBase.fit(StatsBase.Histogram, (Unitful.ustrip.(e_cal)[sel], lq_class[sel]), (0:1:3000, range(-3.5, 5.5, length=200))),
                    title = get_plottitle(filekey, det, "LQ"), figsize = (620,400), watermark = false, xlabel = "Energy (keV)", ylabel = ylabel = Makie.rich("LQ", Makie.subscript(" ctc")), limits = (0,3000,-3.5,5.5))
                Makie.hlines!([Measurements.value(report.cut)], color = LegendMakie.CoaxGreen, label = "LQ cut", linewidth = 4)
                Makie.axislegend(position = :rb)
                LegendMakie.add_watermarks!(position = "outer top", final = true)
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("lq_cut_$lq_classifier"))

                p = LegendMakie.lplot((; e_cal, lq_class, cut_value = report.cut), figsize = (750,400),
                    title = get_plottitle(filekey, det, "LQ Performance", additional_type=string(lq_classifier)))
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("energy_hist_$lq_classifier"))

                fig = Makie.Figure()
                e_unit = Unitful.unit(first(e_cal))
                ax = Makie.Axis(fig[1,1], 
                    xlabel = "Energy ($e_unit)", ylabel = "Survival fraction", limits = (0,3000,0,1),
                    title = get_plottitle(filekey, det, "LQ survival", additional_type=string(lq_classifier)))
                h1 = StatsBase.fit(StatsBase.Histogram, Unitful.ustrip.(e_unit, e_cal), 0:3:3000)
                h2 = StatsBase.fit(StatsBase.Histogram, Unitful.ustrip.(e_unit, e_cal)[lq_class .> report.cut], 0:3:3000)
                Makie.lines!(ax, StatsBase.midpoints(first(h1.edges)), h2.weights ./ h1.weights, label = "Cut fraction", linewidth = 1)
                Makie.axislegend(ax, position = :lt)
                LegendMakie.add_watermarks!(final = true)
                savelfig(LegendMakie.lsavefig, fig, l200, filekey, det, Symbol("cut_fraction_$lq_classifier"))
                
                @debug("Generate Surrvival Fractions for LQ")

                result_peaks, report_peaks = nothing, nothing
                try
                    result_peaks, report_peaks = get_peaks_survival_fractions(lq_class, e_cal, lq_peaks, lq_peaks_names, lq_peaks_windows_left, lq_peaks_windows_right, result.cut; inverted_mode=true, fit_funcs=lq_peaks_fit_funcs)
                catch e
                    @error "Error in peak lq survival fraction calculation: $e"
                    throw(ErrorException("Error in peak lq survival fraction calculation: $e"))
                end

                result_qbb, report_qbb = nothing, nothing
                try
                    result_qbb, report_qbb = get_continuum_survival_fraction(lq_class, e_cal, qbb_pos, qbb_window, result.cut, inverted_mode=true)
                catch e
                    @error "Error in qbb lq survival fraction calculation: $e"
                    throw(ErrorException("Error in qbb lq survival fraction calculation: $e"))
                end
                
                # save results
                final_result = merge(result, (peaks = result_peaks, qbb = result_qbb))

                log_info = log_nt_cut((ch, det, ProcessStatus(1), lq_classifier, final_result.cut, final_result.peaks[:Tl208DEP].sf, final_result.qbb.sf, "-"))

                # add results to dict
                result_dict[lq_classifier] = final_result
                log_info_dict[lq_classifier] = log_info
                processed_dict[lq_classifier] = true

                GC.gc()
            catch e
                @error "Error in lq cut generation: $(truncate_error(e))"
                log_info = log_nt_cut((ch, det, ProcessStatus(0), lq_classifier, "-", "-", "-", truncate_error(e)))
                
                # add results to dict
                log_info_dict[lq_classifier] = log_info
                processed_dict[lq_classifier] = false
            end
        end

        # cleanup log and combine
        log_info_dict_cleaned = Dict{Symbol, NamedTuple}()
        for lq_type in lq_types
            log_info_dict_cleaned[lq_type] = merge(log_info_dict[lq_type], log_info_dict[Symbol("$(string(lq_type))_classifier")])
        end

        return (result = result_dict, log = log_info_dict_cleaned, processed = processed_dict)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_lq = parallel(chinfo, ch_lq_cut, merge(log_nt_cal, log_nt_cut), wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished LQ Cut calculation"

    pars_db = create_pars(pars_db, result_lq)
    writelprops(l200.par.rpars.lq[period], run, pars_db)
    writevalidity(l200.par.rpars.lq, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, lq_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_lq))

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, :lq), report)
    @info report

    # flush stdout
    flush(stdout)
end
