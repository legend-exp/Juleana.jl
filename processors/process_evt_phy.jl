function process_evt_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool = false, timeout::Int=0)
    
    @info "Process events for period $period and run $run"

    filekeys = search_disk(FileKey, l200.tier[:jldsp, :phy, period, run])
    
    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found start filekey $filekey"

    if reprocess @info "Reprocess all filekeys"
    else @info "Only reprocess filekeys that are not processed yet" end

    # create log line Tuple
    log_nt = NamedTuple{(:Filekey, :Status, Symbol("Number of Physical Trigger"), Symbol("Number of Forced Trigger"), Symbol("Number of Pulser Trigger"), Symbol("Total Time"), Symbol("Total Allocated"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    function filekey_evt(fk::FileKey)
        dsp_timer = TimerOutput()
        dspfilename = l200.tier[:jldsp, fk]
        @info "Processing file: $(basename(dspfilename))"
        evtfilename = l200.tier[:jlevt, fk]
        @info "Using output file: $(basename(evtfilename))"
        
        # start processing
        read_files(dspfilename, use_cache = false) do filename
            global n_forced, n_pulser, n_phy = 0, 0, 0
            write_files(evtfilename, use_cache = true, mode = CreateOrModify()) do outfilename
                if reprocess && isfile(outfilename)
                    @info "Reprocess $(basename(outfilename)), remove old DSP."
                    rm(outfilename, force=true)
                elseif isfile(outfilename)
                    @info "File $(basename(outfilename)) already exists, skip"
                    n_forced, n_pulser, n_phy = lh5open(outfilename, "r") do evt_data
                        n_forced = count(evt_data.aux.forcedtrigger.aux_trig)
                        n_pulser = count(evt_data.aux.pulser.aux_trig)
                        n_phy = count(evt_data.geds.is_valid_qc .&& length.(evt_data.geds.trig_e_ch) .> 1)
                        n_forced, n_pulser, n_phy
                    end
                    return (timer = dsp_timer, log = log_nt((fk, ProcessStatus(1), n_phy, n_pulser, n_forced, "", "", "")), processed = false)
                end

                # open output file
                @timeit dsp_timer "Evt" begin
                    n_forced, n_pulser, n_phy = lh5open(filename, "r") do dsp_data
                        # generate evt level table
                        out_t = nothing
                        try 
                            out_t = Table(calibrate_all(l200, fk, dsp_data))
                        catch e
                            @error "Error processing $fk: $(truncate_string(string(e)))"
                            throw(ErrorException("Error processing $fk: $(truncate_string(string(e)))"))
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
                        n_forced, n_pulser, n_phy
                    end
                end
                
                @info "Finished processing $(basename(outfilename))"
            end
        end

        # create total timer by summing over memory usage and time
        total_time      = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(dsp_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(dsp_timer))
        
        # create log
        log_fk = log_nt((fk, ProcessStatus(1), n_phy, n_pulser, n_forced, total_time, total_allocated, ""))

        return (timer = dsp_timer, log = log_fk, processed = true)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_evt = parallel(filekeys, filekey_evt, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")
    
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
    lreport!(report, "# Total Timing")
    lreport!(report, "```")
    lreport!(report, "$(get_totalTimer(result_evt))")
    lreport!(report, "```")

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, :evt), report)
    @info report

    # flush stdout
    flush(stdout)
end
