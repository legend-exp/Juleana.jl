function process_dsp_cal(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool = false, timeout::Int=0, max_wvfs::Int=10000, use_partition_filter::Bool=true)
    
    @info "Process DSP for period $period and run $run"

    filekeys = search_disk(FileKey, l200.tier[:raw, :cal, period, run])
    
    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found start filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) channels"

    dsp_config_pd = dataprod_config(l200).dsp(filekey)
    @debug "Loaded DSP config: $(dsp_config_pd)"

    f_evaluate_qc = h5open(get_mltrainfilename(l200, filekey)) do train_data
            get_qc_ml_func(Array(train_data["ml_train/dsp/dwt_norm"]), Array(train_data["ml_train/dsp/dc_label"]), l200.par.rpars.ml(filekey))
        end
    @info "Loaded trained SVM model"

    pars_type = ifelse(use_partition_filter, :ppars, :rpars)
    @info "Use $(ifelse(use_partition_filter, "partition", "run"))-based pars from $pars_type for DSP optimization parameters"
    
    pars_tau = get_values(l200.par[pars_type, :pz](filekey))
    @debug "Loaded decay times"

    pars_fltoptimization = get_values(merge(l200.par[pars_type, :fltopt](filekey), l200.par[pars_type, :aoeopt](filekey)))
    @debug "Loaded optimization parameters"

    @debug "Check if all HPGe detectors have optimization parameters"
    for chinfo_det in chinfo
        ch = chinfo_det.channel
        det = chinfo_det.detector
        # prevent DSP from failing if run doesnt appear in any partition by using pars from partition of closest run
        if use_partition_filter && !haskey(pars_tau, det) && !haskey(pars_fltoptimization, det) && chinfo_det.processable != :on && isempty(partitioninfo(l200, ch, period, run))
            @warn "Detector $det ($ch) doesn't have pars and optimization parameters since $period/$run is not in any `DataPartition` for channel"
            parts = partitioninfo(l200, det, period)
            closest_runs_distance = Real[]
            for p in parts
                pinfo = filter(row -> row.period == period, partitioninfo(l200, det, p))
                closest_run = pinfo.run[argmin([abs(r.no - run.no) for r in pinfo.run])]
                push!(closest_runs_distance, abs(closest_run.no - run.no))
            end
            part = parts[argmin(closest_runs_distance)]
            try
                merge!(pars_tau, get_values(l200.par.ppars.pz[det, part]))
            catch e
                @warn "No decay time for detector $det, skip channel $ch"
                continue
            end
            try
                merge!(pars_fltoptimization, get_values(l200.par.ppars.fltopt[det, part]))
            catch e
                @warn "No flt optimization parameters for detector $det, skip channel $ch"
                continue
            end
            try
                merge!(pars_fltoptimization, get_values(l200.par.ppars.aoeopt[det, part]))
            catch e
                @warn "No aoe flt optimization parameters for detector $det, skip channel $ch"
                continue
            end
        end
    end

    if reprocess @info "Reprocess all filekeys and channels"
    else @info "Only reprocess filekeys and channels that are not processed yet" end

    # create log line Tuple
    log_nt = NamedTuple{(:Filekey, :Status, Symbol("Number of Processed Detectors"), Symbol("Failed Detectors"), Symbol("Total Time"), Symbol("Total Allocated"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    function filekey_dsp(fk::FileKey)
        dsp_timer = TimerOutput()
        # raw and dsp filename
        rawfilename = l200.tier[:raw, fk]
        @info "Processing file: $(basename(rawfilename))"
        dspfilename = l200.tier[:jldsp, fk]
        @info "Using output file: $(basename(dspfilename))"
        # number of processed detectors
        n_detectors = 0
        # channel ids of failed detectors
        failed_detectors = DetectorId[]
        # start processing
        read_files(rawfilename, use_cache = false) do filename
            write_files(dspfilename, use_cache = true, mode = CreateOrModify()) do outfilename
                @timeit dsp_timer "Startup" begin
                    raw_data = lh5open(filename, "r")
                    if reprocess && isfile(dspfilename)
                        @info "Reprocess $(basename(dspfilename)), remove old DSP."
                        rm(outfilename, force=true)
                    end
                end

                # open output file
                outdata = lh5open(outfilename, "cw")
                # get processed channels
                processed_channels = keys(outdata)

                @info "Start DSP"
                @timeit dsp_timer "DSP" begin
                    # loop over channels
                    @showprogress desc="Filekey: $fk" output=stdout for chinfo_det in chinfo
                        
                        ch = chinfo_det.channel
                        det = chinfo_det.detector

                        dsp_config_pd_det = merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict()))
                        dsp_config_det = DSPConfig(dsp_config_pd_det)
                        @debug "Loaded DSP config: $(dsp_config_det)"

                        # check if channel can be processed
                        if "$det" in processed_channels && !reprocess
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

                        # check if channel has all required flt opt pars
                        if !all(haskey.(Ref(pars_fltoptimization[det]), Symbol.(dsp_config_pd_det.required_fltopt)))
                            @warn "Not all required energy filter optimization parameters available for detector $det, skip"
                            push!(failed_detectors, det)
                            continue
                        end

                        # check if channel has all required aoe opt pars
                        if chinfo_det.usability == :on && chinfo_det.low_aoe_status in [:valid, :present] && !all(haskey.(Ref(pars_fltoptimization[det]), Symbol.(dsp_config_pd_det.required_aoeopt)))
                            @warn "Not all required A/E optimization parameters available for detector $det, skip"
                            push!(failed_detectors, det)
                            continue
                        end

                        @debug "Processing detector $det ($ch)"
                        @timeit dsp_timer "DSP $det" begin
                            # process data
                            outdata_det = nothing
                            try
                                outdata_det = dsp_icpc_compressed(raw_data[det].raw[:], dsp_config_det, pars_tau[det].τ, pars_fltoptimization[det]; f_evaluate_qc=f_evaluate_qc)
                            catch e
                                if e isa TaskFailedException
                                    e = e.task.exception
                                end
                                @error "Error processing detector $det ($ch) in $(fk): $(truncate_error(e))"
                                push!(failed_detectors, det)
                                continue
                            end
                            # save data to hdf5
                            outdata[det, :jldsp] = outdata_det
                            # free memory
                            GC.gc()
                            # count number of detectors processed and Successful
                            n_detectors += 1
                            # flush streams
                            flush(stdout)
                            flush(stderr)
                        end
                    end
                    # close outdata file
                    close(outdata)
                end
                @info "Finished processing file: $(basename(rawfilename))"
                close(raw_data)
                # return number of processed detectors and failed detectors
            end
        end
        if n_detectors == 0
            @warn "No detectors processed in $(basename(rawfilename))"
        end

        # create total timer by summing over memory usage and time
        total_time      = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(dsp_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(dsp_timer))
        
        # create log
        log_fk = log_nt((fk, ProcessStatus(ifelse(isempty(failed_detectors), 1, 0)), "$(n_detectors)/$(length(chinfo))", string.(failed_detectors), total_time, total_allocated, ""))

        return (timer = dsp_timer, log = log_fk, processed = true)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_dsp = parallel(filekeys, filekey_dsp, log_nt, wpool,; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")
    
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
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    # flush stdout
    flush(stdout)
end
