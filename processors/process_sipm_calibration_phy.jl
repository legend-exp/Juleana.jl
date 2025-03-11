function process_sipm_calibration_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)
        
    @info "Process SiPM calibration for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:spms, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) channels"

    calibration_config = dataprod_config(l200).sipm(filekey).calibration
    @debug "Loaded calibration config: $(calibration_config)"

    qc_config = dataprod_config(l200).qc(filekey)
    @debug "Loaded QC config: $(qc_config)"

    chinfo_puls = channelinfo(l200, filekey, Symbol(qc_config.pulser.puls_channel))
    @info "Loaded pulser channel info: $(chinfo_puls)"

    ch_puls = chinfo_puls.channel
    det_puls = chinfo_puls.detector

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.sipmcal), string(period)))
    pars_db = PropDict(l200.par.rpars.sipmcal[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" end

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Status, Symbol("Filter Type"), Symbol("1PE Pos."), Symbol("1PE Res."), Symbol("Cal. Constant"), :Error)}
    
    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    # function to process decay time
    function ch_sipm_calibration(chinfo_ch::NamedTuple)

        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        @debug "Processing channel $ch ($det)"

        result_dict    = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        calibration_config_ch = merge(calibration_config.default, get(calibration_config, det, PropDict()))

        pulser_config_ch = merge(qc_config.pulser.default, get(qc_config.pulser, det, PropDict()))

        energy_types = Symbol.(calibration_config_ch.energy_types)

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(det) already processed, check missing energy types"
            for e_type in energy_types
                if haskey(pars_db[det], e_type)
                    @debug "Filter $e_type already processed, skip"
                    log_info = log_nt((ch, det, ProcessStatus(1), e_type, pars_db[det][e_type].fit.positions[1], pars_db[det][e_type].fit.resolutions_cal[1], pars_db[det][e_type].cal.par[2], "Already processed --> skipped."))
                    processed_dict[e_type] = false
                    log_info_dict[e_type] = log_info
                end
            end
        end

        # get data
        data_dsp = nothing
        try
            @debug "Load DSP data"
            # load DSP data and apply QC cut
            data_dsp = read_ldata(l200, DataTier(:jldsp), :phy, period, run, ch)
        catch e
            @error "Error in loading DSP data for channel $ch: $(truncate_error(e))"
            throw(ErrorException("Error data loader"))
        end

        is_pulser = nothing
        try
            @debug "Get Pulser tags"
            data_pulser = read_ldata(:tags, l200, DataTier(:jlpls), :phy, period, run, ch_puls)
            is_pulser = flag_coincidences(data_dsp.timestamp, data_pulser.timestamp[data_pulser.aux_trig], ts_window = pulser_config_ch.puls_ts_window)
            @debug "Found $(count(is_pulser)) pulser events"
        catch e
            @error "Error in Pulser tag for channel $ch: $(truncate_error(e))"
            throw(ErrorException("Error in Pulser tag for channel: $(truncate_error(e))"))
        end

        # get data
        data_ch_after_qc = nothing
        try
            @debug "Load hit data"
            # load DSP data and apply QC cut
            data_ch_after_qc = data_dsp[findall(ljl_propfunc(calibration_config_ch.qc).(data_dsp) .&& .!is_pulser)]
        catch e
            @error "Error in loading data for channel $ch: $(truncate_error(e))"
            throw(ErrorException("Error data loader"))
        end

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
                    e_uncal = filter(isfinite, reduce(vcat, getproperty(data_ch_after_qc, e_type)))
                    e_uncal_func = "$e_type"
                catch e
                    @error "Error in $e_type data extraction for channel $ch: $(truncate_error(e))"
                    throw(ErrorException("Error in $e_type data extraction"))
                end

                p = LegendMakie.lplot(fit(Histogram, e_uncal, calibration_config_ch.simple.kwargs.initial_min_amp:0.1:calibration_config_ch.simple.kwargs.initial_max_amp), 
                    xlabel = "Peak Amplitudes (ADC)", ylabel = "Counts / 0.1", label="Uncalibrated PE", yscale = Makie.log10, 
                    title = get_plottitle(filekey, det, "PE Uncalibrated"; additional_type=string(e_type)))
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("pe_uncalibrated_$(e_type)"))

                # get uncalibrated energy function
                result_simple, report_simple = nothing, nothing
                try
                    @debug "Get $e_type simple calibration"
                    result_simple, report_simple = sipm_simple_calibration(e_uncal; NamedTuple(calibration_config_ch.simple.kwargs)...)
                catch e
                    @error "Error in $e_type simple calibration for channel $ch: $(truncate_error(e))"
                    throw(ErrorException("Error in $e_type simple calibration"))
                end
                GC.gc()

                # save plots for simple calibration for control
                p = LegendMakie.lplot(report_simple, cal = true, title = get_plottitle(filekey, det, "Simple Calibration"; additional_type=string(e_type)))
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("sipm_simple_calibration_$(e_type)"))
                yield()

                result_fit, report_fit = nothing, nothing
                try
                    @debug "Fit all $e_type peaks"
                    result_fit, report_fit = fit_sipm_spectrum(result_simple.pe_simple_cal, calibration_config_ch.fit.min_pe, calibration_config_ch.fit.max_pe; 
                            NamedTuple(calibration_config_ch.fit.kwargs)...,
                            f_uncal=result_simple.f_simple_uncal, uncertainty=true)
                catch e
                    @error "Error in $e_type peak fitting for channel $ch: $(truncate_error(e))"
                    throw(ErrorException("Error in $e_type peak fitting"))
                end
                GC.gc()

                p = LegendMakie.lplot(report_fit, figsize = (700,500), xerrscaling = 5, title = get_plottitle(filekey, det, "Peak Fits"; additional_type=string(e_type)))
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("sipm_peak_fits_$(e_type)"))

                yield()

                @debug "Get $e_type calibration values"
                peak_fit_cut = findall(isfinite.(result_fit.positions))

                result_calib, report_calib = nothing, nothing
                try
                    result_calib, report_calib = fit_calibration(calibration_config_ch.pol_order, result_fit.positions[peak_fit_cut], collect(result_fit.peaks)[peak_fit_cut] .* u"e_au"; e_expression=e_type)
                    @debug "Found $e_type calibration curve: $(result_calib.func)"
                catch e
                    @error "Error in $e_type calibration curve fitting for channel $ch: $(truncate_error(e))"
                    throw(ErrorException("Error in $e_type calibration curve fitting"))
                end

                p = LegendMakie.lplot(report_calib, xerrscaling = 5, title = get_plottitle(filekey, det, "Calibration Curve"; additional_type=string(e_type)))
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("sipm_calibration_curve_$(e_type)"))
                
                log_info = log_nt((ch, det, ProcessStatus(1), e_type, result_fit.positions[1], result_fit.resolutions_cal[1], result_calib.par[2], "-"))

                result_energy = (
                    m_cal_simple = result_simple.c,
                    n_cal_simple = result_simple.offset,
                    cal = result_calib,
                    fit  = result_fit,
                )

                # add results to dict
                result_dict[e_type]   = result_energy
                log_info_dict[e_type] = log_info
                processed_dict[e_type] = true

                GC.gc()
            catch e
                @error "Error in processing channel $ch: $(truncate_error(e))"
                log_info = log_nt((ch, det, ProcessStatus(0), e_type, "-", "-", "-", string(e)))
                # add results to dict
                log_info_dict[e_type] = log_info
                processed_dict[e_type] = false
            end
        end

        return (result = result_dict, log = log_info_dict, processed = processed_dict)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_sipm_calibration = parallel(chinfo, ch_sipm_calibration, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")
    @info "Finished SiPM calibration"

    pars_db = create_pars(pars_db, result_sipm_calibration)
    writelprops(l200.par.rpars.sipmcal[period], run, pars_db)
    writevalidity(l200.par.rpars.sipmcal, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, sipm_cal_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_sipm_calibration))

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report
    
    # flush stdout
    flush(stdout)
end