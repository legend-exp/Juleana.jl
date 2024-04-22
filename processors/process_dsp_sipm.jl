function process_dsp_sipm(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool = false, timeout::Union{Int, Bool}=false)
    
    @info "Process SiPM DSP for period $period and run $run"

    if !ispath(l200.tier[:raw, :phy, period, run])
        @warn "No raw data found for period $period and run $run"
        return
    end
    filekeys = search_disk(FileKey, l200.tier[:raw, :phy, period, run])
    
    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found start filekey $filekey"

    chinfo = Table(channelinfo(l200, filekey; system=:spms, only_processable=true))
    @info "Loaded channel info with $(length(chinfo)) channels"

    dsp_meta = dataprod_config(l200).sipm(filekey)
    @debug "Loaded DSP config: $(dsp_meta)"

    pars_sipm = l200.par.rpars.sipm(filekey)
    @debug "Loaded SiPM parameters"

    @debug "Create DSP folder: $(mkpath(l200.tier[:jldsp, :phy, period, run]))"

    if reprocess 
        @info "Reprocess all filekeys and channels"
    else
        @info "Only reprocess filekeys and channels that are not processed yet"
    end

    # create log line Tuple
    log_nt = NamedTuple{(:Filekey, :Status, Symbol("Number of Processed Detectors"), Symbol("Failed Detectors"), Symbol("Total Time"), Symbol("Total Allocated"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    function filekey_dsp(fk::FileKey)
        dsp_timer = TimerOutput()
        @timeit dsp_timer "Startup" begin
            filename    = l200.tier[:raw, fk]
            outfilename = l200.tier[:jldsp, fk]

            @info "Processing file: $(basename(filename))"
            data    = lh5open(filename, "r")
            @info "Using output file: $(basename(outfilename))"
            if reprocess && isfile(outfilename)
                @info "Reprocess $(basename(outfilename))"
            else
                try 
                    lh5open(outfilename, "cw")
                catch e
                    @warn "LoadError: $e"
                    @warn "Filename $(basename(outfilename)) seems broken, remove it."
                    rm(outfilename)
                end
            end
            outdata = lh5open(outfilename, "cw")
        end

        @info "Start DSP"
        n_detectors = 0
        failed_detectors = DetectorId[]
        @timeit dsp_timer "DSP" begin
            # loop over channels
            @showprogress desc="Filekey: $fk" for (ch, det) in zip(chinfo.channel, chinfo.detector)

                # check if channel can be processed
                if !haskey(pars_sipm, det)
                    @warn "No thresholds for detector $det, skip channel $ch"
                    push!(failed_detectors, det)
                    continue
                end
                if haskey(outdata, "$ch") && !reprocess
                    @info "Detector $det ($ch) already processed, skip"
                    n_detectors += 1
                    continue
                end

                @debug "Processing channel $ch ($det)"
                @timeit dsp_timer "DSP $det" begin
                    # load data from HDF5
                    data_ch = data[ch].raw[:]
                    # get metadata
                    dsp_meta_ch = merge(dsp_meta.default, get(dsp_meta, det, PropDict()))
                    # process channel
                    outdata_ch = nothing
                    try
                        outdata_ch = dsp_sipm(data_ch, dsp_meta_ch, pars_sipm[det])
                    catch e
                        if e isa TaskFailedException
                            e = e.task.exception
                        end
                        @error "Error processing channel $ch ($det) in $(fk): $e"
                        push!(failed_detectors, det)
                        continue
                    end
                    # save data to hdf5
                    outdata["$ch"] = outdata_ch
                    # free memory
                    GC.gc()
                    # count number of detectors processed and Successful
                    n_detectors += 1
                end
            end
        end

        @info "Finished processing file: $(basename(filename))"
        close(data)
        close(outdata)

        if n_detectors == 0
            @warn "No detectors processed in $(basename(filename))"
        end

        total_time      = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(dsp_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(dsp_timer))
        
        # create log
        log_fk = log_nt((fk, ProcessStatus(1), "$(n_detectors)/$(length(chinfo))", string.(failed_detectors), total_time, total_allocated, ""))

        return (timer = dsp_timer, log = log_fk, processed = true)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_dsp = parallel(filekeys, filekey_dsp, log_nt, wpool,; timeout=timeout)
    
    @info "Finished DSP for period $period and run $run"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, dsp_cal_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_dsp))
    lreport!(report, "# Total Timing")
    lreport!(report, "```")
    lreport!(report, "$(get_totalTimer(result_dsp))")
    lreport!(report, "```")

    @info "Write log report"
    writelreport(get_reportfilename(l200, filekey, :dsp_sipms), report)
    @info report

    # flush stdout
    flush(stdout)
end
