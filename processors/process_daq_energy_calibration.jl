function process_daq_energy_calibration(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool = false, timeout::Int = 0)
    
    @info "Process DAQ energy calibration for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :geds, only_processable = true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    raw_config = dataprod_config(l200).raw(filekey)
    @debug "Loaded raw config: $(lstring(raw_config))"
    filekeys = filter(!in(bad_filekeys(l200; load_key = :unprocessable)), search_disk(FileKey, l200.tier[:raw, :cal, period, run]))
    @info "Found $(length(filekeys)) calibration filekeys"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.daqecal), string(period)))
    pars_db = PropDict(l200.par.rpars.daqecal[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)

    if reprocess @info "Reprocess all detectors" end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Status, Symbol("Cal. Constant"), Symbol("Total Time"), Symbol("Total Allocated"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    function calibrate_det(chinfo_det::NamedTuple)
        ch  = chinfo_det.channel
        det = chinfo_det.detector

        @info "Processing detector $det ($ch)"

        if !reprocess && haskey(pars_db, det)
            @debug "Detector $det already processed, skip"
            log_det = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), pars_db[det].c, "0", "0", "Already processed --> skipped."))
            return (processed = false, log = log_det)
        end

        config = merge(raw_config.default, get(raw_config, det, PropDict()))

        result, report = nothing, nothing
        calibration_timer = TimerOutput()
        @timeit calibration_timer "$det" begin
            @timeit calibration_timer "Get DAQ Energy" begin
                @debug "Reading DAQ energy for detector $det from $(length(filekeys)) files"
                e_daq = read_ldata(:daqenergy, l200, DataTier(:raw), filekeys, det).daqenergy
            end

            try
                @info "Auto calibrating $det ($ch)"
                result, report = autocal_energy(e_daq, config.th228_cal_lines; mode = :ratio,
                    min_e = config.min_e, max_e = config.max_e, max_e_binning_quantile = config.max_e_binning_quantile,
                    σ = config.σ, threshold = config.threshold, min_n_peaks = config.min_n_peaks,
                    max_n_peaks = config.max_n_peaks, α = config.α, rtol = config.rtol)

                # Plot the calibrated spectrum after a successful energy calibration.
                p = LegendMakie.lplot(report, config.th228_cal_lines; figsize = (650, 400),
                    title = get_plottitle(filekey, det, "Calibrated DAQ Online Energy"))
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, :daq_energy)
            catch e
                @error "Error in DAQ energy calibration for detector $det: $(truncate_error(e))"

                # If calibration or its plot fails, save a uncalibrated raw spectrum instead.
                binwidth = 8 * 15
                edges = range(0; step = binwidth, length = max(2, floor(Int, maximum(e_daq) / binwidth) + 2))
                histogram = StatsBase.fit(StatsBase.Histogram, e_daq, edges)
                fig = Makie.Figure(size = (650, 400))
                ax = Makie.Axis(fig[1, 1];
                    xlabel = "Energy (ADC)", ylabel = "Counts / $binwidth ADC", yscale = Makie.log10,
                    limits = (extrema(edges), (0.9, max(1, maximum(histogram.weights)) * 1.2)),
                    title = get_plottitle(filekey, det, "FAILED DAQ Calibration — Uncalibrated Spectrum"))
                Makie.stephist!(ax, StatsBase.midpoints(edges); weights = replace(histogram.weights, 0 => 1e-10), bins = edges, color = LegendMakie.BEGeOrange)
                LegendMakie.add_watermarks!(final = true)
                failed_filename = replace(LegendDataManagement.LDMUtils.get_pltfilename(l200, filekey, det, :daq_energy), r"\.png$" => "_failed.png")
                LegendMakie.lsavefig(fig, failed_filename)

                log_det = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(0), "-", "-", "-", truncate_error(e)))
                return (timer = calibration_timer, processed = false, log = log_det)
            end
        end

        total_time = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(calibration_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(calibration_timer))
        calibration = (c = result.c * u"keV", func = "$(repr(result.c)) * daqenergy * keV")
        log_det = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), calibration.c, "$total_time", total_allocated, ""))
        @info "Finished processing detector $det ($ch) in $total_time"

        return (result = calibration, timer = calibration_timer, processed = true, log = log_det)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_det = parallel(chinfo, calibrate_det, log_nt, wpool; timeout, retry = false, process_name = "$period-$run-$(nameof(var"#self#"))")

    @info "Finished DAQ energy calibration"

    pars_db = create_pars(pars_db, result_det)
    writelprops(l200.par.rpars.daqecal[period], run, pars_db)
    writevalidity(l200.par.rpars.daqecal, filekey, (period, run); category = :all)
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_det)]))
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, "# Metadata", create_metadatatbl(filekey))
    lreport!(report, "# Results", create_logtbl(result_det))
    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    # flush stdout
    flush(stdout)
end
