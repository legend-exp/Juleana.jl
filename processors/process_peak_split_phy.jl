function process_peak_split_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)

    @info "Process phy peak splitting for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    raw_config = dataprod_config(l200).raw(filekey)
    @debug "Loaded raw config: $(lstring(raw_config))"
    @debug "Load DAQ calibration pars db for $period-$run"
    pars_db = PropDict(l200.par.rpars.daqecal[period, run])

    if reprocess @info "Reprocess all detectors" end

    # create log line Tuple
    log_peaksplit = NamedTuple{(:Detector, :usability, :Status, :Counts, Symbol("Total Time"), Symbol("Total Allocated"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    # get input and output directories
    input_datadir = l200.tier[:raw, :phy, period, run]
    output_datadir = mkpath(l200.tier[:jlpks, :phy, period, run])
    @assert isdir(input_datadir) && isdir(output_datadir)

    @info "Expecting $(length(chinfo)) detectors each file in \"$input_datadir\"."

    filekeys = filter(!in(bad_filekeys(l200; load_key=:unprocessable)), search_disk(FileKey, input_datadir))
    @info "Found $(length(filekeys)) phy filekeys"

    # split peaks from raw waveforms
    function split_peak_det(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector

        @info "Processing detector $det ($ch)"

        raw_config_det = merge(raw_config.default, get(raw_config, det, PropDict()))
        energy_windows = Dict(label => first(window)..last(window) for (label, window) in pairs(raw_config_det.peaks))

        output_filename = l200.tier[:jlpks, filekey, det]
        counts = Dict{Symbol, Int}()

        if isfile(output_filename) && !reprocess
            @info "Output file \"$output_filename\" already exists, skipping"
            try
                for label in keys(energy_windows)
                    counts[label] = length(read_ldata(ljl_propfunc("$label.daqenergy"), l200, DataTier(:jlpks), filekey, det))
                end
            catch e
                @error "Error reading peaks from $(basename(output_filename)): $(truncate_error(e))"
                @warn "Filename $(basename(output_filename)) seems broken, remove it."
                rm(output_filename)
            end

            if isfile(output_filename)
                log_det = log_peaksplit((det, detector_status(chinfo_det.usability), ProcessStatus(1), join(("$label = $n" for (label, n) in counts), ", "), "0", "0", "Already processed --> skipped."))
                return (processed = false, log = log_det)
            end
        end

        split_timer = TimerOutput()

        @info "Generating output file \"$output_filename\""
        @timeit split_timer "$det" begin
            @timeit split_timer "Load DAQ Calibration" begin
                @debug "Loading saved DAQ calibration for detector $det ($ch)"
                f_calib = ljl_propfunc(pars_db[det].func)
            end
            GC.gc()
            @timeit split_timer "Filter Raw" begin
                minimum_energy = minimum(leftendpoint.(values(energy_windows)))
                maximum_energy = maximum(rightendpoint.(values(energy_windows)))
                @debug "Reading raw data for detector $det ($ch) from $(length(filekeys)) files"
                energy_filter = @pf minimum_energy <= f_calib((daqenergy = $daqenergy,)) <= maximum_energy
                slim_data = read_ldata(l200, DataTier(:raw), filekeys, det; filterby=energy_filter)

                write_files(output_filename; use_cache=false, mode=CreateOrReplace()) do filename
                    lh5open(filename, "w") do output
                        for (label, window) in energy_windows
                            @debug "Filtering $label for detector $det ($ch)"
                            peak_data = slim_data |> filterby(@pf f_calib((daqenergy = $daqenergy,)) in window)
                            output[:jlpks, det, label] = peak_data
                            counts[label] = length(peak_data)
                        end
                    end
                end
                @info "Writing $output_filename"
            end
        end
        GC.gc()

        # create total timer by summing over memory usage and time
        total_time      = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(split_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(split_timer))

        log_det = log_peaksplit((det, detector_status(chinfo_det.usability), ProcessStatus(1), join(("$label = $n" for (label, n) in counts), ", "), "$total_time", total_allocated, ""))

        @info "Finished processing detector $det ($ch) in $total_time"

        return (result = counts, processed = true, log = log_det)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_peaksplit = parallel(chinfo, split_peak_det, log_peaksplit, wpool; timeout=timeout, retry=false, process_name="$period-$run-$(nameof(var"#self#"))")

    @info "Finished peak splitting"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_peaksplit)]))
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, peak_splitting_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_peaksplit))

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    # flush stdout
    flush(stdout)
end
