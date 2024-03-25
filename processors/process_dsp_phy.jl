function process_dsp_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool = false, timeout::Int=3600, max_wvfs::Int=10000)
    
    @info "Process DSP for period $period and run $run"

    if !ispath(l200.tier[:raw, :phy, period, run])
        @warn "No raw data found for period $period and run $run"
        return
    end
    filekeys = search_disk(FileKey, l200.tier[:raw, :phy, period, run])
    
    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found start filekey $filekey"

    chinfo = Table(channelinfo(l200, filekey; system=:geds, only_processable=true))
    @info "Loaded channel info with $(length(chinfo)) channels"

    dsp_config = DSPConfig(dataprod_config(l200).dsp(filekey).default)
    dsp_meta = dataprod_config(l200).dsp(filekey).default
    @debug "Loaded DSP config: $(dsp_config)"

    train_data = h5open(get_mltrainfilename(l200, filekey))
    f_evaluate_qc = get_qc_ml_func(Array(train_data["ml_train/dsp/dwt_norm"]), Array(train_data["ml_train/dsp/dc_label"]), l200.par.rpars.ml(filekey))
    close(train_data)
    @info "Loaded trained SVM model"

    pars_tau = get_values(l200.par.rpars.pz[period, run])
    @debug "Loaded decay times"

    pars_fltoptimization = get_values(merge(l200.par.rpars.fltopt[period, run], l200.par.rpars.aoeopt[period, run]))
    @debug "Loaded optimization parameters"

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

    # move all variables to workers
    @everywhere begin
        l200 = $l200
        filekeys = $filekeys
        filekey = $filekey
        dsp_config = $dsp_config
        dsp_meta = $dsp_meta
        pars_tau = $pars_tau
        pars_fltoptimization = $pars_fltoptimization
        chinfo = $chinfo
        reprocess = $reprocess
        max_wvfs = $max_wvfs
        log_nt = $log_nt
        f_evaluate_qc = $f_evaluate_qc
    end

    @everywhere function filekey_dsp(fk::FileKey)
        dsp_timer = TimerOutput()
        @timeit dsp_timer "Startup" begin
            filename    = l200.tier[:raw, fk]
            outfilename = l200.tier[:jldsp, fk]

            @info "Processing file: $(basename(filename))"
            data    = lh5open(filename, "r")
            @info "Using output file: $(basename(outfilename))"
            if reprocess && isfile(outfilename)
                @info "Reprocess $(basename(outfilename)), remove old DSP."
                rm(outfilename)
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
            if haskey(dsp_meta, :additional_channel)
                # process additional channels
                for det in DetectorId.(keys(dsp_meta.additional_channel))
                    ch = channelinfo(l200, filekey, det).channel

                    # check if channel can be processed
                    if haskey(outdata, "$ch") && !reprocess
                        @info "Detector $det ($ch) already processed, skip"
                        n_detectors += 1
                        continue
                    end

                    @debug "Processing channel $ch ($det)"
                    @timeit dsp_timer "DSP $det" begin
                        # process data
                        outdata_ch = nothing
                        try
                            outdata_ch = fast_flatten([getfield(Main, Symbol(dsp_meta.additional_channel[Symbol(det)]))(data_part, dsp_config)
                                    for data_part in Iterators.partition(data[ch].raw[:], max_wvfs)])
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

            # loop over channels
            @showprogress desc="Filekey: $fk" for (ch, det) in zip(chinfo.channel, chinfo.detector)

                # check if channel can be processed
                if haskey(outdata, "$ch") && !reprocess
                    @info "Detector $det ($ch) already processed, skip"
                    n_detectors += 1
                    continue
                end
                # check for decay time
                if !haskey(pars_tau, det)
                    @warn "No decay time for detector $det, skip channel $ch"
                    push!(failed_detectors, det)
                    continue
                end
                # check if channel has values for RT and FT for different filters
                if !haskey(pars_fltoptimization, det)
                    @warn "No optimization parameters for detector $det, skip channel $ch"
                    push!(failed_detectors, det)
                    continue
                end

                @debug "Processing channel $ch ($det)"
                error_dets = ""
                @timeit dsp_timer "DSP $det" begin
                    # process data
                    outdata_ch = nothing
                    try
                        outdata_ch = fast_flatten([dsp_icpc(data_part, dsp_config, pars_tau[det].tau, pars_fltoptimization[det]; f_evaluate_qc=f_evaluate_qc)
                                for data_part in Iterators.partition(data[ch].raw[:], max_wvfs)])
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

        # create total timer by summing over memory usage and time
        total_time      = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(dsp_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(dsp_timer))
        
        # create log
        log_fk = log_nt((fk, ProcessStatus(1), "$(n_detectors)/$(length(chinfo)+length(dsp_meta.additional_channel))", string.(failed_detectors), total_time, total_allocated, ""))

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
    writelreport(get_logfilename(l200, filekey, :dsp), report)
    @info report
end
