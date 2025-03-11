function process_psd_efficiencies(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0, use_partition_pars::Bool=true)

    @info "Generate PSD efficiencies for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true) |> filterby(@pf $usability == :on && $low_aoe_status in [:valid, :present])
    @info "Loaded channel info with $(length(chinfo)) channels"

    psd_config = dataprod_config(l200).psd(filekey).psd
    @debug "Loaded psd config: $(psd_config)"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.psd), string(period)))
    pars_db = PropDict(l200.par.rpars.psd[period, run])

    pars_type = ifelse(use_partition_pars, :ppars, :rpars)
    @info "Use $(ifelse(use_partition_pars, "partition", "run"))-based pars from $pars_type for PSD parameters"
    
    pars_aoe = get_values(l200.par[pars_type, :aoe](filekey))
    @debug "Loaded aoe pars"

    pars_lq = get_values(l200.par[pars_type, :lq](filekey))
    @debug "Loaded lq pars"

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" end

    # create log line Tuple
    log_nt_cut = NamedTuple{(:Channel, :Detector, :Status, Symbol("Classifier Type"), Symbol("Cut Value"), Symbol("SEP SF"), Symbol("FEP SF"), :CutError)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))
    
    # flush stdout
    flush(stdout)

    function ch_psd_sf(chinfo_ch::NamedTuple)

        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        @info "Processing channel $ch ($det)"

        pars_db_ch = get(pars_db, det, PropDict())

        result_dict    = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        psd_config_ch = merge(psd_config.default, get(psd_config, det, PropDict()))

        e_type = Symbol(psd_config_ch.e_type)
        psd_classifiers = collect(keys(psd_config_ch.psd_classifiers))
        psd_classifiers_dict = psd_config_ch.psd_classifiers

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(det) already processed, check missing energy types"
            for psd_classifier in psd_classifiers
                if haskey(pars_db[det], psd_classifier)
                    log_info = log_nt_cut((ch, det, ProcessStatus(1), psd_classifier, pars_db[det][psd_classifier].lowcut, pars_db[det][psd_classifier].peaks.ds[:Tl208SEP].sf, pars_db[det][psd_classifier].peaks.ds[:Tl208FEP].sf, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[psd_classifier] = log_info
                    processed_dict[psd_classifier] = false
                end
            end
        end

        e_cal, hit_cal = nothing, nothing
        try
            hit_cal = let dsp=read_ldata(:dataQC, l200, :jlhit, :cal, period, run, ch), e_type_cal=e_type, e_type=Symbol(first(split(string(e_type), "_cal")))
                @debug "Reading from $(period)-$(run)"
                    Table(merge(NamedTuple{(e_type_cal, )}([collect(ljl_propfunc(l200.par.rpars.ecal[period, run][det][e_type].cal.func).(dsp))]), columns(dsp)))
                end
            e_cal = getproperty(hit_cal, e_type)
        catch e
            @error "Hit data for $det from cannot be loaded: $(truncate_error(e))"
            throw(LoadError("Hit data", 154, "Hit data for $det from $period-$run cannot be loaded: $(truncate_error(e))"))
        end

        @showprogress desc="Detector: $det" for psd_classifier in psd_classifiers
            if haskey(processed_dict, psd_classifier)
                continue
            end
            try
                @debug "Generate $psd_classifier cut"

                aoe_classifier = Symbol(psd_classifiers_dict[psd_classifier][1])
                aoe_high_cut = psd_classifiers_dict[psd_classifier][2]
                lq_classifier = Symbol(psd_classifiers_dict[psd_classifier][3])

                aoe, aoe_low_cut = nothing, nothing
                try
                    aoe = ljl_propfunc(pars_aoe[det][Symbol(first(split(string(aoe_classifier), "_classifier")))].func).(hit_cal)
                    aoe_low_cut = pars_aoe[det][aoe_classifier].lowcut
                catch e
                    @error "AoE for $det from cannot be loaded"
                    throw(LoadError("AoE", 154, "AoE data for $det cannot be loaded"))
                end

                lq, lq_cut = nothing, nothing
                try
                    lq = ljl_propfunc(pars_lq[det][Symbol(first(split(string(lq_classifier), "_classifier")))].func).(hit_cal)
                    lq_cut = pars_lq[det][lq_classifier].cut
                catch e
                    @error "LQ for $det from cannot be loaded"
                    throw(LoadError("LQ", 154, "LQ data for $det cannot be loaded"))
                end

                @debug "Use low A/E cut at $(round(aoe_low_cut, digits=2)) and high A/E cut at $(round(aoe_high_cut, digits=2))"


                ### low A/E cut
                result_peaks_low, report_peaks_low = nothing, nothing
                try
                    @debug "Generate A/E low Survival Fractions"
                    result_peaks_low, report_peaks_low = get_peaks_survival_fractions(aoe, e_cal, psd_config_ch.psd_peaks, Symbol.(psd_config_ch.psd_peaks_names), psd_config_ch.psd_peaks_windows_left, psd_config_ch.psd_peaks_windows_right, aoe_low_cut,; 
                                                    bin_width_window=psd_config_ch.psd_peaks_bin_width_window, sigma_high_sided=Inf, fit_funcs=Symbol.(psd_config_ch.psd_peaks_fit_funcs), uncertainty=true)
                catch e
                    @error "AoE peaks low SF for $det cannot be generated"
                    throw(ErrorException("AoE peaks low SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found low SEP Survival Fraction at $(round(u"percent", result_peaks_low[:Tl208SEP].sf, digits=2))"
                @debug "Found low FEP Survival Fraction at $(round(u"percent", result_peaks_low[:Tl208FEP].sf, digits=2))"

                qbb_result_low = nothing
                try
                    qbb_result_low, _ = get_continuum_survival_fraction(aoe, e_cal, psd_config_ch.qbb, psd_config_ch.qbb_window, aoe_low_cut,; sigma_high_sided=Inf)
                catch e
                    @error "Qbb low SF for $det cannot be generated"
                    throw(ErrorException("Qbb low SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found low Qbb Survival Fraction at $(round(u"percent", qbb_result_low.sf, digits=2))"

                ### low A/E cut & high A/E cut
                result_peaks_ds, report_peaks_ds = nothing, nothing
                try
                    @debug "Generate A/E DS Survival Fractions"
                    result_peaks_ds, report_peaks_ds = get_peaks_survival_fractions(aoe, e_cal, psd_config_ch.psd_peaks, Symbol.(psd_config_ch.psd_peaks_names), psd_config_ch.psd_peaks_windows_left, psd_config_ch.psd_peaks_windows_right, aoe_low_cut,; 
                                                    bin_width_window=psd_config_ch.psd_peaks_bin_width_window, sigma_high_sided=aoe_high_cut, fit_funcs=Symbol.(psd_config_ch.psd_peaks_fit_funcs), uncertainty=true)
                catch e
                    @error "AoE peaks DS SF for $det cannot be generated"
                    throw(ErrorException("AoE peaks DS SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found DS SEP Survival Fraction at $(round(u"percent", result_peaks_ds[:Tl208SEP].sf, digits=2))"
                @debug "Found DS FEP Survival Fraction at $(round(u"percent", result_peaks_ds[:Tl208FEP].sf, digits=2))"

                qbb_result_ds = nothing
                try
                    qbb_result_ds, _ = get_continuum_survival_fraction(aoe, e_cal, psd_config_ch.qbb, psd_config_ch.qbb_window, aoe_low_cut,; sigma_high_sided=aoe_high_cut)
                catch e
                    @error "Qbb DS SF for $det cannot be generated"
                    throw(ErrorException("Qbb DS SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found DS Qbb Survival Fraction at $(round(u"percent", qbb_result_ds.sf, digits=2))"


                ### low A/E cut & LQ cut
                result_peaks_low_lq, report_peaks_low_lq = nothing, nothing
                try
                    @debug "Generate A/E DS Survival Fractions"
                    result_peaks_low_lq, report_peaks_low_lq = get_peaks_survival_fractions(aoe, e_cal, psd_config_ch.psd_peaks, Symbol.(psd_config_ch.psd_peaks_names), psd_config_ch.psd_peaks_windows_left, psd_config_ch.psd_peaks_windows_right, aoe_low_cut, lq .< lq_cut; 
                                                    bin_width_window=psd_config_ch.psd_peaks_bin_width_window, sigma_high_sided=Inf, fit_funcs=Symbol.(psd_config_ch.psd_peaks_fit_funcs), uncertainty=true)
                catch e
                    @error "AoE peaks DS SF for $det cannot be generated"
                    throw(ErrorException("AoE peaks DS SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found LQ DS SEP Survival Fraction at $(round(u"percent", result_peaks_low_lq[:Tl208SEP].sf, digits=2))"
                @debug "Found LQ DS FEP Survival Fraction at $(round(u"percent", result_peaks_low_lq[:Tl208FEP].sf, digits=2))"

                qbb_result_low_lq = nothing
                try
                    qbb_result_low_lq, _ = get_continuum_survival_fraction(aoe, e_cal, psd_config_ch.qbb, psd_config_ch.qbb_window, aoe_low_cut, lq .< lq_cut; sigma_high_sided=Inf)
                catch e
                    @error "Qbb DS SF for $det cannot be generated"
                    throw(ErrorException("Qbb DS SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found DS Qbb Survival Fraction at $(round(u"percent", qbb_result_low_lq.sf, digits=2))"



                ### low A/E cut & high A/E cut & LQ cut
                result_peaks_lq_ds, report_peaks_lq_ds = nothing, nothing
                try
                    @debug "Generate A/E DS Survival Fractions"
                    result_peaks_lq_ds, report_peaks_lq_ds = get_peaks_survival_fractions(aoe, e_cal, psd_config_ch.psd_peaks, Symbol.(psd_config_ch.psd_peaks_names), psd_config_ch.psd_peaks_windows_left, psd_config_ch.psd_peaks_windows_right, aoe_low_cut, lq .< lq_cut; 
                                                    bin_width_window=psd_config_ch.psd_peaks_bin_width_window, sigma_high_sided=aoe_high_cut, fit_funcs=Symbol.(psd_config_ch.psd_peaks_fit_funcs), uncertainty=true)
                catch e
                    @error "AoE peaks DS SF for $det cannot be generated"
                    throw(ErrorException("AoE peaks DS SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found LQ DS SEP Survival Fraction at $(round(u"percent", result_peaks_lq_ds[:Tl208SEP].sf, digits=2))"
                @debug "Found LQ DS FEP Survival Fraction at $(round(u"percent", result_peaks_lq_ds[:Tl208FEP].sf, digits=2))"

                qbb_result_lq_ds = nothing
                try
                    qbb_result_lq_ds, _ = get_continuum_survival_fraction(aoe, e_cal, psd_config_ch.qbb, psd_config_ch.qbb_window, aoe_low_cut, lq .< lq_cut; sigma_high_sided=aoe_high_cut)
                catch e
                    @error "Qbb DS SF for $det cannot be generated"
                    throw(ErrorException("Qbb DS SF for $det from $period-$run cannot be generated"))
                end

                @debug "Found DS Qbb Survival Fraction at $(round(u"percent", qbb_result_lq_ds.sf, digits=2))"


                # p = plot(broadcast(k -> plot(report_peaks_ds[k].after, show_components=false, left_margin=20mm, top_margin=-5mm, bottom_margin=-2mm, peak_name=string(k), ms=2), keys(report_peaks_ds))..., layout=(length(report_peaks_ds), 1), size=(1000,710*length(report_peaks_ds)) , thickness_scaling=1.8, titlefontsize = 10, legendfontsize = 8, yguidefontsize = 9, xguidefontsize=11)
                # plot!(plot_title=get_plottitle(filekey, det, "A/E DS Performance"; additional_type=string(psd_classifier)), plot_titlelocation=(0.5,0.2), plot_titlefontsize = 9)
                # savelfig(savefig, p, l200, filekey, det, Symbol("aoe_peaks_ds_sf_$psd_classifier"))

                # save results
                result = merge((cuts = (lowcut = aoe_low_cut, highcut = aoe_high_cut, lq = lq_cut), ), (peaks = (low = result_peaks_low, ds = result_peaks_ds, low_lq = result_peaks_low_lq, lq_ds = result_peaks_lq_ds) , qbb = (low = qbb_result_low, ds = qbb_result_ds, low_lq = qbb_result_low_lq, lq_ds = qbb_result_lq_ds)))

                log_info = log_nt_cut((ch, det, ProcessStatus(1), psd_classifier, aoe_low_cut, result.peaks.ds[:Tl208SEP].sf, result.peaks.ds[:Tl208FEP].sf, "-"))

                # add results to dict
                result_dict[psd_classifier]   = result
                log_info_dict[psd_classifier] = log_info
                processed_dict[psd_classifier] = true

                GC.gc()
            catch e
                @error "Error in $psd_classifier cut generation: $(truncate_error(e))"
                log_info = log_nt_cut((ch, det, ProcessStatus(0), psd_classifier, "-", "-", "-", truncate_error(e)))
                
                # add results to dict
                log_info_dict[psd_classifier] = log_info
                processed_dict[psd_classifier] = false
            end
        end

        return (result = result_dict, log = log_info_dict, processed = processed_dict)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_psd = parallel(chinfo, ch_psd_sf, log_nt_cut, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished PSD efficiencies"

    pars_db = create_pars(pars_db, result_psd)
    writelprops(l200.par.rpars.psd[period], run, pars_db)
    writevalidity(l200.par.rpars.psd, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, aoe_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_psd))

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    # flush stdout
    flush(stdout)
end
