function p_process_aoe_calibration_cut(processing_config::PropDict, l200::LegendData, period::DataPeriod,; reprocess::Bool=false, timeout::Int=0, only_first_period::Bool=true)
    
    @info "Generate AoE cut for all partitions containing period $period"

    rinfo = runinfo(l200, period) |> filterby(@pf $cal.is_analysis_run)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).cal.startkey
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true) |> filterby(@pf $low_aoe_status in [:valid, :present])
    @info "Loaded channel info with $(length(chinfo)) channels"

    if reprocess @info "Reprocess all channels" else @info "Only process channels not in pars_db" end

    # create log line Tuple
    log_nt_cal = NamedTuple{(:Channel, :Detector, :Partition, :Status, Symbol("Filter Type"), Symbol("N Compt. Bands"), Symbol("Median norm. Resid."), Symbol("StD norm. Resid."), Symbol("FCT"), :CalError)}
    log_nt_cut = NamedTuple{(:Channel, :Detector, :Partition, :Status, Symbol("Classifier Type"), Symbol("Cut Value"), Symbol("SEP SF"), Symbol("FEP SF"), :CutError)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # get unfolded channel info where each entry is a detector and its partition for all partitions that contain period
    chinfo_unfolded = get_partition_channelinfo(l200, chinfo, period, :cal; unfold_partitions=true)

    # flush stdout
    flush(stdout)

    if !@isdefined(read_hit_data)
        function read_hit_data(selector, l200::LegendData, category::DataCategoryLike, period::DataPeriodLike, run::DataRunLike, det::DetectorIdLike, ch::ChannelIdLike; kwargs...)
            try
                return read_ldata(selector, l200, :jlhit, category, period, run, det; kwargs...)
            catch err
                @warn "Detector-keyed hit data missing for $det ($ch), falling back to channel" exception=(err, catch_backtrace())
                return read_ldata(selector, l200, :jlhit, category, period, run, ch; kwargs...)
            end
        end
    end
    
    function ch_aoe_cut(chinfo_ch::NamedTuple)
        
        ch  = chinfo_ch.channel
        det = chinfo_ch.detector
        part = chinfo_ch.partition

        @info "Processing channel $ch ($det)"

        mkpath(joinpath(data_path(l200.par.ppars.aoe), string(det)))
        pars_db_ch = if isfile(joinpath(data_path(l200.par.ppars.aoe), "$det", "$part.yaml")) && !reprocess
            PropDict(l200.par.ppars.aoe[det, part])
        else
            mkpath(joinpath(data_path(l200.par.ppars.aoecut), "$det"))
            PropDict()
        end

        partinfo_ch = partitioninfo(l200, det, part)
        @debug "Loaded channel partition info with $(length(partinfo_ch)) runs"
    
        filekey_ch = start_filekey(l200, (first(partinfo_ch.period), first(partinfo_ch.run), :cal))
        @debug "Found filekey $filekey_ch"

        validity_ch = get_partitionvalidity(l200, det, part)

        # load config
        aoe_config = dataprod_config(l200).psd(filekey_ch).aoe
        aoe_config_ch = merge(aoe_config.p_default, get(aoe_config.p, det, PropDict()))
        @debug "Loaded aoe config: $(aoe_config_ch)"

        compton_bands     = aoe_config_ch.compton_bands
        compton_window    = aoe_config_ch.compton_window
        p_value_cut       = aoe_config_ch.p_value # what is this? p values threshold 
        e_type            = Symbol(aoe_config_ch.e_type)
        aoe_types         = collect(keys(aoe_config_ch.aoe_funcs))
        aoe_funcs         = aoe_config_ch.aoe_funcs
        qdrift_expression = aoe_config_ch.qdrift_expression

        aoe_classifiers = Symbol.(aoe_config_ch.aoe_classifiers)

        # sigma_high_sided = ifelse(chinfo_ch.high_aoe_status == :valid, aoe_config_ch.sigma_high_sided, Inf)
        sigma_high_sided = aoe_config_ch.sigma_high_sided

        result_dict = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        if (only_first_period && period != first(partinfo_ch.period))
            @info "Only first period in partition $part for $period in $ch ($det)"
            for aoe_type in aoe_types
                log_info = log_nt_cal((ch, det, part, ProcessStatus(1), aoe_type, fill("-", 4)..., "Only first periods --> skipped."))
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
                if haskey(pars_db_ch[det], aoe_type)
                    pars_db_det_aoe_type = pars_db_ch[det][aoe_type]
                    log_info = log_nt_cal(ch, det, part, ProcessStatus(1), aoe_type, length(pars_db_det_aoe_type.μ_compton.μ), mean(pars_db_det_aoe_type.µ_compton.gof.residuals_norm), mean(pars_db_det_aoe_type.σ_compton.gof.residuals_norm), get(pars_db_det_aoe_type.ctc, :fct, NaN), "Already processed --> skipped.")
                    processed_dict[aoe_type] = false
                    log_info_dict[aoe_type] = log_info
                end
            end
            for aoe_classifier in aoe_classifiers
                if haskey(pars_db_ch[det], aoe_classifier)
                    log_info = log_nt_cut((ch, det, part, ProcessStatus(1), aoe_classifier, pars_db_ch[det][aoe_classifier].lowcut, pars_db_ch[det][aoe_classifier].peaks.ds[:Tl208SEP].sf, pars_db_ch[det][aoe_classifier].peaks.ds[:Tl208FEP].sf, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[aoe_classifier] = log_info
                    processed_dict[aoe_classifier] = false
                end
            end
        end

        e_cal, hit_cal, ts = nothing, nothing, nothing
        try
            if !all([haskey(processed_dict, aoe_type) for aoe_type in aoe_types]) || !all([haskey(processed_dict, aoe_classifier) for aoe_classifier in aoe_classifiers])
                hit_cal = fast_flatten([
                    let dsp=read_hit_data(:dataQC, l200, :cal, pinfo.period, pinfo.run, det, ch).dataQC, e_type_cal=e_type, e_type=Symbol(first(split(string(e_type), "_cal")))
                        @debug "Reading from $(pinfo.period)-$(pinfo.run)"
                        # calibrate_ged_channel_data(l200, pinfo.cal.startkey, det, read_ldata(:dataQC, l200, :jlhit, :cal, pinfo.period, pinfo.run, ch); keep_chdata=true) end
                            Table(merge(NamedTuple{(e_type_cal, )}([collect(ljl_propfunc(l200.par.rpars.ecal[pinfo.period, pinfo.run][det][e_type].cal.func).(dsp))]), columns(dsp)))
                    end
                    for pinfo in partinfo_ch])
                e_cal = getproperty(hit_cal, e_type)

                # get timestamps for stability plots
                ts = uconvert.(u"hr", hit_cal.timestamp)
                # correct for gaps in timestamps which correspond to phy runs
                run_idx = findall(diff(ts) .> 6u"hr") .+ 1
                for idx in run_idx
                    ts[idx:end] .-= (ts[idx] - ts[idx-1])
                end
                # normalize to first timestamp
                ts .-= first(ts)
            end
        catch e
            @error "E data for $det from cannot be loaded"
            throw(LoadError("E data", 154, "E data for $det from partition $(part) cannot be loaded: $(truncate_error(e))"))
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
                    @error "Error in $aoe_type simple normalization for channel $ch: $(truncate_error(e))"
                    throw(ErrorException("Error in $aoe_type simple normalization"))
                end
                GC.gc()

                h_aoe_uncal = fit(Histogram, (ustrip.(e_unit, e_cal[isfinite.(aoe)]), aoe[isfinite.(aoe)]), (0:0.5:3000, 0.1:5e-3:1.8))
                p = LegendMakie.lhist(h_aoe_uncal, figsize = (670,400), rasterize = true,
                    title = get_plottitle(filekey_ch, part, det, "uncalibrated A/E"; additional_type=string(aoe_type)),
                    xlabel = "Energy ($e_unit)",
                    titlesize = 14,
                    ylabel = Makie.rich("A/E", Makie.subscript(" norm")),
                    xticks = 0:500:3000,
                    yticks = 0.25:0.25:1.75
                )
                savelfig(LegendMakie.lsavefig, p, l200, part, filekey_ch, det, Symbol("aoe_uncalibrated_$aoe_type"))

                # cut around CC to get only compton band for stability plotting
                cc_min, cc_max = 0.9, 1.1
                aoe_cut = findall(cc_min .< aoe .< cc_max)
                # plot CC A/E over time
                h_aoe_stability = StatsBase.fit(StatsBase.Histogram, (Unitful.ustrip.(u"hr", ts[aoe_cut]), aoe[aoe_cut]), (0:0.01:ustrip(maximum(ts)), cc_min:5e-3:cc_max))
                p = LegendMakie.lhist(h_aoe_stability, xlabel = "Time (hr)", ylabel = "CC A/E (a.u.)", titlealign = :center, watermark = false,
                    title = get_plottitle(filekey_ch, part, det, "A/E stability"; additional_type=string(aoe_type)))
                savelfig(LegendMakie.lsavefig, p, l200, part, filekey_ch, det, Symbol("aoe_stability_$aoe_type"))

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
                    p_μ = LegendMakie.lplot(report_fit_single.report_μ, report_fit_combined.report_µ, legend_position = :lb, figsize = (600,420), title = get_plottitle(filekey_ch, part, det, "A/E μ"; additional_type=string(aoe_type)))
                    p_σ = LegendMakie.lplot(report_fit_single.report_σ, report_fit_combined.report_σ, legend_position = :rt, figsize = (600,420), title = get_plottitle(filekey_ch, part, det, "A/E σ"; additional_type=string(aoe_type)))
                    
                    # create corrected A/E values
                    aoe_corr = ljl_propfunc(result_fit_combined.func).(hit_cal)

                    # create result
                    result_correction = result_fit_combined
                else
                    # create plots
                    p_μ = LegendMakie.lplot(report_fit_single.report_μ, legend_position = :lb, figsize = (600,420), title = get_plottitle(filekey_ch, part, det, "A/E µ"; additional_type=string(aoe_type)))
                    p_σ = LegendMakie.lplot(report_fit_single.report_σ, legend_position = :rt, figsize = (600,420), title = get_plottitle(filekey_ch, part, det, "A/E σ"; additional_type=string(aoe_type)))

                    # create corrected A/E values
                    aoe_corr = ljl_propfunc(result_fit_single.func).(hit_cal)

                    # add GoF to result
                    single_fit_residuals = vcat([result_fit[band].gof.residuals_norm for band in compton_bands]...)
                    result_correction = merge(result_fit_single, (gof = (mean_residuals = mean(single_fit_residuals), median_residuals = median(single_fit_residuals), std_residuals = std(single_fit_residuals)), ))
                end
                    
                savelfig(LegendMakie.lsavefig, p_μ, l200, part, filekey_ch, det, Symbol("compton_bands_mu_$aoe_type"))
                savelfig(LegendMakie.lsavefig, p_σ, l200, part, filekey_ch, det, Symbol("compton_bands_sigma_$aoe_type"))

                # charge trapping correction
                result_aoe_ctc, report_aoe_ctc = NamedTuple(), NamedTuple()
                if aoe_config_ch.apply_ctc
                    try
                        qdrift_e = ljl_propfunc(qdrift_expression).(hit_cal)
                        result_aoe_ctc, report_aoe_ctc = LegendSpecFits.ctc_aoe(aoe_corr, e_cal, qdrift_e, compton_bands,
                            aoe_expression = result_correction.func, qdrift_expression = qdrift_expression)
                    catch e
                        @error "AoE classifier cannot be charge-trapping corrected: $(truncate_error(e))"
                        throw(ErrorException("AoE classifier cannot be charge-trapping corrected"))
                    end

                    # plot A/E ctc correlation plot
                    p = LegendMakie.lplot(report_aoe_ctc, figsize = (600,600), title = get_plottitle(filekey_ch, part, det, "A/E CT Correction"; additional_type=string(aoe_type)))
                    savelfig(LegendMakie.lsavefig, p, l200, part, filekey_ch, det, Symbol("aoe_ctc_$aoe_type"))

                    # plot A/E normalization after CTC
                    p = LegendMakie.lplot(report_aoe_ctc.report_after, xlims=(-20, 12), 
                        title = get_plottitle(filekey_ch, part, det, "$(first(compton_bands)) - $(last(compton_bands)) CTC"; additional_type=string(aoe_type)), 
                        xlabel = LaTeXStrings.latexstring("\\fontfamily{Roboto}" * "A/E_{CTC}"), ylabel = "Counts / $(round(step(report_aoe_ctc.report_after.h.edges[1]), digits=2))")
                    savelfig(LegendMakie.lsavefig, p, l200, part, filekey_ch, det, Symbol("aoe_compton_after_ctc_$aoe_type"))

                    aoe_corr = ljl_propfunc(result_aoe_ctc.func).(hit_cal)
                end

                # plot corrected A/E 2D histogram
                h_aoe_ec = fit(Histogram, (ustrip.(u"keV", e_cal), aoe_corr), (0:0.5:3000, -30:0.1:10))
                p = LegendMakie.lhist(h_aoe_ec, figsize = (670,400), rasterize = true,
                    title = get_plottitle(filekey_ch, part, det, "normalized A/E"; additional_type=string(aoe_type)),
                    titlesize = 14,
                    xlabel = "Energy ($e_unit)",
                    ylabel = Makie.rich("A/E", Makie.subscript(" ec")),
                    xticks = 0:500:3000,
                    yticks = -30:10:10
                )
                savelfig(LegendMakie.lsavefig, p, l200, part, filekey_ch, det, Symbol("aoe_normalized_$aoe_type"))

                log_info = log_nt_cal(ch, det, part, ProcessStatus(1), aoe_type, length(compton_bands), get(result_correction.gof, :median_residuals, NaN), get(result_correction.gof, :std_residuals, NaN), get(result_aoe_ctc, :fct, NaN), "-")

                # create result
                result = (
                            func = get(result_aoe_ctc, :func, result_correction.func),
                            ctc = result_aoe_ctc,
                            correction = result_correction,
                            apply_ctc = aoe_config_ch.apply_ctc,
                            use_combined_fit = aoe_config_ch.use_combined_fit,
                        )
                # add results to dict
                result_dict[aoe_type]   = result
                log_info_dict[aoe_type] = log_info
                processed_dict[aoe_type] = true

                # free memory
                GC.gc()
            catch e
                @error "Error in $aoe_type calibration: $(truncate_error(e))"
                log_info = log_nt_cal((ch, det, part, ProcessStatus(0), aoe_type, fill("-", 4)..., truncate_error(e)))
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

                h_aoe_ctc = fit(Histogram, (ustrip.(e_unit, e_cal), aoe), (0:0.5:3000, -20:0.1:10))
                p = LegendMakie.lhist(h_aoe_ctc, figsize = (670,400), rasterize = true,
                    title = get_plottitle(filekey_ch, part, det, ""; additional_type=string(aoe_classifier)),
                    xlabel = "Energy ($e_unit)",
                    ylabel = Makie.rich("A/E", Makie.subscript(" ctc")),
                    xticks = 0:500:3000,
                    yticks = -20:10:10
                )
                savelfig(LegendMakie.lsavefig, p, l200, part, filekey_ch, det, Symbol("aoe_normalized_$aoe_classifier"))

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
                p = LegendMakie.lplot(report_cut, figsize = (750,400), title = get_plottitle(filekey_ch, part, det, "A/E Performance"; additional_type=string(aoe_classifier)))
                savelfig(LegendMakie.lsavefig, p, l200, part, filekey_ch, det, Symbol("aoe_energy_afterAoE_zoom_$aoe_classifier"))

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

                p = LegendMakie.lplot(report_peaks_ds, titlesize = 17, figsize = (600, 400*length(report_peaks_ds)), title = get_plottitle(filekey_ch, part, det, "A/E Performance"; additional_type=string(aoe_classifier)))
                savelfig(LegendMakie.lsavefig, p, l200, part, filekey_ch, det, Symbol("aoe_peaks_sf_$aoe_classifier"))

                # save results
                result = merge(result_cut, (peaks = (low = result_peaks_low, ds = result_peaks_ds) , qbb = (low = qbb_result_low, ds = qbb_result_ds)))

                log_info = log_nt_cut((ch, det, part, ProcessStatus(1), aoe_classifier, result_cut.lowcut, result.peaks.ds[:Tl208SEP].sf, result.peaks.ds[:Tl208FEP].sf, "-"))

                # add results to dict
                result_dict[aoe_classifier]   = result
                log_info_dict[aoe_classifier] = log_info
                processed_dict[aoe_classifier] = true

                GC.gc()
            catch e
                @error "Error in $aoe_classifier cut generation: $(truncate_error(e))"
                log_info = log_nt_cut((ch, det, part, ProcessStatus(0), aoe_classifier, "-", "-", "-", truncate_error(e)))
                
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
        if !isempty(pars_db_ch)
            writelprops(l200.par.ppars.aoe[det], part, pars_db_ch)
            writevalidity(l200.par.ppars.aoe[det], filekey_ch, part)
        end

        return result_ch
    end

    # get start time
    start_time = now()

    result_aoe = parallel(chinfo_unfolded, ch_aoe_cut, merge(log_nt_cal, log_nt_cut), wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")
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

