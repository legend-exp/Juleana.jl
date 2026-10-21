function process_daq_energy_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool = false, timeout::Int = 0)

    @info "Plot calibrated DAQ energy for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :geds, only_processable = true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    @debug "Load DAQ calibration pars db for $period-$run"
    pars_db = PropDict(l200.par.rpars.daqecal[period, run])

    filekeys = filter(!in(bad_filekeys(l200; load_key=:unprocessable)), search_disk(FileKey, l200.tier[:raw, :phy, period, run]))
    @info "Found $(length(filekeys)) physics filekeys"

    if reprocess @info "Reprocess all detectors" end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Status, :Counts, Symbol("Total Time"), Symbol("Total Allocated"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    function plot_daq_energy_det(chinfo_det::NamedTuple)
        ch  = chinfo_det.channel
        det = chinfo_det.detector

        @info "Processing detector $det ($ch)"

        output_filename = LegendDataManagement.LDMUtils.get_pltfilename(l200, filekey, det, :daq_energy)
        if isfile(output_filename) && !reprocess
            @info "Output file \"$output_filename\" already exists, skipping"
            log_det = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), "-", "0", "0", "Already processed --> skipped."))
            return (processed = false, log = log_det)
        end

        spectrum_timer = TimerOutput()
        bins = 0:0.5:3000

        @timeit spectrum_timer "$det" begin
            @timeit spectrum_timer "Load DAQ Calibration" begin
                @debug "Loading saved DAQ calibration for detector $det ($ch)"
                f_calib = ljl_propfunc(pars_db[det].func)
            end
            @timeit spectrum_timer "Get Calibrated DAQ Energy" begin
                @debug "Reading DAQ energy for detector $det from $(length(filekeys)) files"
                data = read_ldata(:daqenergy, l200, DataTier(:raw), filekeys, det)
                e_cal = ustrip.(u"keV", f_calib.(data))
                h_cal = fit(Histogram, e_cal, bins)
                n_events = length(e_cal)
            end

            @timeit spectrum_timer "Plot DAQ Energy" begin
                p = LegendMakie.lplot(h_cal; figsize = (650, 400), xlabel = "Energy (keV)", ylabel = "Counts / 0.5 keV",
                    yscale = Makie.log10, ylims = (0.9, max(1, maximum(h_cal.weights)) * 1.2), xticks = 0:250:3000,
                    label = "DAQ Energy before QC", title = get_plottitle(filekey, det, "Calibrated DAQ Online Energy"))
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, :daq_energy)
            end
        end
        GC.gc()

        total_time = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(spectrum_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(spectrum_timer))
        log_det = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), n_events, "$total_time", total_allocated, ""))
        @info "Finished processing detector $det ($ch) in $total_time"

        return (timer = spectrum_timer, processed = true, log = log_det)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_daq = parallel(chinfo, plot_daq_energy_det, log_nt, wpool; timeout, retry = false, process_name = "$period-$run-$(nameof(var"#self#"))")

    @info "Finished DAQ energy plot generation"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_daq)]))
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, "# Metadata", create_metadatatbl(filekey))
    lreport!(report, "# Results", StructArray([res.log for (_, res) in result_daq]))

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    # flush stdout
    flush(stdout)
end
