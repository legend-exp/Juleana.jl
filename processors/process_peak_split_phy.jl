function process_peak_split_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)

    @info "Process physics preproduction for period $period and run $run"
    start_time = now()

    filekey = start_filekey(l200, (period, run, :phy))
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
    output_datadir = mkpath(l200.tier[:jlpks, :phy, period, run])
    output_dir = mkpath(joinpath(output_datadir, "peak_split_phy"))

    if reprocess @info "Reprocess all filekeys and detectors"
    else @info "Only process failed or missing steps" end

    # get keylists and check files
    disk_filekeys = sort(search_disk(FileKey, l200.tier[:raw, :phy, period, run]))

    # Read the metadata on every invocation; bad_filekeys caches it for a LegendData.
    ignored_metadata = PropDict(l200.metadata.datasets.ignored_daq_cycles)
    ignored_filekeys = Set(FileKey(fk) for list in values(ignored_metadata) for fk in list)
    ignored_run = sort([fk for fk in ignored_filekeys if (fk.setup, fk.period, fk.run, fk.category) == (filekey.setup, period, run, DataCategory(:phy))])
    excluded_metadata = intersect(disk_filekeys, ignored_run)
    candidates = setdiff(disk_filekeys, ignored_run)

    # reuse checks for unchanged raw files
    detectors = sort(string.(chinfo.detector))
    check_filename = joinpath(output_dir, "filekey_checks.yaml")
    check_state = isfile(check_filename) && !reprocess ? readlprops(check_filename) : PropDict()
    checked = get(check_state, :detectors, nothing) == detectors ? get(check_state, :files, PropDict()) : PropDict()

    file_info = PropDict()
    for fk in candidates
        info = stat(l200.tier[:raw, fk])
        file_info[Symbol(fk)] = PropDict(:size => info.size, :mtime => info.mtime)
    end

    # create log line Tuple
    log_fkcheck = NamedTuple{(:Filekey, :Status, :Action, Symbol("Failed Detectors"), :Error)}

    function check_filekey(fk::FileKey)

        if get(checked, Symbol(fk), nothing) == file_info[Symbol(fk)]
            @debug "Filekey $fk already checked, skip"
            return (result = true, processed = false, log = log_fkcheck((fk, ProcessStatus(1), "Reused", "-", "-")))
        end
        @debug "Checking file $(l200.tier[:raw, fk])"

        failed_detectors, detector_errors = DetectorId[], String[]
        for det in chinfo.detector
            try
                energies = read_ldata(:daqenergy, l200, :raw, fk, det).daqenergy
                isempty(energies) && error("Empty DAQ energy for $det")
                all(isfinite, energies) || error("Nonfinite DAQ energy for $det")
                lh5open(l200.tier[:raw, fk], "r") do input
                    length(input[:raw, det, :waveform_presummed]) == length(energies) || error("Waveform/DAQ energy row count mismatch for $det")
                end
            catch e
                e isa InterruptException && rethrow()
                @error "Exclude $fk: checking detector $det failed: $(truncate_error(e))"
                push!(failed_detectors, det)
                push!(detector_errors, "$det: $(truncate_error(e))")
            end
        end
        good = isempty(failed_detectors)
        return (result = good, processed = true, log = log_fkcheck((fk, ProcessStatus(Int(good)), good ? "Accepted" : "EXCLUDED", join(string.(failed_detectors), ", "), join(detector_errors, "; "))))
    end

    @info "Check raw filekeys against ignore metadata"
    flush(stdout)
    result_fkcheck = Dict(parallel(candidates, check_filekey, log_fkcheck, wpool; timeout, retry = false, process_name))
    filekeys = [fk for fk in candidates if hasproperty(result_fkcheck[fk], :result) && result_fkcheck[fk].result]
    broken_filekeys = setdiff(candidates, filekeys)
    filekeys_filename = joinpath(output_datadir, "filekeys.txt")
    previous_filekeys = isfile(filekeys_filename) ? read_filekeys(filekeys_filename) : FileKey[]
    changed_inputs = previous_filekeys != filekeys || any(fk -> get(checked, Symbol(fk), nothing) != file_info[Symbol(fk)], filekeys)

    write_files(check_filename, use_cache = false, mode = CreateOrReplace()) do checkpoint_file
        writelprops(checkpoint_file, PropDict(:detectors => detectors, :files => PropDict(Dict(Symbol(fk) => file_info[Symbol(fk)] for fk in filekeys))))
    end
    for (name, keylist) in (("filekeys.txt", filekeys), ("broken_filekeys.txt", broken_filekeys), ("ignored_filekeys.txt", excluded_metadata))
        write_files(joinpath(output_datadir, name); use_cache = false, mode = CreateOrReplace()) do filename
            write_filekeys(filename, keylist)
        end
    end

    # create log report
    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, peak_split_phy_log_text)

    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))

    lreport!(report, "# Filekey Crosscheck")
    lreport!(report, "Found $(length(disk_filekeys)) filekeys on disk; $(length(filekeys)) accepted; $(length(excluded_metadata)) excluded by metadata; $(length(broken_filekeys)) failed validation.")

    lreport!(report, "## Excluded by Ignore Metadata")
    lreport!(report, isempty(excluded_metadata) ? "None." : join(("- `$fk`" for fk in excluded_metadata), "\n"))

    lreport!(report, "## Unexpected Failures — Excluded Filekeys")
    lreport!(report, isempty(broken_filekeys) ? "No discrepancies: all filekeys outside the ignore metadata passed validation." : "**The following filekeys failed validation but are absent from the ignore metadata. They have been EXCLUDED from every preproduction step.**\n\n" * join(("- **`$fk` — EXCLUDED**" for fk in broken_filekeys), "\n"))

    lreport!(report, "## Ignore Metadata Entries Absent from Disk")
    absent_metadata = setdiff(ignored_run, disk_filekeys)
    lreport!(report, isempty(absent_metadata) ? "None." : join(("- `$fk`" for fk in absent_metadata), "\n"))

    fk_log_rows = [res.log for (_, res) in result_fkcheck]
    fk_log_columns = fieldnames(log_fkcheck)
    fk_log_table = isempty(fk_log_rows) ? Table(Status = ["No entries."]) : Table(NamedTuple{fk_log_columns}(Tuple([row[name] for row in fk_log_rows] for name in fk_log_columns)))
    lreport!(report, "## Validation Results", fk_log_table)

    report_filename = get_rreportfilename(l200, filekey, :peak_split_phy)
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
    lreport!(report, "# Calibration Validity", "Selected saved DAQ calibration separately for every physics filekey. Missing or invalid calibration blocks that detector's calibrated steps.",
        isempty(validity_rows) ? Table(Status = ["No entries."]) : Table(NamedTuple{keys(first(validity_rows))}(Tuple([row[name] for row in validity_rows] for name in keys(first(validity_rows))))))

    # discard outputs derived from changed raw inputs or saved calibrations
    for row in chinfo
        det = row.detector
        calibration_filename = joinpath(output_dir, "$det-daqecal.yaml")
        previous_calibrations = isfile(calibration_filename) ? readlprops(calibration_filename) : PropDict()
        if reprocess || changed_inputs || no_inputs || !isempty(calibration_errors[det]) || previous_calibrations != calibrations[det]
            @debug "Clear calibrated outputs for $det ($(row.channel))"
            for filename in (calibration_filename, joinpath(output_dir, "$det-cal.lh5"), l200.tier[:jlpks, filekey, det],
                LegendDataManagement.LDMUtils.get_pltfilename(l200, filekey, det, :daq_energy))
                isfile(filename) && rm(filename)
            end
        end
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
        cal_histogram_filename = joinpath(output_dir, "$det-cal.lh5")
        calibration_filename = joinpath(output_dir, "$det-daqecal.yaml")
        cal_plot_filename = LegendDataManagement.LDMUtils.get_pltfilename(l200, filekey, det, :daq_energy)
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

        # calibrated spectrum
        try
            processed_dict[:calibrated_spectrum] = false
            timed = @timed begin
                if !isfile(cal_histogram_filename) || filesize(cal_histogram_filename) == 0
                    energies = map(filekeys) do fk
                        f_calib = ljl_propfunc(records[Symbol(fk)].func)
                        raw_energy = read_ldata(:daqenergy, l200, :raw, fk, det).daqenergy
                        [ustrip(u"keV", f_calib((daqenergy=e,))) for e in raw_energy]
                    end
                    histogram = StatsBase.fit(StatsBase.Histogram, LegendDataTypes.fast_flatten(energies), 0:0.5:3000)
                    write_files(cal_histogram_filename; use_cache = false, mode = CreateOrReplace()) do filename
                        lh5open(filename, "w") do output
                            output[:histogram] = histogram
                        end
                    end
                    processed_dict[:calibrated_spectrum] = true
                end

                if !isfile(cal_plot_filename) || filesize(cal_plot_filename) == 0
                    histogram = lh5open(h -> h[:histogram], cal_histogram_filename, "r")
                    binwidth = step(first(histogram.edges))
                    plot_title = "Calibrated DAQ Online Energy"

                    @debug "Plot $plot_title for $det ($ch)"
                    fig = Makie.Figure(size = (650, 400))
                    ax = Makie.Axis(fig[1, 1], xlabel = "Energy (keV)", ylabel = "Counts / $binwidth keV", yscale = Makie.log10,
                        limits = (extrema(first(histogram.edges)), (0.9, max(1, maximum(histogram.weights)) * 1.2)), title = get_plottitle(filekey, det, plot_title))
                    Makie.stephist!(ax, StatsBase.midpoints(first(histogram.edges)), weights = replace(histogram.weights, 0 => 1e-10), bins = first(histogram.edges), color = LegendMakie.BEGeOrange, label = "DAQ Energy before QC")
                    for (label, window) in energy_windows
                        low, high = ustrip(u"keV", leftendpoint(window)), ustrip(u"keV", rightendpoint(window))
                        Makie.vspan!(ax, low, high, color = (LegendMakie.BEGeOrange, 0.2), label = string(label))
                    end
                    Makie.vlines!(ax, ustrip.(u"keV", raw_config_det.gamma_lines), color = :red, label = "K40 / K42 gamma lines")
                    Makie.axislegend(ax, position = :rt, framevisible = true, framecolor = :lightgray)
                    LegendMakie.add_watermarks!(final = true)

                    write_files(cal_plot_filename, use_cache = false, mode = CreateOrReplace()) do filename
                        LegendMakie.lsavefig(fig, filename)
                    end
                    processed_dict[:calibrated_spectrum] = true
                end
            end
            action = processed_dict[:calibrated_spectrum] ? "Processed" : "Reused"
            log_info_dict[:calibrated_spectrum] = log_nt((det, ch, ProcessStatus(1), :calibrated_spectrum, action, "$(round(timed.time; digits=2)) s", Base.format_bytes(timed.bytes), "-"))
        catch e
            e isa InterruptException && rethrow()
            complete = false
            log_info_dict[:calibrated_spectrum] = log_nt((det, ch, ProcessStatus(0), :calibrated_spectrum, "Failed", "-", "-", truncate_error(e)))
            @error "Preproduction calibrated_spectrum failed for $det" exception=(e, catch_backtrace())
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
    no_inputs && error("No usable physics filekeys or detectors for $period-$run; see $report_filename")
    all(pair -> hasproperty(last(pair), :complete) && last(pair).complete, result_det) || error("Some preproduction steps failed; rerun with reprocess=false to retry them. See $report_filename")

    @info "Finished physics preproduction for $period-$run"

    # flush stdout
    flush(stdout)
end # function
