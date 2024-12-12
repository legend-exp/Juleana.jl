function process_sipm_calibration_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod,; reprocess::Bool=false, timeout::Int=0, only_first_period::Bool=true)
        
    @info "Process SiPM calibration for all partitions containing period $period"

    rinfo = runinfo(l200, period)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).phy.startkey
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:spms, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) channels"

    if reprocess @info "Reprocess all channels" else @info "Only process channels not in pars_db" end

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Partition, :Status, Symbol("Filter Type"), Symbol("1PE Pos."), Symbol("1PE Res."), Symbol("Cal. Constant"), :Error)}
    
    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # get unfolded channel info where each entry is a detector and its partition for all partitions that contain period
    chinfo_unfolded = get_partition_channelinfo(l200, chinfo, period; unfold_partitions=true)

    # flush stdout
    flush(stdout)

    # function to process decay time
    function ch_sipm_calibration(chinfo_ch::NamedTuple)

        ch  = chinfo_ch.channel
        det = chinfo_ch.detector
        part = chinfo_ch.partition

        @info "Processing channel $ch ($det)"

        pars_db_ch = if isfile(joinpath(data_path(l200.par.ppars.sipmcal), "$det", "$part.json"))
            PropDict(l200.par.ppars.sipmcal[det, part])
        else
            PropDict()
        end

        partinfo_ch = partitioninfo(l200, ch, part)
        @debug "Loaded channel partition info with $(length(partinfo_ch)) runs"
    
        filekey_ch = start_filekey(l200, (first(partinfo_ch.period), first(partinfo_ch.run), :phy))
        @debug "Found filekey $filekey_ch"

        validity_ch = get_partitionvalidity(l200, ch, det, part, :phy)

        calibration_config = dataprod_config(l200).sipm(filekey_ch).calibration
        calibration_config_ch = merge(calibration_config.default, get(calibration_config, det, PropDict()))
        @debug "Loaded calibration config: $(calibration_config_ch)"

        energy_types = Symbol.(calibration_config_ch.energy_types)

        result_dict    = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        if (only_first_period && period != first(partinfo_ch.period))
            @info "Only first period in partition $part for $period in $ch ($det)"
            for e_type in energy_types
                log_info = log_nt((ch, det, part, ProcessStatus(1), e_type, fill("-", 3)..., "Only first periods --> skipped."))
                # add results to dict
                log_info_dict[aoe_type] = log_info
                processed_dict[aoe_type] = false
            end
            return (processed = processed_dict, log = log_info_dict, validity = validity_ch, skipped = true)
        end

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(det) already processed, check missing energy types"
            for e_type in energy_types
                if haskey(pars_db[det], e_type)
                    @debug "Filter $e_type already processed, skip"
                    log_info = log_nt((ch, det, part, ProcessStatus(1), e_type, pars_db[det][e_type].fit.positions[1], pars_db[det][e_type].fit.resolutions_cal[1], pars_db[det][e_type].cal.par[2], "Already processed --> skipped."))
                    processed_dict[e_type] = false
                    log_info_dict[e_type] = log_info
                end
            end
        end

        # get data
        data_ch_after_qc = nothing
        try
            @debug "Load hit data"
            # load DSP data and apply QC cut
            data_dsp = read_ldata(l200, :jldsp, :phy, partinfo_ch, ch)
            data_ch_after_qc = data_dsp[findall(ljl_propfunc(calibration_config_ch.qc).(data_dsp))]
        catch e
            @error "Error in loading data for channel $ch: $(truncate_string(string(e)))"
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
                    e_uncal = reduce(vcat, getproperty(data_ch_after_qc, e_type))
                    e_uncal_func = "$e_type"
                catch e
                    @error "Error in $e_type data extraction for channel $ch: $(truncate_string(string(e)))"
                    throw(ErrorException("Error in $e_type data extraction"))
                end

                # get uncalibrated energy function
                result_simple, report_simple = nothing, nothing
                try
                    @debug "Get $e_type simple calibration"
                    result_simple, report_simple = sipm_simple_calibration(e_uncal; 
                            initial_min_amp=calibration_config_ch.simple.initial_min_amp, initial_max_quantile=calibration_config_ch.simple.initial_max_quantile,
                            peakfinder_σ=calibration_config_ch.simple.peakfinder_σ, peakfinder_threshold=calibration_config_ch.simple.peakfinder_threshold)
                catch e
                    @error "Error in $e_type simple calibration for channel $ch: $(truncate_string(string(e)))"
                    throw(ErrorException("Error in $e_type simple calibration"))
                end
                GC.gc()

                # save plots for simple calibration for control
                p = plot(report_simple, cal=true, yscale=:log10)
                title!(p, get_plottitle(filekey_ch, part, det, "Simple Calibration"; additiional_type=string(e_type)))
                savelfig(savefig, p, l200, part, filekey_ch, det, Symbol("sipm_simple_calibration_$(e_type)"))
                yield()

                result_fit, report_fit = nothing, nothing
                try
                    @debug "Fit all $e_type peaks"
                    result_fit, report_fit = fit_sipm_spectrum(result_simple.pe_simple_cal, calibration_config_ch.fit.min_pe, calibration_config_ch.fit.max_pe; 
                            method=Symbol(calibration_config_ch.fit.init_method), nInit=calibration_config_ch.fit.nInit, nIter=calibration_config_ch.fit.nIter, 
                            f_uncal=result_simple.f_simple_uncal, uncertainty=true)
                catch e
                    @error "Error in $e_type peak fitting for channel $ch: $(truncate_string(string(e)))"
                    throw(ErrorException("Error in $e_type peak fitting"))
                end
                GC.gc()

                p = plot(report_fit, show_peaks=true, xerrscaling=5, show_residuals=true, show_components=true)
                plot!(p, plot_title=get_plottitle(filekey_ch, part, det, "Peak Fits"; additiional_type=string(e_type)), plot_titlelocation=(0.5,0.2), plot_titlefontsize = 12)
                savelfig(savefig, p, l200, part, filekey_ch, det, Symbol("sipm_peak_fits_$(e_type)"))

                yield()

                @debug "Get $e_type calibration values"

                result_calib, report_calib = nothing, nothing
                try
                    result_calib, report_calib = fit_calibration(calibration_config_ch.pol_order, result_fit.positions, collect(result_fit.peaks).*u"e_au"; e_expression=e_type)
                    @debug "Found $e_type calibration curve: $(result_calib.func)"
                catch e
                    @error "Error in $e_type calibration curve fitting for channel $ch: $(truncate_string(string(e)))"
                    throw(ErrorException("Error in $e_type calibration curve fitting"))
                end

                p = plot(report_calib, xerrscaling=5)
                plot!(plot_title=get_plottitle(filekey_ch, part, det, "Calibration Curve"; additiional_type=string(e_type)), plot_titlelocation=(0.5,0.3), plot_titlefontsize=12)
                savelfig(savefig, p, l200, part, filekey_ch, det, Symbol("sipm_calibration_curve_$(e_type)"))
                
                log_info = log_nt((ch, det, part, ProcessStatus(1), e_type, result_fit.positions[1], result_fit.resolutions_cal[1], result_calib.par[2], "-"))

                result_energy = (
                    m_cal_simple = result_simple.c,
                    cal = result_calib,
                    fit  = result_fit,
                )

                # add results to dict
                result_dict[e_type]   = result_energy
                log_info_dict[e_type] = log_info
                processed_dict[e_type] = true

                GC.gc()
            catch e
                @error "Error in processing channel $ch: $(truncate_string(string(e)))"
                log_info = log_nt((ch, det, part, ProcessStatus(0), e_type, "-", "-", "-", string(e)))
                # add results to dict
                log_info_dict[e_type] = log_info
                processed_dict[e_type] = false
            end
        end

        result_ch = (result = result_dict, processed = processed_dict, log = log_info_dict, validity = validity_ch)
        result_sipm_ch = Dict{NamedTuple, NamedTuple}(chinfo_ch => result_ch)

        pars_db_ch = create_pars(pars_db_ch, result_sipm_ch)
        writelprops(l200.par.ppars.sipmcal[det], part, pars_db_ch)
        writevalidity(l200.par.ppars.sipmcal[det], filekey_ch, part)

        # return results
        return result_ch
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_sipm_calibration = parallel(chinfo_unfolded, ch_sipm_calibration, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")
    
    @info "Finished SiPM partition calibration"

    @info "Write $period validity"
    validity_all = create_validity(result_sipm_calibration)
    writevalidity(l200.par.ppars.sipmcal, validity_all)

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
    writelreport(get_preportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report
    
    # flush stdout
    flush(stdout)

    return any(x -> get(last(x), :skipped, false), values(result_sipm_calibration))
end