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

    function ch_energy_calibration(chinfo_ch::NamedTuple)
        
        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        @debug "Processing channel $ch ($det)"

        hitchfilename = l200.tier[:jlhitch, filekey, ch]
        # load data file
        if !isfile(hitchfilename)
            @error "Hit file $hitchfilename not found"
            throw(ErrorException("Hit file not found"))
        end

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

        # load data file
        if !isfile(hitchfilename)
            @error "Hit file $hitchfilename not found"
            throw(ErrorException("Hit file not found"))
        end
        # get data
        data_ch_after_qc = nothing
        try
            @debug "Load hit file"
            data_hit = LHDataStore(hitchfilename, "r");
            data_ch_after_qc = data_hit[ch, :jlhit, :dataQC][:];
            close(data_hit)
        catch e
            @error "Error in loading data for channel $ch: $(truncate_string(string(e)))"
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
                    @error "Error in $e_type data extraction for channel $ch: $(truncate_string(string(e)))"
                    throw(ErrorException("Error in $e_type data extraction"))
                end
                GC.gc()

                result_simple, report_simple = nothing, nothing
                try
                    @debug "Get $e_type simple calibration"
                    result_simple, report_simple = simple_calibration(e_uncal, energy_config_ch.th228_lines, energy_config_ch.left_window_sizes, energy_config_ch.right_window_sizes,; calib_type=:th228, n_bins=energy_config_ch.n_bins, quantile_perc=quantile_perc, binning_peak_window=energy_config_ch.binning_peak_window)
                catch e
                    @error "Error in $e_type simple calibration for channel $ch: $(truncate_string(string(e)))"
                    throw(ErrorException("Error in $e_type simple calibration"))
                end
                GC.gc()

                # get simple calibration constant
                m_cal_simple = result_simple.c
                # save plots for simple calibration for control
                p = plot(report_simple, margin=5mm, yformatter=:plain, thickness_scaling=1.5, cal=true)
                title!(p, get_plottitle(filekey, det, "Simple Calibration"; additiional_type=string(e_type)))
                savelfig(savefig, p, l200, filekey, det, Symbol("simple_calibration_$(e_type)"))
                yield()

                result_fit, report_fit = nothing, nothing
                try
                    @debug "Fit all $e_type peaks"
                    result_fit, report_fit = fit_peaks(result_simple.peakhists, result_simple.peakstats, th228_names; e_unit=result_simple.unit, calib_type=:th228)
                catch e
                    @error "Error in $e_type peak fitting for channel $ch: $(truncate_string(string(e)))"
                    throw(ErrorException("Error in $e_type peak fitting"))
                end
                GC.gc()

                p = plot(broadcast(k -> plot(report_fit[k], left_margin=20mm, top_margin=-5mm, bottom_margin=-2mm, title=string(k), ms=2), keys(report_fit))..., layout=(length(report_fit), 1), size=(1000,710*length(report_fit)) , thickness_scaling=1.8, titlefontsize = 10, legendfontsize = 8, yguidefontsize = 9, xguidefontsize=11)
                plot!(p, plot_title=get_plottitle(filekey, det, "Peak Fits"; additiional_type=string(e_type)), plot_titlelocation=(0.5,0.2), plot_titlefontsize = 12)
                savelfig(savefig, p, l200, filekey, det, Symbol("peak_fits_$(e_type)"))

                yield()

                @debug "Get $e_type calibration values"

                result_calib, report_calib = nothing, nothing
                try
                    μ_fit =  [result_fit[p].μ for p in th228_names if !(p in Symbol.(energy_config_ch.cal_fit_excluded_peaks))] ./ m_cal_simple
                    pp_fit = [th228_lines_dict[p] for p in th228_names if !(p in Symbol.(energy_config_ch.cal_fit_excluded_peaks))]
                    result_calib, report_calib = fit_calibration(energy_config_ch.cal_pol_order, μ_fit, pp_fit; e_expression=e_uncal_func)
                    @debug "Found $e_type calibration curve: $(result_calib.func)"
                catch e
                    @error "Error in $e_type calibration curve fitting for channel $ch: $(truncate_string(string(e)))"
                    throw(ErrorException("Error in $e_type calibration curve fitting"))
                end
                # add not-fitted peaks to plot 
                μ_notfit =  [result_fit[p].μ for p in Symbol.(energy_config_ch.cal_fit_excluded_peaks)] ./ m_cal_simple
                pp_notfit = [th228_lines_dict[p] for p in Symbol.(energy_config_ch.cal_fit_excluded_peaks)]
        
                p = plot(report_calib, xerrscaling=1, additional_pts=(μ = μ_notfit, peaks = pp_notfit))
                plot!(plot_title=get_plottitle(filekey, det, "Calibration Curve"; additiional_type=string(e_type)), plot_titlelocation=(0.5,-0.3), plot_titlefontsize=12)
                savelfig(savefig, p, l200, filekey, det, Symbol("calibration_curve_$(e_type)"))

                yield()

                f_cal(x) = report_calib.f_fit(x) .* report_calib.e_unit .- first(report_calib.par)

                result_fwhm, report_fwhm = nothing, nothing
                try
                    fwhm_fit = f_cal.([result_fit[p].fwhm for p in th228_names if !(p in Symbol.(energy_config_ch.:fwhm_fit_excluded_peaks))] ./ m_cal_simple)
                    pp_fit = [th228_lines_dict[p] for p in th228_names if !(p in Symbol.(energy_config_ch.:fwhm_fit_excluded_peaks))]    
                    result_fwhm, report_fwhm = fit_fwhm(pp_fit, fwhm_fit; pol_order=energy_config_ch.fwhm_pol_order, e_type_cal=Symbol("$(e_type)_cal"), e_expression=e_uncal_func, uncertainty=true)
                    @debug "Found $e_type FWHM: $(round(u"keV", result_fwhm.qbb, digits=2))"
                catch e
                    @error "Error in $e_type FWHM fitting for channel $ch: $(truncate_string(string(e)))"
                    throw(ErrorException("Error in $e_type FWHM fitting"))
                end
                fwhm_notfit =  f_cal.([result_fit[p].fwhm for p in Symbol.(energy_config_ch.cal_fit_excluded_peaks)] ./ m_cal_simple)
                pp_notfit = [th228_lines_dict[p] for p in Symbol.(energy_config_ch.:fwhm_fit_excluded_peaks)]
        

                p = plot(report_fwhm, additional_pts=(peaks = pp_notfit, fwhm = fwhm_notfit))
                plot!(plot_title=get_plottitle(filekey, det, "FWHM"; additiional_type=string(e_type)), plot_titlelocation=(0.5,-0.3))
                savelfig(savefig, p, l200, filekey, det, Symbol("fwhm_$(e_type)"))
                
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
                @error "Error in $e_type CT correction: $(truncate_string(string(e)))"
                log_info = log_nt((ch, det, ProcessStatus(0), e_type, "-", "-", "-", e))
                # add results to dict
                log_info_dict[e_type] = log_info
                processed_dict[e_type] = false
            end
        end


        return (result = result_dict, log = log_info_dict, processed = processed_dict)
    end

    # get start time
    start_time = now()

    result_energy = parallel(chinfo, ch_energy_calibration, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period-", "$period-$run"))-$(nameof(var"#self#"))")

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
    writelreport(get_rreportfilename(l200, filekey, :energy_calibration), report)
    @info report

    # flush stdout
    flush(stdout)
end