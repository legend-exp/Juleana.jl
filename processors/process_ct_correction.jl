function process_ct_correction(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)

    @info "CT correction for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = Table(channelinfo(l200, filekey; system=:geds, only_processable=true))
    @info "Loaded channel info with $(length(chinfo)) detectors"

    energy_config = dataprod_config(l200).energy(filekey)
    @debug "Loaded energy config: $(lstring(energy_config))"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.ctc), string(period)))
    pars_db = PropDict(l200.par.rpars.ctc[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all detectors" end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :Channel, :Status, Symbol("Filter Type"), Symbol("FCT/1E6"), Symbol("FWHM Before"), Symbol("FWHM After"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    function det_ct_correction(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector

        @debug "Processing detector $det ($ch)"

        hitchfilename = l200.tier[:jlhit, filekey, det]
        # load data file
        if !isfile(hitchfilename)
            @error "Hit file $hitchfilename not found"
            throw(ErrorException("Hit file not found"))
        end

        result_dict    = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        energy_config_det = merge(energy_config.default, get(energy_config, det, PropDict()))
        ctc_config_det = merge(energy_config.ctc.default, get(energy_config.ctc, det, PropDict()))

        energy_types = Symbol.(ctc_config_det.energy_types)

        if !reprocess && haskey(pars_db, det)
            @debug "Detector $(det) already processed, check missing energy types"
            for e_type in energy_types
                if haskey(pars_db[det], e_type)
                    @debug "Filter $e_type already processed, skip"
                    log_info = log_nt((det, ch, ProcessStatus(1), e_type, pars_db[det][e_type].fct*1e6, pars_db[det][e_type].fwhm_before, pars_db[det][e_type].fwhm_after, "Already processed --> skipped."))
                    processed_dict[e_type] = false
                    log_info_dict[e_type] = log_info
                end
            end
        end

        # get data
        data_det_after_qc = nothing
        try
            @debug "Load hit file"
            if !all([haskey(processed_dict, e_type) for e_type in energy_types])
                data_det_after_qc = read_ldata(:dataQC, l200, :jlhit, :cal, period, run, det).dataQC
            end
        catch e
            @error "Error in loading data for detector $det: $(truncate_error(e))"
            throw(ErrorException("Error data loader"))
        end

        quantile_perc = if energy_config_det.quantile_perc isa String parse(Float64, energy_config_det.quantile_perc) else energy_config_det.quantile_perc end

        # get special config for CTC
        ctc_cal_peak = ctc_config_det.peak

        @showprogress desc="Detector: $det" for e_type in energy_types
            if haskey(processed_dict, e_type)
                continue
            end
            
            try
                @debug "Correct $e_type"

                result_simple, report_simple = nothing, nothing
                try
                    @debug "Get $e_type simple calibration"
                    result_simple, report_simple = simple_calibration(getproperty(data_det_after_qc, e_type), energy_config_det.th228_lines, energy_config_det.left_window_sizes, energy_config_det.right_window_sizes,; calib_type=:th228, quantile_perc=quantile_perc, binning_peak_window=energy_config_det.binning_peak_window)
                catch e
                    @error "Error in $e_type simple calibration for detector $det: $(truncate_error(e))"
                    throw(ErrorException("Error in $e_type simple calibration"))
                end

                # get simple calibration constant
                m_cal_simple = result_simple.c
                # save plots for simple calibration for control
                p = LegendMakie.lplot(report_simple, cal = true, title = get_plottitle(filekey, det, "Simple Calibration"; additional_type=string(e_type)))
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("simple_calibration_$(e_type)"))

                yield()

                result_ctc, report_ctc = nothing, nothing
                try
                    @debug "Get $e_type Charge Trapping Alpha"
                    result_ctc, report_ctc = ctc_energy(getproperty(data_det_after_qc, e_type) .* m_cal_simple, data_det_after_qc.qdrift, ctc_config_det.peak, (ctc_config_det.left_window_size, ctc_config_det.right_window_size), m_cal_simple; e_expression="$e_type", pol_order=ctc_config_det.ctc_order)
                catch e
                    @error "Error in $e_type alpha generation $det: $(truncate_error(e))"
                    throw(ErrorException("Error in $e_type alpha generation"))
                end
                
                @debug "Found Best $e_type FWHM: $(round(u"keV", result_ctc.fwhm_after, digits=2))"
                @debug "Found $e_type FCTs: $(round.(result_ctc.fct .* 1e6, digits=2))E-6"
                
                p = LegendMakie.lplot(report_ctc, figsize = (600,600), title = get_plottitle(filekey, det, "CTC"; additional_type="$e_type $ctc_cal_peak"))            
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, Symbol("ctc_$(e_type)"))

                yield()
                log_ch = log_nt((det, ch, ProcessStatus(1), "$e_type", result_ctc.fct*1e6, result_ctc.fwhm_before, result_ctc.fwhm_after, "-"))

                # add results to dict
                result_dict[e_type]   = result_ctc
                log_info_dict[e_type] = log_ch
                processed_dict[e_type] = true
            catch e
                @error "Error in $e_type CT correction: $(truncate_error(e))"
                log_ch = log_nt((det, ch, ProcessStatus(0), "$e_type", "-", "-", "-", "$(truncate_error(e))"))
                # add results to dict
                log_info_dict[e_type] = log_ch
                processed_dict[e_type] = false
            end
        end

        return (result = result_dict, log = log_info_dict, processed = processed_dict)
    end

    # get start time
    start_time = now()

    result_ctc = parallel(chinfo, det_ct_correction, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished CT correction"

    pars_db = create_pars(pars_db, result_ctc)
    writelprops(l200.par.rpars.ctc[period], run, pars_db)
    writevalidity(l200.par.rpars.ctc, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, energy_ctc_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_ctc))

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    # flush stdout
    flush(stdout)
end