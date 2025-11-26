function process_energy_calibration(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Union{Int, Bool}=false)
    
    @info "Energy calibration for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) channels"

    energy_config = dataprod_config(l200).energy(filekey)
    @debug "Loaded energy config: $(energy_config)"

    pars_ctc = get_values(l200.par.rpars.ctc[period, run])
    @debug "Loaded CTC parameters"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.ecal), string(period)))
    pars_db = PropDict(l200.par.rpars.ecal[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" end

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Status, Symbol("Filter Type"), Symbol("FWHM Qbb"), Symbol("FWHM FEP"), Symbol("Cal. Constant"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

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

    function ch_energy_calibration(chinfo_ch::NamedTuple)
        
        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        @debug "Processing channel $ch ($det)"

        result_dict    = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()


        energy_config_ch = merge(energy_config.default, get(energy_config, det, PropDict()))

        energy_types = Symbol.(energy_config_ch.energy_types)

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(det) already processed, check missing energy types"
            for e_type in energy_types
                if haskey(pars_db[det], e_type)
                    @debug "Filter $e_type already processed, skip"
                    log_info = log_nt((ch, det, ProcessStatus(1), e_type, pars_db[det][e_type].fwhm.qbb, pars_db[det][e_type].fit.Tl208FEP.fwhm, pars_db[det][e_type].cal.par[2], "Already processed --> skipped."))
                    processed_dict[e_type] = false
                    log_info_dict[e_type] = log_info
                end
            end
        end

        # get data
        data_ch_after_qc = nothing
        try
            @debug "Load hit file"
            # prevent from loading if all energy types are already processed
            if !all([haskey(processed_dict, e_type) for e_type in energy_types])
                data_ch_after_qc = read_hit_data(:dataQC, l200, :cal, period, run, det, ch).dataQC
            end
        catch e
            @error "Error in loading data for channel $ch: $(truncate_error(e))"
            throw(ErrorException("Error data loader"))
        end

        quantile_perc = if energy_config_ch.quantile_perc isa String parse(Float64, energy_config_ch.quantile_perc) else energy_config_ch.quantile_perc end
        th228_names = Symbol.(energy_config_ch.th228_names)
        th228_lines_dict = Dict(th228_names .=> energy_config_ch.th228_lines)

        @showprogress desc="Detector: $det" for e_type in energy_types
            if haskey(processed_dict, e_type)
                continue
            end
            try
                @debug "Calibrate $e_type"

                # get data
                e_uncal, e_uncal_func = nothing, nothing
                try
                    @debug "Get $e_type data"
                    # open hit data file
                    e_type_name = Symbol(split(string(e_type), "_ctc")[1])
                    e_uncal = getproperty(data_ch_after_qc, e_type_name)
                    e_uncal_func = "$e_type_name"
                    if endswith(string(e_type), "_ctc")
                        @debug "Apply CT correction for $e_type"
                        e_uncal_func = pars_ctc[det][e_type_name].func
                        e_uncal = ljl_propfunc(e_uncal_func).(data_ch_after_qc)
                    end
                catch e
                    @error "Error in $e_type data extraction for channel $ch: $(truncate_error(e))"
                    throw(ErrorException("Error in $e_type data extraction"))
                end
                GC.gc()

                result_simple, report_simple = nothing, nothing
                try
                    @debug "Get $e_type simple calibration"
                    result_simple, report_simple = simple_calibration(e_uncal, energy_config_ch.th228_lines, energy_config_ch.left_window_sizes, energy_config_ch.right_window_sizes,; calib_type=:th228, quantile_perc=quantile_perc, binning_peak_window=energy_config_ch.binning_peak_window)
                catch e
                    @error "Error in $e_type simple calibration for channel $ch: $(truncate_error(e))"
                    throw(ErrorException("Error in $e_type simple calibration"))
                end
                GC.gc()

                # get simple calibration constant
                m_cal_simple = result_simple.c
                # save plots for simple calibration for control
                p = LegendMakie.lplot(report_simple, title = get_plottitle(filekey, det, "Simple Calibration"; additional_type=string(e_type)), cal = true)
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("simple_calibration_$(e_type)"))
                yield()

                result_fit, report_fit = nothing, nothing
                try
                    @debug "Fit all $e_type peaks"
                    result_fit, report_fit = fit_peaks(result_simple.peakhists, result_simple.peakstats, th228_names; 
                                                e_unit=result_simple.unit, calib_type=:th228, fit_func=Symbol.(energy_config_ch.th228_fit_func), m_cal_simple=m_cal_simple)
                catch e
                    @error "Error in $e_type peak fitting for channel $ch: $(truncate_error(e))"
                    throw(ErrorException("Error in $e_type peak fitting"))
                end
                GC.gc()

                p = LegendMakie.lplot(report_fit, figsize = (600, 400*length(report_fit)), title = get_plottitle(filekey, det, "Peak Fits"; additional_type=string(e_type)))
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("peak_fits_$(e_type)"))

                yield()

                # fit QC peaks
                fit_qc = energy_config_ch.qc.fit
        
                # peak fitting QC
                fwhm_cut = [result_fit[th228_names[i]].fwhm .* m_cal_simple > energy_config_ch.qc.min_fwhm && result_fit[th228_names[i]].fwhm .* m_cal_simple .< energy_config_ch.qc.max_fwhm_per_window * (energy_config_ch.left_window_sizes[i] + energy_config_ch.right_window_sizes[i]) for i in eachindex(th228_names)]
                qc_cut = ljl_propfunc(fit_qc).([result_fit[k] for k in th228_names]) .&& fwhm_cut
        
                th228_names_qc = th228_names[qc_cut]
                th228_names_cut = th228_names[.!qc_cut]

                @debug "Get $e_type calibration values"

                th228_names_qc_cal_fit = [p for p in th228_names_qc if !(p in Symbol.(energy_config_ch.cal_fit_excluded_peaks))]

                result_calib, report_calib = nothing, nothing
                try
                    μ_fit =  [result_fit[p].centroid for p in th228_names_qc_cal_fit]
                    pp_fit = [th228_lines_dict[p] for p in th228_names_qc_cal_fit]
                    result_calib, report_calib = fit_calibration(energy_config_ch.cal_pol_order, μ_fit, pp_fit; e_expression=e_uncal_func)
                    @debug "Found $e_type calibration curve: $(result_calib.func)"
                catch e
                    @error "Error in $e_type calibration curve fitting for channel $ch: $(truncate_error(e))"
                    throw(ErrorException("Error in $e_type calibration curve fitting"))
                end
                # add not-fitted peaks to plot 
                μ_notfit =  [result_fit[p].centroid for p in th228_names if !(p in th228_names_qc_cal_fit)]
                pp_notfit = [th228_lines_dict[p] for p in th228_names if !(p in th228_names_qc_cal_fit)]

                p = LegendMakie.lplot(report_calib, xerrscaling=100, additional_pts=(μ = μ_notfit, peaks = pp_notfit), title = get_plottitle(filekey, det, "Calibration Curve"; additional_type=string(e_type)))
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("calibration_curve_$(e_type)"))

                yield()

                f_cal_widths(x) = report_calib.f_fit(x) .* report_calib.e_unit .- first(report_calib.par)

                th228_names_qc_fwhm_fit = [p for p in th228_names_qc if !(p in Symbol.(energy_config_ch.fwhm_fit_excluded_peaks))]

                result_fwhm, report_fwhm = nothing, nothing
                try
                    fwhm_fit = f_cal_widths.([result_fit[p].fwhm for p in th228_names_qc_fwhm_fit])
                    pp_fit = [th228_lines_dict[p] for p in th228_names_qc_fwhm_fit] 
                    result_fwhm, report_fwhm = fit_fwhm(energy_config_ch.fwhm_pol_order, pp_fit, fwhm_fit; e_type_cal=Symbol("$(e_type)_cal"), e_expression=e_uncal_func, uncertainty=true)
                    @debug "Found $e_type FWHM: $(round(u"keV", result_fwhm.qbb, digits=2))"
                catch e
                    @error "Error in $e_type FWHM fitting for channel $ch: $(truncate_error(e))"
                    throw(ErrorException("Error in $e_type FWHM fitting"))
                end
                fwhm_notfit =  f_cal_widths.([result_fit[p].fwhm for p in th228_names if !(p in th228_names_qc_fwhm_fit)])
                pp_notfit = [th228_lines_dict[p] for p in th228_names if !(p in th228_names_qc_fwhm_fit)]

                p = LegendMakie.lplot(report_fwhm, additional_pts=(peaks = pp_notfit, fwhm = fwhm_notfit), title = get_plottitle(filekey, det, "FWHM"; additional_type=string(e_type)))
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("fwhm_$(e_type)"))
                
                f_cal_pos(x) = report_calib.f_fit(x) .* report_calib.e_unit

                # calibrate best fit values
                width_pars = [:σ, :fwhm]
                position_pars = [:μ, :centroid]
                for (peak, result_peak) in result_fit
                    result_peak = merge(result_peak, NamedTuple{Tuple(width_pars)}([f_cal_widths(result_peak[k]) for k in width_pars]...))
                    result_peak = merge(result_peak, NamedTuple{Tuple(position_pars)}([f_cal_pos(result_peak[k]) for k in position_pars]...))
                    result_fit[peak] = result_peak
                end

                yield()

                log_info = log_nt((ch, det, ProcessStatus(1), e_type, result_fwhm.qbb, result_fit[:Tl208FEP].fwhm, result_calib.par[2], "-"))

                result_energy = (
                    m_cal_simple = m_cal_simple,
                    fwhm = result_fwhm,
                    cal = result_calib,
                    fit  = result_fit,
                )

                # add results to dict
                result_dict[e_type]   = result_energy
                log_info_dict[e_type] = log_info
                processed_dict[e_type] = true

                GC.gc()
            catch e
                @error "Error in $e_type calibration: $(truncate_error(e))"
                log_info = log_nt((ch, det, ProcessStatus(0), e_type, "-", "-", "-", truncate_error(e)))
                # add results to dict
                log_info_dict[e_type] = log_info
                processed_dict[e_type] = false
            end
        end


        return (result = result_dict, log = log_info_dict, processed = processed_dict)
    end

    # get start time
    start_time = now()

    result_energy = parallel(chinfo, ch_energy_calibration, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished energy calibration"

    pars_db = create_pars(pars_db, result_energy)
    writelprops(l200.par.rpars.ecal[period], run, pars_db)
    writevalidity(l200.par.rpars.ecal, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, energy_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_energy))

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    # flush stdout
    flush(stdout)
end