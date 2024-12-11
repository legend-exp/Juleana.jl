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
    log_nt_cal = NamedTuple{(:Channel, :Detector, :Status, Symbol("Drift Correction Type"), Symbol("LQ classifier function"), :CalError)}
    log_nt_cut = NamedTuple{(:Channel, :Detector, :Status, Symbol("Classifier Type"), Symbol("LQ cut Value"), Symbol("Continuum SF"), Symbol("DEP SF"), :CutError)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    function ch_lq_cut(chinfo_ch::NamedTuple)

        ############
        ############
        #fill config with:

        #fill config with:
        lq_classifiers=[:lq_classifier]

        #for lq_ctc_correction:
        DEP_µ = 1592.53u"keV"
        ctc_dep_edgesigma=3.0               # sigma window for DEP peak
        ctc_driftime_cutoff_method= :percentile     # method for drift time cutoff
        lq_outlier_sigma= 2.0                   # sigma for lq outlier #### in your pars as ctc_qdrift_cutoff_sigma
        drift_time_outlier_sigma=2.0            # sigma for drift time outlier                  

        # only e_cusp, the best energy type from calibration?
        e_cal_type = :e_cusp_ctc_cal            # energy type for calibrated energy
        e_uncal_type = :e_cusp                  # energy type for uncalibrated energy

        ctc_dt_eff_low_quantile=0.15 
        ctc_dt_eff_high_quantile=0.95
        pol_fit_order=1

        #for lq_cut
        cut_sigma=3.0 
        dep_sideband_sigma = 4.5
        cut_truncation_sigma=2.0
        
        #for get_peaks_surrival_fractions


        #In ein config file auslagern
        lq_peaks_names = [:Tl208DEP, :Tl208FEP]
        lq_peaks = [1592.53, 2614.51] * u"keV"
        lq_peaks_windows_left = [10.0u"keV", 10.0u"keV"]
        lq_peaks_windows_right = [10.0u"keV", 10.0u"keV"]
        lq_peaks_fit_funcs = [:gamma_tails_bckFlat, :gamma_def]
        qbb_pos = 2039.0u"keV"
        qbb_window = 10.0u"keV"

        ##############
        ##############

        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        @info "Processing channel $ch ($det)"

        pars_db_ch = get(pars_db, det, PropDict())

        result_dict    = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        lq_config_ch = merge(lq_config.default, get(lq_config, det, PropDict()))

        e_cal_type              = Symbol(lq_config_ch.e_cal_type)
        e_uncal_type            = Symbol(lq_config_ch.e_uncal_type)
        
        DEP_edgesigma           = lq_config_ch.ctc_dep_edgesigma
        ctc_mode                = Symbol(lq_config_ch.ctc_mode)
        ctc_qdrift_cutoff_sigma = lq_config_ch.ctc_qdrift_cutoff_sigma
        ctc_prehist_sigma       = lq_config_ch.ctc_prehist_sigma
        lq_types                = collect(keys(lq_config_ch.lq_funcs))
        lq_funcs                = lq_config_ch.lq_funcs

        lq_classifiers          = Symbol.(lq_config_ch.lq_classifiers)

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(det) already processed, check missing lq_classifiers"
            for classifier in lq_classifiers
                if !haskey(pars_db[det], classifier)
                    pars_db_det_classifier = pars_db[det][classifier]
                    log_info = log_nt_cal(ch, det, ProcessStatus(1), classifier, drift_result.func,"Already processed --> skipped.")
                    processed_dict[classifier] = false
                    log_info_dict[classifier] = log_ch
                end
            end
            for classifier in lq_classifiers
                if haskey(pars_db[det], Symbol("lq_cut_of_$classifier"))
                    log_info = log_nt_cut((ch, det, ProcessStatus(1), classifier, final_result.cut, final_result.peaks.lq_aoe[:Tl208DEP].sf, final_result.qbb.lq_aoe.sf, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[aoe_classifier] = log_info
                    processed_dict[aoe_classifier] = false
                end
            end
        end

        hit_cal = nothing
        e_cal, e_uncal, lq, qdrift = nothing, nothing, nothing, nothing
        DEP_σ = nothing

        try 
            @debug("Load data")

            hit_cal = calibrate_ged_channel_data(l200, filekey, det, read_ldata(:dataQC, l200, :jlhit, :cal, period, run, ch); keep_chdata=true)

            e_cal = getproperty(hit_cal, e_cal_type)
            e_uncal = getproperty(hit_cal, e_uncal_type)
            lq = getproperty(hit_cal, :lq)
            qdrift = getproperty(hit_cal, :qdrift)

            aoe_cut = getproperty(hit_cal, :aoe_sg_classifier_low_cut)


            pd = l200.par.rpars.ecal(filekey) 
            DEP_σ = mvalue(pd[det].e_cusp_ctc.fit.Tl208DEP.fwhm / 2.355)


        catch e
            @error "Error in loading data: $e"
            throw(ErrorException("Error in loading data: $e"))
        end

        lq_e_corr, dt_eff = nothing, nothing
        lq_e_corr_expression, dt_eff_expression = nothing, nothing
        try
            @debug "Calculate energy corrected and normalized lq and effective drift time"

            lq_e_corr = lq ./ e_uncal
            dt_eff = qdrift ./ e_uncal

            #cuts_lq = cut_single_peak(lq, 0.0, quantile(filter(isfinite, lq), 0.99); n_bins=-1)
            #lq ./= cuts_lq.max

            lq_e_corr_expression = "(lq / $e_uncal_type)"
            dt_eff_expression = "(qdrift / $e_uncal_type)"
        catch e
            @error "Error in energy correction: $e"
            throw(ErrorException("Error in energy correction: $e"))
        end


        @showprogress desc="Detector: $det" for classifier in lq_classifiers
            if haskey(processed_dict, classifier)
                println("Already processed")
                continue
            end
            try
                
                @debug "Calibrate $classifier"
                drift_result, drift_report = nothing, nothing
                try 
                    drift_result, drift_report = lq_ctc_correction(lq_e_corr, dt_eff, e_cal, DEP_µ, DEP_σ;
                    ctc_dep_edgesigma=ctc_dep_edgesigma , ctc_driftime_cutoff_method=ctc_driftime_cutoff_method, lq_outlier_sigma = lq_outlier_sigma, drift_time_outlier_sigma=drift_time_outlier_sigma, lq_e_corr_expression=lq_e_corr_expression, dt_eff_expression=dt_eff_expression, ctc_dt_eff_low_quantile=ctc_dt_eff_low_quantile, ctc_dt_eff_high_quantile=ctc_dt_eff_high_quantile, pol_fit_order=pol_fit_order)
                catch e
                    @error "Error in drift time correction: $e"
                    throw(ErrorException("Error in drift time correction: $e"))
                end

                #create and save plots
                p = plot(drift_report, e_cal, dt_eff, lq_e_corr, :DEP)
                plot!(title="Drift Time vs LQ in DEP for Detector: $det")
                savelfig(savefig, p, l200, filekey, det, Symbol("drift_time_vs_lq_plot_DEP_$classifier"))

                p = plot(drift_report, e_cal, dt_eff, lq_e_corr, :whole) 
                plot!(title="Drift Time vs LQ for Detector: $det")
                savelfig(savefig, p, l200, filekey, det, Symbol("drift_time_vs_lq_plot_$classifier"))

                #create log entry
                log_info = log_nt_cal(ch, det, ProcessStatus(1), classifier, drift_result.func, "-")

                # add results to dict
                result_dict[classifier]   = drift_result
                log_info_dict[classifier] = log_info
                processed_dict[classifier] = true

                # free memory
                GC.gc()
            catch e
                @error "Error in $classifier calibration: $(truncate_string(string(e)))"
                log_info = log_nt_cal((ch, det, ProcessStatus(0), classifier, "-", truncate_string(string(e))))

                # add results to dict
                log_info_dict[classifier] = log_info
                processed_dict[classifier] = false
            end
        end
        @info "LQ classifier construction for channel $ch ($det) finished"

        # add lq constructor results to pars_db
        result_ch = (result = result_dict, processed = processed_dict, log = log_info_dict)
        result_lq_cons = Dict{NamedTuple, NamedTuple}(chinfo_ch => result_ch)
        pars_db_ch = create_pars(pars_db_ch, result_lq_cons)

        # continue with lq cut
        @showprogress desc="Detector: $det" for classifier in lq_classifiers
            if haskey(processed_dict, Symbol("lq_cut_of_$classifier"))
                continue
            end
            try
                @debug "Generate lq cut"

                #get lq classifier
                lq_class = nothing
                try
                    lq_class = ljl_propfunc(pars_db_ch[det][classifier].func).(hit_cal)
                catch e
                    @error "Error in lq class calculation: $e"
                    throw(ErrorException("Error in lq class calculation"))
                end
                
                #calculate LQ cut parameter value
                result, report = nothing, nothing
                try
                    result, report = lq_cut(DEP_µ, DEP_σ, e_cal, lq_class; cut_sigma=cut_sigma, dep_sideband_sigma=dep_sideband_sigma, cut_truncation_sigma=cut_truncation_sigma)
                catch e
                    @error "Error in LQ cut calculation: $e"
                    throw(ErrorException("Error in LQ cut calculation: $e"))
                end

                #create and save plots
                p=plot(report, lq_class, e_cal, :fit)
                plot!(title="Fit of LQ Cut for Detector: $det")
                savelfig(savefig, p, l200, filekey, det, Symbol("lq_cut_fit_$classifier"))

                p=plot(report, lq_class, e_cal, :sideband)
                plot!(title="Sidebands for Detector: $det")
                savelfig(savefig, p, l200, filekey, det, Symbol("sidebands_$classifier"))

                p = plot(report, lq_class, e_cal, :lq_cut)
                plot!(title="LQ Cut for Detector: $det")
                savelfig(savefig, p, l200, filekey, det, Symbol("lq_cut_$classifier"))

                p = plot(report, lq_class, e_cal, :energy_hist)
                plot!(title="Energy Spectrum of Detector: $det")
                savelfig(savefig, p, l200, filekey, det, Symbol("energy_hist_$classifier"))

                p = plot(report, lq_class, e_cal, :cut_fraction)
                plot!(title="LQ cutted events in $det")
                savelfig(savefig, p, l200, filekey, det, Symbol("cut_fraction_$classifier"))
                

                @debug("starting to calculate SF values for lq cut")

                result_peaks, report_peaks = nothing, nothing
                try
                    result_peaks, report_peaks = get_peaks_surrival_fractions(lq_class, e_cal, lq_peaks, lq_peaks_names, lq_peaks_windows_left, lq_peaks_windows_right, result.cut; inverted_mode=true)
                catch e
                    @error "Error in peak surrival fraction calculation: $e"
                    throw(ErrorException("Error in peak surrival fraction calculation: $e"))
                end

                result_qbb, report_qbb = nothing, nothing
                try
                    result_qbb, report_qbb = get_continuum_surrival_fraction(lq_class, e_cal, qbb_pos, qbb_window, result.cut, inverted_mode=true)
                catch e
                    @error "Error in qbb surrival fraction calculation: $e"
                    throw(ErrorException("Error in qbb surrival fraction calculation: $e"))
                end

                @debug("starting to calculate SF values for lq cut after aoe cut")

                result_peaks_aoe, report_peaks_aoe = nothing, nothing
                try
                    result_peaks_aoe, report_peaks_aoe = get_peaks_surrival_fractions(lq_class[aoe_cut], e_cal[aoe_cut], lq_peaks, lq_peaks_names, lq_peaks_windows_left, lq_peaks_windows_right, result.cut; inverted_mode=true)
                catch e
                    @error "Error in peak surrival fraction calculation: $e"
                    throw(ErrorException("Error in peak surrival fraction calculation: $e"))
                end

                result_qbb_aoe, report_qbb_aoe = nothing, nothing
                try
                    result_qbb_aoe, report_qbb_aoe = get_continuum_surrival_fraction(lq_class[aoe_cut], e_cal[aoe_cut], qbb_pos, qbb_window, result.cut, inverted_mode=true)
                catch e
                    @error "Error in qbb surrival fraction calculation: $e"
                    throw(ErrorException("Error in qbb surrival fraction calculation: $e"))
                end


                # save results
                final_result = merge(result, (peaks = (lq = result_peaks, lq_aoe = result_peaks_aoe), qbb = (lq = result_qbb, lq_aoe = result_qbb_aoe)))

                log_info = log_nt_cut((ch, det, ProcessStatus(1), lq_class, final_result.cut, final_result.peaks.lq_aoe[:Tl208DEP].sf, final_result.qbb.lq_aoe.sf, "-"))

                # add results to dict
                result_dict[Symbol("lq_cut_of_$classifier")] = final_result
                log_info_dict[Symbol("lq_cut_of_$classifier")] = log_info
                processed_dict[Symbol("lq_cut_of_$classifier")] = true

                GC.gc()
            catch e
                @error "Error in lq cut generation: $(truncate_string(string(e)))"
                log_info = log_nt_cut((ch, det, ProcessStatus(0), lq_class, "-", "-", "-", truncate_string(string(e))))
                
                # add results to dict
                log_info_dict[Symbol("lq_cut_of_$classifier")] = log_info
                processed_dict[Symbol("lq_cut_of_$classifier")] = false
            end
        end

        # cleanup log and combine
        log_info_dict_cleaned = Dict{Symbol, NamedTuple}()
        for classifier in lq_classifiers
            log_info_dict_cleaned[classifier] = merge(log_info_dict[classifier], log_info_dict[Symbol("lq_cut_of_$(string(classifier))")])
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
