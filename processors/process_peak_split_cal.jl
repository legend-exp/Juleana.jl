function process_peak_split_cal(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)

    @info "Process calibration preproduction for period $period and run $run"
    start_time = now()

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :geds, only_processable = true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    raw_config = dataprod_config(l200).raw(filekey)
    @debug "Loaded raw config: $(lstring(raw_config))"

    process = nameof(var"#self#")

    # get worker pool
    wpool = get_workerPool(processing_config, process)
    process_name = "$period-$run-$process"

    # get output directories
    output_datadir = mkpath(l200.tier[:jlpks, :cal, period, run])
    output_dir = mkpath(joinpath(output_datadir, "peak_split_cal"))

    if reprocess @info "Reprocess all filekeys and detectors"
    else @info "Only process failed or missing steps" end

    # Reuse the calibration stage's accepted inputs without reading raw files again.
    calibration_dir = joinpath(output_datadir, "daq_energy_calibration")
    filekeys = read_filekeys(joinpath(calibration_dir, "filekeys.txt"))
    input_state = readlprops(joinpath(calibration_dir, "filekey_checks.yaml"))
    get(input_state, :detectors, nothing) == sort(string.(chinfo.detector)) || error("Detector selection changed; rerun process_daq_energy_calibration first")

    check_filename = joinpath(output_dir, "filekey_checks.yaml")
    previous_state = isfile(check_filename) ? readlprops(check_filename) : PropDict()
    filekeys_filename = joinpath(output_datadir, "filekeys.txt")
    previous_filekeys = isfile(filekeys_filename) ? read_filekeys(filekeys_filename) : FileKey[]
    changed_inputs = previous_state != input_state || previous_filekeys != filekeys

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, peak_split_cal_log_text)
    lreport!(report, "# Metadata", create_metadatatbl(filekey))
    lreport!(report, "# Calibration Inputs", "Reused $(length(filekeys)) accepted filekeys from `$calibration_dir/filekeys.txt`. File validation is performed by `process_daq_energy_calibration`.")

    report_filename = get_rreportfilename(l200, filekey, :peak_split_cal)
    no_inputs = isempty(filekeys) || isempty(chinfo)
    if no_inputs
        lreport!(report, "**Preproduction stopped: no usable filekeys or processable detectors.**")
    end

    # Fresh validity selections also detect calibration updates on a resumed run.
    calibrations = Dict{DetectorId, PropDict}()
    calibration_errors = Dict{DetectorId, String}()
    validity_rows = NamedTuple[]
    for row in chinfo
        records, errors = PropDict(), String[]
        pars_root = nothing
        for fk in filekeys
            try
                isnothing(pars_root) && (pars_root = LegendDataManagement.AnyProps(joinpath(data_path(l200, "par"), "rpars", "daqecal")))
                record = pars_root(fk)[row.detector]
                Timestamp(record.valid_from) <= Timestamp(fk) || error("Calibration begins after $fk")
                isfinite(ustrip(u"keV", record.c)) && record.c > 0u"keV" || error("Invalid DAQ calibration coefficient")
                ljl_propfunc(record.func)
                records[Symbol(fk)] = record
                push!(validity_rows, (Filekey = fk, Detector = row.detector, Status = ProcessStatus(1), Source = record.source_filekey, ValidFrom = record.valid_from, Error = "-"))
            catch e
                e isa InterruptException && rethrow()
                message = "$fk: $(truncate_error(e))"
                push!(errors, message)
                push!(validity_rows, (Filekey = fk, Detector = row.detector, Status = ProcessStatus(0), Source = "-", ValidFrom = "-", Error = message))
            end
        end
        calibrations[row.detector] = records
        calibration_errors[row.detector] = join(errors, "; ")
    end
    lreport!(report, "# Calibration Validity", "Selected saved DAQ calibration separately for every calibration filekey. Missing or invalid calibration blocks that detector's calibrated steps.",
        isempty(validity_rows) ? Table(Status = ["No entries."]) : Table(NamedTuple{keys(first(validity_rows))}(Tuple([row[name] for row in validity_rows] for name in keys(first(validity_rows))))))

    # discard outputs derived from changed raw inputs or saved calibrations
    for row in chinfo
        det = row.detector
        calibration_filename = joinpath(output_dir, "$det-daqecal.yaml")
        previous_calibrations = isfile(calibration_filename) ? readlprops(calibration_filename) : PropDict()
        if reprocess || changed_inputs || no_inputs || !isempty(calibration_errors[det]) || previous_calibrations != calibrations[det]
            @debug "Clear calibrated outputs for $det ($(row.channel))"
            for filename in (calibration_filename, l200.tier[:jlpks, filekey, det])
                isfile(filename) && rm(filename)
            end
        end
    end

    write_files(check_filename; use_cache = false, mode = CreateOrReplace()) do filename
        writelprops(filename, input_state)
    end
    write_files(filekeys_filename; use_cache = false, mode = CreateOrReplace()) do filename
        write_filekeys(filename, filekeys)
    end

    # create detector log line Tuple
    log_nt = NamedTuple{(:Detector, :Channel, :Status, :Step, :Action, Symbol("Total Time"), Symbol("Total Allocated"), :Error)}

    function split_peak_det(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector

        @info "Processing detector $det ($ch)"

        raw_config_det = merge(raw_config.default, get(raw_config, det, PropDict()))
        @debug "Loaded raw config for $det ($ch): $(lstring(raw_config_det))"

        energy_windows = Dict(label => first(window)..last(window) for (label, window) in pairs(raw_config_det.peaks))
        calibration_filename = joinpath(output_dir, "$det-daqecal.yaml")
        output_filename = l200.tier[:jlpks, filekey, det]

        records = calibrations[det]

        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()
        counts = PropDict()
        complete = true

        # load calibration
        try
            @debug "Use saved calibration by filekey validity for $det ($ch)"
            isempty(calibration_errors[det]) || error(calibration_errors[det])
            processed_dict[:calibration] = !isfile(calibration_filename)
            if processed_dict[:calibration]
                write_files(calibration_filename, use_cache = false, mode = CreateOrReplace()) do filename
                    writelprops(filename, records)
                end
            end
            action = processed_dict[:calibration] ? "Processed" : "Reused"
            log_info_dict[:calibration] = log_nt((det, ch, ProcessStatus(1), :calibration, action, "0", "0", "-"))
        catch e
            e isa InterruptException && rethrow()
            log_info_dict[:calibration] = log_nt((det, ch, ProcessStatus(0), :calibration, "Failed", "-", "-", truncate_error(e)))
            @error "Loading DAQ calibration failed for $det" exception=(e, catch_backtrace())
            return (processed = processed_dict, complete = false, counts = counts, log = log_info_dict)
        end

        # peak split
        try
            processed_dict[:peak_split] = false
            timed = @timed begin
                if !isfile(output_filename) || filesize(output_filename) == 0
                    @debug "Filter peak waveforms for $det ($ch)"
                    minimum_energy = minimum(leftendpoint.(values(energy_windows)))
                    maximum_energy = maximum(rightendpoint.(values(energy_windows)))
                    # Filter before waveform loading, using the valid function for each DAQ cycle.
                    slim_data = map(filekeys) do fk
                        f_calib = ljl_propfunc(records[Symbol(fk)].func)
                        energy_filter = @pf minimum_energy <= f_calib((daqenergy=$daqenergy,)) <= maximum_energy
                        read_ldata(l200, :raw, fk, det; filterby = energy_filter)
                    end
                    counts = PropDict()
                    write_files(output_filename; use_cache = false, mode = CreateOrReplace()) do filename
                        lh5open(filename, "w") do output
                            for (label, window) in energy_windows
                                @debug "Filtering $label for detector $det ($ch)"
                                chunks = map(filekeys, slim_data) do fk, data
                                    f_calib = ljl_propfunc(records[Symbol(fk)].func)
                                    filterby(@pf f_calib((daqenergy=$daqenergy,)) in window)(data)
                                end
                                peak_data = LegendDataTypes.fast_flatten(chunks)
                                output[:jlpks, det, label] = peak_data
                                counts[label] = length(peak_data)
                            end
                        end
                    end
                    processed_dict[:peak_split] = true
                else
                    @debug "Peak split for $det ($ch) already processed, skip"
                    for label in keys(energy_windows)
                        counts[label] = length(read_ldata(ljl_propfunc("$label.daqenergy"), l200, :jlpks, filekey, det))
                    end
                end
            end
            action = processed_dict[:peak_split] ? "Processed" : "Reused"
            log_info_dict[:peak_split] = log_nt((det, ch, ProcessStatus(1), :peak_split, action, "$(round(timed.time; digits=2)) s", Base.format_bytes(timed.bytes), "-"))
        catch e
            e isa InterruptException && rethrow()
            complete = false
            log_info_dict[:peak_split] = log_nt((det, ch, ProcessStatus(0), :peak_split, "Failed", "-", "-", truncate_error(e)))
            @error "Preproduction peak_split failed for $det" exception=(e, catch_backtrace())
        end

        GC.gc()
        @info "Finished preproduction for detector $det ($ch)"
        return (processed = processed_dict, complete = complete, counts = counts, log = log_info_dict)
    end

    # execute in parallel
    flush(stdout)
    result_det = no_inputs ? [] : parallel(chinfo, split_peak_det, log_nt, wpool; timeout, retry = false, process_name)

    # collect detector logs, including tasks that failed before returning step logs
    det_log_rows = NamedTuple[]
    for (_, res) in result_det
        append!(det_log_rows, res.log isa AbstractDict ? collect(values(res.log)) : [res.log])
    end
    det_log_columns = fieldnames(log_nt)
    det_log_table = isempty(det_log_rows) ? Table(Status = ["No entries."]) : Table(NamedTuple{det_log_columns}(Tuple([row[name] for row in det_log_rows] for name in det_log_columns)))
    lreport!(report, "# Results by Detector and Step", det_log_table)

    for (row, res) in result_det
        hasproperty(res, :counts) || continue
        lreport!(report, "$(row.detector) peak counts: " * join(("$label = $count" for (label, count) in pairs(res.counts)), ", "))
    end

    lreport!(report, "Total processing time: $(canonicalize(now() - start_time))")

    @info "Write log report to $report_filename"
    writelreport(report_filename, report)
    flush(stdout)
    no_inputs && error("No usable calibration filekeys or detectors for $period-$run; see $report_filename")
    all(pair -> hasproperty(last(pair), :complete) && last(pair).complete, result_det) || error("Some preproduction steps failed; rerun with reprocess=false to retry them. See $report_filename")

    @info "Finished calibration preproduction for $period-$run"

    # flush stdout
    flush(stdout)
end # function
