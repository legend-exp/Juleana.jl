"""
    process_peak_split(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Extract the events in the Th-228 peaks from the raw `cal` data of the HPGe detectors (`geds`) of a run.

First, each raw `cal` file is checked by reading the `daqenergy` of every detector; the files
that can be read are listed in `filekeys.txt` and the others in `broken_filekeys.txt` in the
`jlpks` directory of the run. An existing `filekeys.txt` is reused unless `reprocess` is `true`.
Then, for each detector, the DAQ energy of all good files is calibrated automatically with the
Th-228 lines (`th228_cal_lines`), and the events inside the energy windows given by `peaks`
(for example `Tl208FEP` and `Tl208SEP`) are written with their raw waveforms. The processor
throws an error if no file is found.

# Inputs
- `raw` tier of all `cal` filekeys of the run, except the filekeys marked bad
- `dataprod_config(l200).raw(filekey)`, sections `default` and per detector

# Outputs
- `jlpks` tier file for each detector, with one table per entry of `peaks`
- `filekeys.txt` and `broken_filekeys.txt` in the `jlpks` directory of the run
- plots `:daq_energy_raw` and `:daq_energy` for each detector
- run report `:peak_split`, with the file check (if it ran) and one row per detector (numbers of FEP and SEP events, time, allocations)

# Keywords
- `reprocess`: check all files again and recreate the `jlpks` files; otherwise a detector with a readable `jlpks` file is skipped (an unreadable file is removed and recreated)
- `timeout`: seconds allowed per item in `parallel` (0 = no limit); an item is a filekey in the file check and a detector in the peak splitting

# Returns
Return `nothing`.
"""
function process_peak_split(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool=false, timeout::Real=0)

    @info "Process peak splitting for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    raw_config = dataprod_config(l200).raw(filekey)

    if reprocess @info "Reprocess all detectors" end

    # create log line Tuple
    log_fkcheck = NamedTuple{(:Filekey, :Status, Symbol("Number of Processed Detectors"), Symbol("Failed Detectors"), Symbol("Total Time"), Symbol("Total Allocated"), :Error)}
    log_peaksplit = NamedTuple{(:Detector, :usability, :Status, Symbol("Number of FEP Events"), Symbol("Number of SEP Events"), Symbol("Total Time"), Symbol("Total Allocated"), :Error)}

    # get worker pool

    # get start time
    start_time = now()

    # get input and output directories
    input_datadir = l200.tier[:raw, :cal, period, run]
    output_datadir = mkpath(l200.tier[:jlpks, :cal, period, run])
    @assert isdir(input_datadir) && isdir(output_datadir)

    # get detectors
    detectors = chinfo.detector

    @info "Expecting $(length(detectors)) detectors each file in \"$input_datadir\"."

    # get keylists and check files
    keylist_filename = joinpath(output_datadir, "filekeys.txt")
    broken_keylist_filename = joinpath(output_datadir, "broken_filekeys.txt")

    if isfile(keylist_filename) && !reprocess
        filekeys = read_filekeys(keylist_filename)
        files_checked = true
    else
        filekeys = filter(!in(bad_filekeys(l200; load_key=:all)), search_disk(FileKey, l200.tier[:raw, :cal, period, run]))
        files_checked = false
    end
    isempty(filekeys) && error("No files found in \"$input_datadir\"")

    # check for broken filekeys
    result_fkcheck = nothing
    @info "Check files for broken filekeys."
    if !files_checked
        @info "Checking files in \"$input_datadir\"."
        function check_filekey(fk::FileKey)
            fk_timer = TimerOutput()
            filename = l200.tier[:raw, fk]
            @info "Checking file \"$filename\""
            is_ok::Bool = true
            failed_detectors = DetectorId[]
            @timeit fk_timer "$fk" begin
                try
                    for det in detectors
                        @timeit fk_timer "$det" begin
                            try
                                read_ldata(:daqenergy, l200, DataTier(:raw), fk, det)
                            catch e
                                @error "Error while checking detector $det in \"$(filename)\": $(e)"
                                push!(failed_detectors, det)
                                is_ok = false
                            end
                        end
                    end
                catch e
                    @error "Error while checking file \"$(filename)\": $(e)"
                    is_ok = false
                end
            end

            # create total timer by summing over memory usage and time
            total_time      = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(fk_timer)))
            total_allocated = Base.format_bytes(TimerOutputs.totallocated(fk_timer))

            # create log
            log_fk = log_fkcheck((fk, ProcessStatus(is_ok), "$(length(detectors))", string.(failed_detectors), total_time, total_allocated, ""))
            return (result = is_ok, timer = fk_timer, log = log_fk, processed = true)
        end

        result_fkcheck = Dict(parallel(check_filekey, filekeys, log_fkcheck; timeout=timeout, retry=false, process_name="$period-$run-process_peak_split"))

        if !all(v -> hasproperty(v, :result), values(result_fkcheck))
            error("Some filekeys failed during checking due to unknown reason.")
        end

        good_filekeys = [fk for fk in keys(result_fkcheck) if result_fkcheck[fk].result]
        write_filekeys(keylist_filename, good_filekeys)

        broken_filekeys = [fk for fk in keys(result_fkcheck) if !(result_fkcheck[fk].result)]
        if !isempty(broken_filekeys)
            @error "Detected broken files for filekeys" broken_filekeys
            write_filekeys(broken_keylist_filename, broken_filekeys)
        end

        filekeys = good_filekeys
    else
        @info "Files already checked, use filelist from \"$keylist_filename\" instead."
    end


    # split peaks from raw waveforms
    function split_peak_det(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector

        @info "Processing detector $det ($ch)"

        raw_config_det = merge(raw_config.default, get(raw_config, det, PropDict()))

        energy_windows = IdDict(keys(raw_config_det.peaks) .=> [first(v)..last(v) for v in values(raw_config_det.peaks)])

        output_filename = l200.tier[:jlpks, first(filekeys), det]

        if isfile(output_filename) && !reprocess
            @info "Output file \"$output_filename\" already exists, skipping"
            n_sep, n_fep = nothing, nothing
            try
                n_sep = length(read_ldata((@pf $Tl208SEP.daqenergy), l200, DataTier(:jlpks), first(filekeys), det))
                n_fep = length(read_ldata((@pf $Tl208FEP.daqenergy), l200, DataTier(:jlpks), first(filekeys), det))
            catch e
                @error "Error reading SEP and FEP events from $(basename(output_filename)): $(truncate_error(e))"
                @warn "Filename $(basename(output_filename)) seems broken, remove it."
                rm(output_filename)
            end
            if isfile(output_filename) && !isnothing(n_sep) && !isnothing(n_fep)
                log_det = log_peaksplit((det, detector_status(chinfo_det.usability), ProcessStatus(1), n_fep, n_sep, "0", "0", ""))
                return (processed = false, log = log_det)
            end
        end

        split_timer = TimerOutput()

        @info "Generating output file \"$output_filename\""
        @timeit split_timer "$det" begin
            # get raw daqenergy
            @timeit split_timer "Get DAQ Energy" begin
                @debug "Reading DAQ energy for detector $det from $(length(filekeys)) files"
                e_raw = read_ldata(:daqenergy, l200, DataTier(:raw), filekeys, det).daqenergy
                begin
                    fig = Makie.Figure(size = (620, 400))
                    binwidth = 8 * 15
                    hall = StatsBase.fit(StatsBase.Histogram, e_raw, range(0, maximum(e_raw), step = binwidth))
                    ax = Makie.Axis(fig[1,1], xlabel = "Energy (ADC)", ylabel = "Counts / $(binwidth) ADC", xtickformat = x -> string.(round.(Int,x)), yscale = log10, limits = (extrema(first(hall.edges)), (0.9, maximum(hall.weights) * 1.2)), title = get_plottitle(filekey, det, "Raw Energy Spectrum"))
                    Makie.stephist!(ax, StatsBase.midpoints(first(hall.edges)), weights = replace(hall.weights, 0 => 1e-10), bins = first(hall.edges), color = LegendMakie.BEGeOrange, label = "DAQ Energy before QC")
                    Makie.axislegend(ax, position = :rt, framevisible = true, framecolor = :lightgray)
                    LegendMakie.add_watermarks!(final = true)
                    savelfig(LegendMakie.lsavefig, fig, l200, filekey, det, Symbol("daq_energy_raw"))
                end
                @info "Auto calibrating $det ($ch)"
                result_autocal, report_autocal = autocal_energy(e_raw, raw_config_det.th228_cal_lines; mode=:ratio, min_e=raw_config_det.min_e, max_e=raw_config_det.max_e, max_e_binning_quantile=raw_config_det.max_e_binning_quantile, σ=raw_config_det.σ, threshold=raw_config_det.threshold, min_n_peaks=raw_config_det.min_n_peaks, max_n_peaks=raw_config_det.max_n_peaks, α=raw_config_det.α, rtol=raw_config_det.rtol)
                f_calib = result_autocal.f_calib
                p = LegendMakie.lplot(report_autocal, raw_config_det.th228_cal_lines, figsize = (650,400), title = get_plottitle(first(filekeys), det, "Calibrated DAQ Online Energy"))
                savelfig(LegendMakie.lsavefig, p, l200, first(filekeys), det, Symbol("daq_energy"))
            end
            GC.gc()
            @timeit split_timer "Filter Raw" begin
                minimum_energy = minimum(leftendpoint.(values(energy_windows)))
                maximum_energy = maximum(rightendpoint.(values(energy_windows)))
                energy_filter = @pf minimum_energy <= f_calib($daqenergy) <= maximum_energy
                slim_data = read_ldata(l200, DataTier(:raw), filekeys, det; filterby=energy_filter)
                write_files(output_filename, use_cache = false, mode = CreateOrReplace()) do outfile
                    lh5open(outfile, "w") do output
                        for (label, window) in energy_windows
                            @debug "Filtering $label for detector $det ($ch)"
                            output[:jlpks, det, label] = slim_data |> filterby(@pf f_calib($daqenergy) ∈ window)
                        end
                    end
                end            
                @info "Writing $output_filename"
            end
            n_sep = length(read_ldata((@pf $Tl208SEP.daqenergy), l200, DataTier(:jlpks), first(filekeys), det))
            n_fep = length(read_ldata((@pf $Tl208FEP.daqenergy), l200, DataTier(:jlpks), first(filekeys), det))

        end

        # create total timer by summing over memory usage and time
        total_time      = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(split_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(split_timer))

        log_det = log_peaksplit((det, detector_status(chinfo_det.usability), ProcessStatus(1), n_fep, n_sep, "$total_time", total_allocated, ""))

        @info "Finished processing detector $det ($ch) in $total_time"

        return (result = (n_fep = n_fep, n_sep = n_sep), processed = true, log = log_det)
    end

    # execute in parallel
    result_peaksplit = parallel(split_peak_det, chinfo, log_peaksplit; timeout=timeout, retry=false, process_name="$period-$run-process_peak_split")

    @info "Finished peak splitting"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_fkcheck, result_peaksplit)]))
    lreport!(report, "Date of processing: $(utc_timestamp())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, peak_splitting_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(first(filekeys)))
    lreport!(report, "# Results")
    if !isnothing(result_fkcheck)
        lreport!(report, "## Results Filekey Check")
        lreport!(report, create_logtbl(result_fkcheck))
        lreport!(report, "## Results Peak Splitting")
    end
    lreport!(report, create_logtbl(result_peaksplit))

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, :peak_split), report)
    @info report

    # flush stdout
    flush(stdout)
end # function

register_processor!(process_peak_split)
