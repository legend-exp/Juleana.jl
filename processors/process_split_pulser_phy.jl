function process_pulser_filter_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)

    @info "Process pulser event filtering for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    dsp_config = DSPConfig(dataprod_config(l200).dsp(filekey).default)

    puls_ch_name = "PULS01ANA"
    puls_threshold = 1000.0  # e_10410 > 1000  -- TODO: move into processing_config / dataprod config if it should be tunable

    if reprocess @info "Reprocess all detectors" end

    # create log line Tuples
    log_fkcheck = NamedTuple{(:Filekey, :Status, Symbol("Number of Processed Detectors"), Symbol("Failed Detectors"), Symbol("Total Time"), Symbol("Total Allocated"), :Error)}
    log_pulsid  = NamedTuple{(:Filekey, :Status, Symbol("Number of Pulser Events"), Symbol("Total Time"), Symbol("Total Allocated"), :Error)}
    log_pulsraw = NamedTuple{(:Detector, :Channel, :Status, Symbol("Number of Events Extracted"), Symbol("Total Time"), Symbol("Total Allocated"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # get start time
    start_time = now()

    # get input and output directories
    input_datadir = l200.tier[:raw, :phy, period, run]
    output_datadir = mkpath(l200.tier[:jlpuls, :phy, period, run])
    @assert isdir(input_datadir) && isdir(output_datadir)

    # get detectors
    detectors = chinfo.detector

    @info "Expecting $(length(detectors)) detectors + pulser channel \"$puls_ch_name\" each file in \"$input_datadir\"."

    # get keylists and check files (same pattern as process_peak_split)
    keylist_filename = joinpath(output_datadir, "filekeys.txt")
    broken_keylist_filename = joinpath(output_datadir, "broken_filekeys.txt")

    if isfile(keylist_filename) && !reprocess
        filekeys = read_filekeys(keylist_filename)
        files_checked = true
    else
        filekeys = filter(!in(bad_filekeys(l200; load_key=:all)), search_disk(FileKey, l200.tier[:raw, :phy, period, run]))
        files_checked = false
    end
    isempty(filekeys) && error("No files found in \"$input_datadir\"")

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
                    LHDataStore(filename)
                catch e
                    @error "Error while checking file \"$(filename)\": $(e)"
                    is_ok = false
                else
                    LHDataStore(filename) do ds
                        if !haskey(ds, puls_ch_name)
                            @error "Pulser channel $puls_ch_name not found in \"$(filename)\""
                            is_ok = false
                        end
                        for det in detectors
                            @timeit fk_timer "$det" begin
                                try
                                    haskey(ds, "$det") || throw(ErrorException("Detector $det not found in \"$(filename)\""))
                                catch e
                                    @error "Error while checking detector $det in \"$(filename)\": $(e)"
                                    push!(failed_detectors, det)
                                    is_ok = false
                                end
                            end
                        end
                    end
                end
            end
            total_time      = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(fk_timer)))
            total_allocated = Base.format_bytes(TimerOutputs.totallocated(fk_timer))
            log_fk = log_fkcheck((fk, ProcessStatus(1), "$(length(detectors))", string.(failed_detectors), total_time, total_allocated, ""))
            return (result = is_ok, timer = fk_timer, log = log_fk, processed = true)
        end

        result_fkcheck = Dict(parallel(filekeys, check_filekey, log_fkcheck, wpool,; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))"))

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

    # -----------------------------------------------------------------------
    # Step 1+2: run the simplified pulser DSP per file and identify the
    # eventnumbers for which the pulser fired (e_10410 > puls_threshold).
    # Done per-file (not flattened across files) because eventnumber is only
    # unique *within* a file, and we need to re-match it against each
    # detector's raw table per file in the next step.
    # -----------------------------------------------------------------------
    function identify_pulser_events(fk::FileKey)
        id_timer = TimerOutput()
        filename = l200.tier[:raw, fk]
        evtnos = Int[]
        status = 1
        err = ""
        @timeit id_timer "$fk" begin
            try
                LHDataStore(filename) do ds
                    puls_raw = ds[puls_ch_name].raw[:]
                    dsp_out = dsp_puls_compressed(puls_raw, dsp_config)
                    mask = dsp_out.e_10410 .> puls_threshold
                    append!(evtnos, dsp_out.eventID_fadc[mask])
                end
            catch e
                @error "Error while identifying pulser events in \"$(filename)\": $(e)"
                status = 0
                err = "$e"
            end
        end
        total_time      = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(id_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(id_timer))
        log_id = log_pulsid((fk, ProcessStatus(status), "$(length(evtnos))", total_time, total_allocated, err))
        @info "Found $(length(evtnos)) pulser events in $fk"
        return (result = evtnos, processed = true, log = log_id)
    end

    result_pulsid = Dict(parallel(filekeys, identify_pulser_events, log_pulsid, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))-pulsid"))

    puls_evtnos = Dict(fk => Set(result_pulsid[fk].result) for fk in filekeys)

    # -----------------------------------------------------------------------
    # Step 3: for every Ge channel, keep only the raw rows whose eventnumber
    # is in the pulser event set of that file, and write ONE output raw file
    # per channel spanning all filekeys of the period/run (mirrors
    # split_peak_det's per-detector loop in process_peak_split).
    # -----------------------------------------------------------------------
    function extract_pulser_det(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector

        @info "Extracting pulser events for detector $det ($ch)"

        output_filename = l200.tier[:jlpuls, first(filekeys), det]

        if isfile(output_filename) && !reprocess
            @info "Output file \"$output_filename\" already exists, skipping"
            n_evts = nothing
            try
                output = lh5open(output_filename, "r")
                n_evts = length(output[det].raw.eventnumber)
                close(output)
            catch e
                @error "Error reading extracted events from $(basename(output_filename)): $(truncate_error(e))"
                @warn "Filename $(basename(output_filename)) seems broken, remove it."
                rm(output_filename)
            end
            if isfile(output_filename) && !isnothing(n_evts)
                log_det = log_pulsraw((det, ch, ProcessStatus(1), "$n_evts", "0", "0", ""))
                return (processed = false, log = log_det)
            end
        end

        extract_timer = TimerOutput()

        @info "Generating output file \"$output_filename\""
        local slim_data
        @timeit extract_timer "$det" begin
            @timeit extract_timer "Filter Raw" begin
                per_file_tables = [
                    LHDataStore(l200.tier[:raw, fk]) do ds
                        @debug "Filtering $(l200.tier[:raw, fk]) for detector $det ($ch)"
                        raw_tbl = ds[det].raw[:]
                        mask = in.(raw_tbl.eventnumber, Ref(puls_evtnos[fk]))
                        raw_tbl[mask]
                    end
                    for fk in filekeys
                ]
                slim_data = fast_flatten(per_file_tables)
            end
        end

        n_evts = length(slim_data.eventnumber)

        @info "Writing $output_filename"
        @timeit extract_timer "Write Data" begin
            write_files(output_filename, use_cache = false, mode = CreateOrReplace()) do outfile
                lh5open(outfile, "w") do output
                    output[det, :raw] = slim_data
                end
            end
        end

        total_time      = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(extract_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(extract_timer))

        log_det = log_pulsraw((det, ch, ProcessStatus(1), "$n_evts", total_time, total_allocated, ""))

        @info "Finished extracting pulser events for detector $det ($ch): $n_evts events in $total_time"

        return (result = (n_evts = n_evts,), processed = true, log = log_det)
    end

    result_pulsextract = parallel(chinfo, extract_pulser_det, log_pulsraw, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished pulser event extraction"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(first(filekeys)))
    lreport!(report, "# Results")
    if !isnothing(result_fkcheck)
        lreport!(report, "## Results Filekey Check")
        lreport!(report, create_logtbl(result_fkcheck))
    end
    lreport!(report, "## Results Pulser Identification")
    lreport!(report, create_logtbl(result_pulsid))
    lreport!(report, "## Results Pulser Raw Extraction")
    lreport!(report, create_logtbl(result_pulsextract))

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    flush(stdout)
end