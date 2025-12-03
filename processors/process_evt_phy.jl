function process_evt_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool = false, timeout::Int=0)
    
    @info "Process events for period $period and run $run"

    # Get filekeys and filter out bad ones from ignored_daq_cycles.yaml
    all_filekeys = search_disk(FileKey, l200.tier[:jldsp, :phy, period, run])
    filekeys = filter(!in(bad_filekeys(l200)), all_filekeys)
    n_filtered = length(all_filekeys) - length(filekeys)
    @info "Found $(length(all_filekeys)) filekeys" * (n_filtered > 0 ? ", filtered out $n_filtered bad filekeys" : "")
    
    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found start filekey $filekey"

    if reprocess @info "Reprocess all filekeys"
    else @info "Only reprocess filekeys that are not processed yet" end

    # create log line Tuple
    log_nt = NamedTuple{(:Filekey, :Status, Symbol("Number of Physical Trigger"), Symbol("Number of Forced Trigger"), Symbol("Number of Pulser Trigger"), Symbol("Total Time"), Symbol("Total Allocated"), :Error)}

    # Collect calibration issues across all filekeys
    all_missing_ecal = Set{String}()
    all_missing_sipmcal = Set{String}()
    all_missing_pmtcal = Set{String}()

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    function filekey_evt(fk::FileKey)
        dsp_timer = TimerOutput()
        dspfilename = l200.tier[:jldsp, fk]
        @info "Processing file: $(basename(dspfilename))"
        evtfilename = l200.tier[:jlevt, fk]
        pmtevtfilename = l200.tier[:jlpmt, fk]
        @info "Using output file: $(basename(evtfilename))"
        # number of forced, pulser and physical triggers
        n_forced, n_pulser, n_phy = 0, 0, 0
        calibration_issues = nothing
        
        # Skip if file exists and we're not reprocessing - check BEFORE entering closures
        if !reprocess && isfile(evtfilename)
            @info "File $(basename(evtfilename)) already exists, skip"
            try
                n_forced, n_pulser, n_phy = lh5open(evtfilename, "r") do ds
                    evt_data = ds[:jlevt][:]
                    n_f = count(evt_data.aux.forcedtrigger.aux_trig)
                    n_pul = count(evt_data.aux.pulser.aux_trig)
                    n_p = count(evt_data.geds.is_valid_qc .&& length.(evt_data.geds.trig_e_ch) .> 1)
                    n_f, n_pul, n_p
                end
                log_fk = log_nt((fk, ProcessStatus(1), n_phy, n_forced, n_pulser, "", "", ""))
                return (timer = dsp_timer, log = log_fk, processed = false, calibration_issues = nothing)
            catch e
                @warn "Could not read existing file $(basename(evtfilename)), will reprocess: $(truncate_error(e))"
            end
        end
        
        # Clean up output files before processing if reprocess is enabled
        # This handles cases where previous runs partially wrote files
        if reprocess
            rm(pmtevtfilename, force=true)
            rm(evtfilename, force=true)
            @debug "Cleaned up existing output files for reprocessing"
        end
        
        # start processing
        read_files(dspfilename, use_cache = false) do filename
            write_files(evtfilename, use_cache = true, mode = CreateOrModify()) do outfilename

                # open output file
                @timeit dsp_timer "Evt" begin
                    n_forced, n_pulser, n_phy, calibration_issues = lh5open(filename, "r") do dsp_data
                        # Debug: log available channels in DSP data
                        available_keys = collect(keys(dsp_data))
                        @debug "DSP data contains $(length(available_keys)) channels"
                        
                        # generate evt level table
                        out_t, pmts_out_t, cal_issues = nothing, nothing, nothing
                        try 
                            out_t, pmts_out_t, cal_issues = calibrate_all(l200, fk, dsp_data)
                        catch e
                            # Enhanced error logging
                            @error "Error processing $fk: $(truncate_error(e))"
                            if isa(e, KeyError)
                                @error "KeyError - Missing key: $(e.key). Check if channel exists in DSP data."
                            end
                            throw(ErrorException("Error processing $fk: $(truncate_error(e))"))
                        end
                        
                        # get number of forced, physical and pulser triggers
                        n_forced = count(out_t.aux.forcedtrigger.aux_trig)
                        @debug "Number of forced triggers: $n_forced"
                        n_pulser = count(out_t.aux.pulser.aux_trig)
                        @debug "Number of pulser triggers: $n_pulser"
                        n_phy = count(out_t.geds.is_valid_qc .&& length.(out_t.geds.trig_e_ch) .> 1)
                        @debug "Number of physical triggers: $n_phy"
                        lh5open(outfilename, "cw") do ds
                            ds[:jlevt] = out_t
                        end
                        # write pmt evt file - always remove first to avoid "object already exists" errors
                        if !isempty(pmts_out_t)
                            # Ensure PMT file is clean before writing
                            rm(pmtevtfilename, force=true)
                            write_files(pmtevtfilename, use_cache = true, mode = CreateOrReplace()) do pmtoutfilename
                                lh5open(pmtoutfilename, "cw") do ds
                                    ds[:jlpmt] = pmts_out_t
                                end
                            end
                        end
                        n_forced, n_pulser, n_phy, cal_issues
                    end
                end
                
                @info "Finished processing $(basename(evtfilename))"
            end
        end

        # create total timer by summing over memory usage and time
        total_time      = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(dsp_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(dsp_timer))
        
        # create log
        log_fk = log_nt((fk, ProcessStatus(1), n_phy, n_pulser, n_forced, total_time, total_allocated, ""))

        return (timer = dsp_timer, log = log_fk, processed = true, calibration_issues = calibration_issues)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_evt = parallel(filekeys, filekey_evt, log_nt, wpool; timeout=timeout, retry=true, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")
    
    # Collect calibration issues from all processed filekeys
    # result_evt is an array of Pair{FileKey, NamedTuple}
    for (fk, res) in result_evt
        if hasproperty(res, :calibration_issues) && res.calibration_issues !== nothing
            union!(all_missing_ecal, res.calibration_issues.missing_ecal)
            union!(all_missing_sipmcal, res.calibration_issues.missing_sipmcal)
            union!(all_missing_pmtcal, res.calibration_issues.missing_pmtcal)
        end
    end
    
    @info "Finished Evt for period $period and run $run"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, evt_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_evt))
    
    # Add calibration issues section if any detectors have missing parameters
    if !isempty(all_missing_ecal) || !isempty(all_missing_sipmcal) || !isempty(all_missing_pmtcal)
        lreport!(report, "# Calibration Issues")
        lreport!(report, "The following detectors have missing calibration parameters and were stored with NaN fallback values:")
        lreport!(report, "")
        if !isempty(all_missing_ecal)
            lreport!(report, "## HPGe - Missing ecal ($(length(all_missing_ecal)) detectors)")
            lreport!(report, join(sort(collect(all_missing_ecal)), ", "))
            lreport!(report, "")
        end
        if !isempty(all_missing_sipmcal)
            lreport!(report, "## SiPM - Missing sipmcal ($(length(all_missing_sipmcal)) detectors)")
            lreport!(report, join(sort(collect(all_missing_sipmcal)), ", "))
            lreport!(report, "")
        end
        if !isempty(all_missing_pmtcal)
            lreport!(report, "## PMT - Missing pmtcal ($(length(all_missing_pmtcal)) detectors)")
            lreport!(report, join(sort(collect(all_missing_pmtcal)), ", "))
            lreport!(report, "")
        end
    end
    
    # Add PMT calibration source info
    lreport!(report, "# Calibration Info")
    try
        pmtcal_validity_file = joinpath(data_path(l200.par.rpars.pmtcal), "validity.yaml")
        if isfile(pmtcal_validity_file)
            pmtcal_validity = YAML.load_file(pmtcal_validity_file)
            fk_timestamp = string(filekey.time)
            pmtcal_source = nothing
            for v in pmtcal_validity
                if v["valid_from"] <= fk_timestamp
                    pmtcal_source = v
                end
            end
            if pmtcal_source !== nothing
                apply_path = pmtcal_source["apply"][1]
                parts = split(replace(apply_path, ".yaml" => ""), "/")
                pmtcal_period, pmtcal_run = parts[1], parts[2]
                if pmtcal_period != string(period) || pmtcal_run != string(run)
                    lreport!(report, "**Warning - PMT calibration**: Using parameters from **$(pmtcal_period)/$(pmtcal_run)** (valid_from: $(pmtcal_source["valid_from"]))")
                else
                    lreport!(report, "PMT calibration: Using parameters from $(pmtcal_period)/$(pmtcal_run)")
                end
            end
        end
    catch e
        @warn "Could not determine pmtcal source: $e"
    end
    lreport!(report, "")
    
    lreport!(report, "# Total Timing")
    lreport!(report, "```")
    lreport!(report, "$(get_totalTimer(result_evt))")
    lreport!(report, "```")

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    # flush stdout
    flush(stdout)
end
