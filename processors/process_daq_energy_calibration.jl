function process_daq_energy_calibration(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool = false, timeout::Int = 0)
    
    @info "Process DAQ energy calibration for period $period and run $run"
    start_time = now()

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :geds, only_processable = true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    raw_config = dataprod_config(l200).raw(filekey)
    @debug "Loaded raw config: $(lstring(raw_config))"
    filekeys = filter(!in(bad_filekeys(l200; load_key = :unprocessable)), search_disk(FileKey, l200.tier[:raw, :cal, period, run]))
    @info "Found $(length(filekeys)) calibration filekeys"

    pars_root = LegendDataManagement.AnyProps(mkpath(joinpath(data_path(l200, "par"), "rpars", "daqecal")))
    @debug "Create pars db"
    mkpath(joinpath(data_path(pars_root), string(period)))
    pars_filename = joinpath(data_path(pars_root), string(period), "$run.yaml")
    pars_db = PropDict(pars_root[period, run])
    pars_db = ifelse(reprocess, PropDict(), pars_db)

    if reprocess @info "Reprocess all detectors" end

    log_nt = NamedTuple{(:Detector, :Channel, :Status, Symbol("Total Time"), Symbol("Total Allocated"), :Error)}
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    flush(stdout)

    function calibrate_det(chinfo_det::NamedTuple)
        ch  = chinfo_det.channel
        det = chinfo_det.detector

        @info "Processing detector $det ($ch)"

        if haskey(pars_db, det)
            @debug "Detector $(det) already processed, check missing DAQ energy"
            @debug "DAQ energy already processed, skip"
            return (processed = false, log = log_nt((det, ch, ProcessStatus(1), "0", "0", "Already processed --> skipped.")))
        end

        config = merge(raw_config.default, get(raw_config, det, PropDict()))
        calibration, failure = nothing, ""

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

                calibration = (c = result.c * u"keV", func = "$(repr(result.c)) * daqenergy * keV")
            catch e
                failure = truncate_error(e)
                @error "DAQ calibration or calibrated plot failed for $det; plot raw energy" exception = (e, catch_backtrace())

                # If calibration or its plot fails, save a marked raw spectrum in the same folder.
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
            end
        end

        total_time = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(calibration_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(calibration_timer))
        log_det = log_nt((det, ch, ProcessStatus(!isnothing(calibration)), "$total_time", total_allocated, failure))
        @info "Finished processing detector $det ($ch) in $total_time"

        isnothing(calibration) && return (timer = calibration_timer, processed = true, log = log_det)
        return (result = calibration, timer = calibration_timer, processed = true, log = log_det)
    end

    result_det = parallel(chinfo, calibrate_det, log_nt, wpool; timeout, retry = false, process_name = "$period-$run-process_daq_energy_calibration")

    pars_db = create_pars(pars_db, result_det)
    mkpath(dirname(pars_filename))
    write_files(pars_filename; use_cache = false, mode = CreateOrReplace()) do filename
        writelprops(filename, pars_db)
    end
    writevalidity(pars_root, filekey, (period, run); category = :all)

    report = lreport()
    lreport!(report, "# DAQ Energy Calibration", "Date of processing: $(now())", "Total processing time: $(canonicalize(now() - start_time))")
    lreport!(report, "# Metadata", create_metadatatbl(filekey))
    lreport!(report, "# Results", StructArray([res.log for (_, res) in result_det]))
    writelreport(get_rreportfilename(l200, filekey, :daq_energy_calibration), report)
    flush(stdout)
end
