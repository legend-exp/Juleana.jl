function process_daq_energy_calibration(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)

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
    output_dir = mkpath(joinpath(output_datadir, "daq_energy_calibration"))

    if reprocess @info "Reprocess all filekeys and detectors"
    else @info "Only process failed or missing steps" end

    # get keylists and check files
    disk_filekeys = sort(search_disk(FileKey, l200.tier[:raw, :cal, period, run]))

    # Read the metadata on every invocation; bad_filekeys caches it for a LegendData.
    ignored_metadata = PropDict(l200.metadata.datasets.ignored_daq_cycles)
    ignored_filekeys = Set(FileKey(fk) for list in values(ignored_metadata) for fk in list)
    ignored_run = sort([fk for fk in ignored_filekeys if (fk.setup, fk.period, fk.run, fk.category) == (filekey.setup, period, run, DataCategory(:cal))])
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
    filekeys_filename = joinpath(output_dir, "filekeys.txt")
    previous_filekeys = isfile(filekeys_filename) ? read_filekeys(filekeys_filename) : FileKey[]
    changed_inputs = previous_filekeys != filekeys || any(fk -> get(checked, Symbol(fk), nothing) != file_info[Symbol(fk)], filekeys)

    write_files(check_filename, use_cache = false, mode = CreateOrReplace()) do checkpoint_file
        writelprops(checkpoint_file, PropDict(:detectors => detectors, :files => PropDict(Dict(Symbol(fk) => file_info[Symbol(fk)] for fk in filekeys))))
    end
    for (name, keylist) in (("filekeys.txt", filekeys), ("broken_filekeys.txt", broken_filekeys), ("ignored_filekeys.txt", excluded_metadata))
        write_files(joinpath(output_dir, name); use_cache = false, mode = CreateOrReplace()) do filename
            write_filekeys(filename, keylist)
        end
    end

    # create log report
    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, daq_energy_calibration_log_text)

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

    report_filename = get_rreportfilename(l200, filekey, :daq_energy_calibration)
    no_inputs = isempty(filekeys) || isempty(chinfo)
    if no_inputs
        lreport!(report, "**Preproduction stopped: no usable filekeys or processable detectors.**")
    end

    # load saved calibration parameters
    pars_path = joinpath(data_path(l200, "par"), "rpars", "daqecal")
    pars_filename = joinpath(pars_path, string(period), "$run.yaml")
    pars_db = isfile(pars_filename) ? readlprops(pars_filename) : PropDict()

    if reprocess || changed_inputs || no_inputs
        @info "Clear previous outputs for changed inputs or reprocessing"
        pars_db = PropDict()
        isfile(pars_filename) && rm(pars_filename)
        for row in chinfo
            det = row.detector
            for filename in (joinpath(output_dir, "$det-daqecal.yaml"), joinpath(output_dir, "$det-raw.lh5"), joinpath(output_dir, "$det-cal.lh5"),
                LegendDataManagement.LDMUtils.get_pltfilename(l200, filekey, det, :daq_energy_raw), LegendDataManagement.LDMUtils.get_pltfilename(l200, filekey, det, :daq_energy))
                isfile(filename) && rm(filename)
            end
        end
    end

    # create detector log line Tuple
    log_nt = NamedTuple{(:Detector, :Channel, :Status, :Step, :Action, Symbol("Total Time"), Symbol("Total Allocated"), :Error)}

    function calibrate_det(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector

        @info "Processing detector $det ($ch)"

        raw_config_det = merge(raw_config.default, get(raw_config, det, PropDict()))
        @debug "Loaded raw config for $det ($ch): $(lstring(raw_config_det))"

        raw_histogram_filename = joinpath(output_dir, "$det-raw.lh5")
        cal_histogram_filename = joinpath(output_dir, "$det-cal.lh5")
        calibration_filename = joinpath(output_dir, "$det-daqecal.yaml")
        raw_plot_filename = LegendDataManagement.LDMUtils.get_pltfilename(l200, filekey, det, :daq_energy_raw)
        cal_plot_filename = LegendDataManagement.LDMUtils.get_pltfilename(l200, filekey, det, :daq_energy)

        calibration = get(pars_db, det, PropDict())
        if isfile(calibration_filename)
            calibration = readlprops(calibration_filename)
        end

        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()
        complete = true
        e_raw = nothing
        result_autocal = nothing

        # calibration
        try
            processed_dict[:calibration] = false
            timed = @timed begin
                if !haskey(calibration, :c) || !haskey(calibration, :func)
                    @info "Auto calibrating $det ($ch)"
                    if isnothing(e_raw)
                        e_raw = read_ldata(:daqenergy, l200, :raw, filekeys, det).daqenergy
                    end

                    result_autocal, _ = autocal_energy(e_raw, raw_config_det.th228_cal_lines; mode = :ratio,
                        min_e = raw_config_det.min_e, max_e = raw_config_det.max_e, max_e_binning_quantile = raw_config_det.max_e_binning_quantile,
                        σ = raw_config_det.σ, threshold = raw_config_det.threshold, min_n_peaks = raw_config_det.min_n_peaks,
                        max_n_peaks = raw_config_det.max_n_peaks, α = raw_config_det.α, rtol = raw_config_det.rtol)
                    c = result_autocal.c
                    isfinite(c) && c > 0 || error("Invalid DAQ calibration coefficient $c for $det")
                    calibration = PropDict(:c => c * u"keV", :func => "$(repr(c)) * daqenergy * keV", :mode => "ratio",
                        :source_filekey => string(filekey), :filekeys => string.(filekeys), :valid_from => string(filekey.time))
                    write_files(calibration_filename, use_cache = false, mode = CreateOrReplace()) do filename
                        writelprops(filename, calibration)
                    end
                    processed_dict[:calibration] = true
                else
                    @debug "Calibration for $det ($ch) already processed, skip"
                end
            end
            action = processed_dict[:calibration] ? "Processed" : "Reused"
            log_info_dict[:calibration] = log_nt((det, ch, ProcessStatus(1), :calibration, action, "$(round(timed.time; digits=2)) s", Base.format_bytes(timed.bytes), "-"))

            # calibrated spectrum
            processed_dict[:calibrated_spectrum] = false
            timed = @timed begin
                if !isfile(cal_histogram_filename) || filesize(cal_histogram_filename) == 0
                    histogram = if isnothing(result_autocal)
                        if isnothing(e_raw)
                            e_raw = read_ldata(:daqenergy, l200, :raw, filekeys, det).daqenergy
                        end
                        energies = ustrip.(u"keV", calibration.c .* e_raw)
                        StatsBase.fit(StatsBase.Histogram, energies, 0:0.5:3000)
                    else
                        result_autocal.h_cal
                    end
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
                    Makie.vlines!(ax, ustrip.(u"keV", raw_config_det.th228_cal_lines), color = :red, label = "Th calibration lines")
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
            isfile(raw_plot_filename) && rm(raw_plot_filename)
        catch e
            e isa InterruptException && rethrow()
            complete = false
            failed_step = haskey(log_info_dict, :calibration) ? :calibrated_spectrum : :calibration
            log_info_dict[failed_step] = log_nt((det, ch, ProcessStatus(0), failed_step, "Failed", "-", "-", truncate_error(e)))
            isfile(cal_plot_filename) && rm(cal_plot_filename)
            @error "DAQ calibration or calibrated spectrum failed for $det; plot raw spectrum" exception=(e, catch_backtrace())
            # raw spectrum
            try
                processed_dict[:raw_spectrum] = false
                timed = @timed begin
                    if !isfile(raw_histogram_filename) || filesize(raw_histogram_filename) == 0
                        @debug "Load DAQ energy for $det from $(length(filekeys)) files"
                        if isnothing(e_raw)
                            e_raw = read_ldata(:daqenergy, l200, :raw, filekeys, det).daqenergy
                        end

                        energies = e_raw
                        binwidth = 8 * 15
                        edges = range(0; step = binwidth, length = max(2, floor(Int, maximum(energies) / binwidth) + 2))
                        histogram = StatsBase.fit(StatsBase.Histogram, energies, edges)
                        write_files(raw_histogram_filename; use_cache = false, mode = CreateOrReplace()) do filename
                            lh5open(filename, "w") do output
                                output[:histogram] = histogram
                            end
                        end
                        processed_dict[:raw_spectrum] = true
                    end

                    if !isfile(raw_plot_filename) || filesize(raw_plot_filename) == 0
                        histogram = lh5open(h -> h[:histogram], raw_histogram_filename, "r")
                        binwidth = step(first(histogram.edges))
                        plot_title = "Raw Energy Spectrum"

                        @debug "Plot $plot_title for $det ($ch)"
                        fig = Makie.Figure(size = (650, 400))
                        ax = Makie.Axis(fig[1, 1], xlabel = "Energy (ADC)", ylabel = "Counts / $binwidth ADC", yscale = Makie.log10,
                            limits = (extrema(first(histogram.edges)), (0.9, max(1, maximum(histogram.weights)) * 1.2)), title = get_plottitle(filekey, det, plot_title))
                        Makie.stephist!(ax, StatsBase.midpoints(first(histogram.edges)), weights = replace(histogram.weights, 0 => 1e-10), bins = first(histogram.edges), color = LegendMakie.BEGeOrange, label = "DAQ Energy before QC")
                        Makie.axislegend(ax, position = :rt, framevisible = true, framecolor = :lightgray)
                        LegendMakie.add_watermarks!(final = true)

                        write_files(raw_plot_filename, use_cache = false, mode = CreateOrReplace()) do filename
                            LegendMakie.lsavefig(fig, filename)
                        end
                        processed_dict[:raw_spectrum] = true
                    end
                end
                action = processed_dict[:raw_spectrum] ? "Processed" : "Reused"
                log_info_dict[:raw_spectrum] = log_nt((det, ch, ProcessStatus(1), :raw_spectrum, action, "$(round(timed.time; digits=2)) s", Base.format_bytes(timed.bytes), "-"))
            catch e
                e isa InterruptException && rethrow()
                complete = false
                log_info_dict[:raw_spectrum] = log_nt((det, ch, ProcessStatus(0), :raw_spectrum, "Failed", "-", "-", truncate_error(e)))
                @error "Preproduction raw_spectrum failed for $det" exception=(e, catch_backtrace())
            end
        end

        GC.gc()
        @info "Finished preproduction for detector $det ($ch)"
        return (result = calibration, processed = processed_dict, complete = complete, log = log_info_dict)
    end

    # execute in parallel
    flush(stdout)
    result_det = no_inputs ? [] : parallel(chinfo, calibrate_det, log_nt, wpool; timeout, retry = false, process_name)

    # recover calibrations even if a later operation failed or timed out
    for row in chinfo
        no_inputs && continue
        filename = joinpath(output_dir, "$(row.detector)-daqecal.yaml")
        isfile(filename) && (pars_db[row.detector] = readlprops(filename))
    end
    pars_db = PropDict(Dict(Symbol(det) => pars_db[det] for det in chinfo.detector if haskey(pars_db, det)))
    validity_error = nothing
    try
        mkpath(dirname(pars_filename))
        write_files(pars_filename, use_cache = false, mode = CreateOrReplace()) do filename
            writelprops(filename, pars_db)
        end
        pars_root = LegendDataManagement.AnyProps(pars_path)
        writevalidity(pars_root, filekey, (period, run); category = :all)
        # Fresh PropsDB instances observe the just-written index, including physics selection.
        for category in (:cal, :phy)
            selected = LegendDataManagement.AnyProps(pars_path)(ValiditySelection(filekey.time, DataCategory(category)))
            selected == pars_db || error("DAQ calibration validity check failed for $category at $(filekey.time)")
        end
        lreport!(report, "# Calibration Validity", "Saved parameters to `$pars_filename`, valid from `$(filekey.time)` for category `all`. Verified calibration and physics lookup at that timestamp.")
    catch e
        e isa InterruptException && rethrow()
        validity_error = truncate_error(e)
        lreport!(report, "# Calibration Validity", "**Saving or checking calibration validity FAILED:** $validity_error")
    end

    # collect detector logs, including tasks that failed before returning step logs
    det_log_rows = NamedTuple[]
    for (_, res) in result_det
        append!(det_log_rows, res.log isa AbstractDict ? collect(values(res.log)) : [res.log])
    end
    det_log_columns = fieldnames(log_nt)
    det_log_table = isempty(det_log_rows) ? Table(Status = ["No entries."]) : Table(NamedTuple{det_log_columns}(Tuple([row[name] for row in det_log_rows] for name in det_log_columns)))
    lreport!(report, "# Results by Detector and Step", det_log_table)

    lreport!(report, "Total processing time: $(canonicalize(now() - start_time))")

    @info "Write log report to $report_filename"
    writelreport(report_filename, report)
    flush(stdout)
    isnothing(validity_error) || error("DAQ calibration persistence/validity failed: $validity_error. See $report_filename")
    no_inputs && error("No usable calibration filekeys or detectors for $period-$run; see $report_filename")
    all(pair -> hasproperty(last(pair), :complete) && last(pair).complete, result_det) || error("Some preproduction steps failed; rerun with reprocess=false to retry them. See $report_filename")

    @info "Finished calibration preproduction for $period-$run"

    # flush stdout
    flush(stdout)
end # function
