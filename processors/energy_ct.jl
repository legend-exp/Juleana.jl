function process_ct_correction(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=300)

    @info "CT correction for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = Table(channelinfo(l200, filekey; system=:geds, only_processable=true))
    @info "Loaded channel info with $(length(chinfo)) channels"

    energy_config = dataprod_config(l200).energy(filekey)
    @debug "Loaded energy config: $(energy_config)"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.ctc), string(period)))
    pars_db = ifelse(l200.par.rpars.ctc[period, run] isa LegendDataManagement.NoSuchPropsDBEntry, PropDict(), l200.par.rpars.ctc[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" end

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Status, Symbol("Filter Type"), Symbol("FCT/1E6"), Symbol("FWHM Before"), Symbol("FWHM After"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # move all variables to workers
    @everywhere begin
        l200 = $l200
        filekey = $filekey
        chinfo = $chinfo
        pars_db = $pars_db
        reprocess = $reprocess
        energy_config = $energy_config
        log_nt = $log_nt
    end

    @everywhere function ch_ct_correction(chinfo_ch::NamedTuple)

        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        @debug "Processing channel $ch ($det)"

        hitchfilename = get_hitchfilename(l200, filekey, ch)
        # load data file
        if !isfile(hitchfilename)
            @error "Hit file $hitchfilename not found"
            throw(ErrorException("Hit file not found"))
        end

        result_dict    = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        energy_config_ch = merge(energy_config.default, get(energy_config, det, PropDict()))
        ctc_config_ch = merge(energy_config.ctc.default, get(energy_config.ctc, det, PropDict()))

        energy_types = Symbol.(ctc_config_ch.energy_types)

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(det) already processed, check missing energy types"
            for e_type in energy_types
                if haskey(pars_db[det], e_type)
                    @debug "Filter $filter_type already processed, skip"
                    log_info = log_nt((ch, det, ProcessStatus(1), e_type, pars_db[det][e_type].fct, pars_db[det][e_type].fwhm_before, pars_db[det][e_type].fwhm_after, "Already processed --> skipped."))
                    processed_dict[e_type] = false
                    log_info_dict[e_type] = log_info
                end
            end
        end

        # get data
        data_ch_after_qc = nothing
        try
            @debug "Load hit file"
            data_hit = lh5open(hitchfilename, "r");
            data_ch_after_qc = data_hit["$(ch)"].dataQC[:];
            close(data_hit)
        catch e
            @error "Error in loading data for channel $ch: $e"
            throw(ErrorException("Error data loader"))
        end
        

        if length(data_ch_after_qc) < 50000
            @error "Not enough data points for channel $ch ($det), skip"
            throw(ErrorException("Not enough data points for channel $ch ($det)"))
        end

        quantile_perc = if energy_config_ch.quantile_perc isa String parse(Float64, energy_config_ch.quantile_perc) else energy_config_ch.quantile_perc end

        # get special config for CTC
        ctc_cal_peak = ctc_config_ch.peak

        for e_type in energy_types
            if haskey(processed_dict, e_type)
                continue
            end
            
            try
                @debug "Correct $e_type"

                result_simple, report_simple = nothing, nothing
                try
                    @debug "Get $e_type simple calibration"
                    result_simple, report_simple = simple_calibration(getproperty(data_ch_after_qc, e_type), energy_config_ch.th228_lines, energy_config_ch.left_window_sizes, energy_config_ch.right_window_sizes,; calib_type=:th228, n_bins=energy_config_ch.n_bins, quantile_perc=quantile_perc)
                catch e
                    @error "Error in $e_type simple calibration for channel $ch: $e"
                    throw(ErrorException("Error in $e_type simple calibration"))
                end

                # get simple calibration constant
                m_cal_simple = result_simple.c
                # save plots for simple calibration for control
                p = plot(report_simple, margin=5mm, yformatter=:plain, thickness_scaling=1.5, cal=true)
                title!(p, get_plottitle(filekey, det, "Simple Calibration"; additiional_type=string(e_type)))
                savelfig(p, l200, filekey, ch, Symbol("simple_calibration_$(e_type)"))

                yield()

                result_ctc, report_ctc = nothing, nothing
                try
                    @debug "Get $e_type Charge Trapping Alpha"
                    result_ctc, report_ctc = ctc_energy(getproperty(data_ch_after_qc, e_type) .* m_cal_simple, data_ch_after_qc.qdrift, ctc_config_ch.peak, (ctc_config_ch.left_window_size, ctc_config_ch.right_window_size))
                catch e
                    @error "Error in $e_type alpha generation $ch: $e"
                    throw(ErrorException("Error in $e_type alpha generation"))
                end
                fct = result_ctc.fct / m_cal_simple
                @debug "Found Best $e_type FWHM: $(round(u"keV", result_ctc.fwhm_after, digits=2))"
                @debug "Found $e_type FCT: $(round(fct*1e6, digits=2))E-6"
                
                p = plot(report_ctc)
                plot!(p, plot_title=get_plottitle(filekey, det, "Charge Trapping Correction"; additiional_type="$e_type $ctc_cal_peak keV"))
                savelfig(p, l200, filekey, ch, Symbol("ctc_$(e_type)"))

                yield()

                result = (
                    fct = result_ctc.fct / m_cal_simple,
                    fwhm_before = result_ctc.fwhm_before,
                    fwhm_after = result_ctc.fwhm_after,
                    peak = ctc_cal_peak,
                )
                log_ch = log_nt((ch, det, ProcessStatus(1), "$e_type", fct*1e6, result.fwhm_before, result.fwhm_after, "-"))

                # add results to dict
                result_dict[e_type]   = result
                log_info_dict[e_type] = log_ch
                processed_dict[e_type] = true
            catch e
                @error "Error in $e_type CT correction: $e"
                log_ch = log_nt((ch, det, ProcessStatus(0), "$e_type", "-", "-", "-", "$e"))
                # add results to dict
                log_info_dict[e_type] = log_ch
                processed_dict[e_type] = false
            end
        end

        return (result = result_dict, log = log_info_dict, processed = processed_dict)
    end

    # get start time
    start_time = now()

    result_ctc = parallel(chinfo, ch_ct_correction, log_nt, wpool; timeout=timeout)

    @info "Finished CT correction"

    pars_db = create_pars(pars_db, result_ctc)
    writelprops(l200.par.rpars.ctc[period], run, pars_db)
    writevalidity(l200.par.rpars.ctc, filekey)
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
    writelreport(get_logfilename(l200, filekey, :ctc), report)
    @info report
end