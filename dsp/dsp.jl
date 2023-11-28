function process_dsp(l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool = false, timeout::Int=3600)
    @info "Process DSP for period $period and run $run"

    filekeys = sort(search_disk(FileKey, l200.tier[:raw, :cal, period, run]), by = x-> x.time)
    filekey = filekeys[1]
    @info "Found filekey $filekey"
    chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable && $usability != :off) 

    sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)
    dsp_meta = l200.metadata.dataprod.config.cal.dsp(sel).default
    dsp_config = create_dsp_config(dsp_meta)
    @debug "Loaded DSP config: $(dsp_config)"

    pars_tau = l200.par[:cal, :decay_time, period, run]
    @debug "Loaded decay times"

    pars_optimization = l200.par[:cal, :optimization, period, run]
    @debug "Loaded optimization parameters"

    @debug "Create DSP folder"
    dsp_folder = l200.tier[:dsp, :cal, period, run]
    if isdir(dsp_folder)
        @debug("DSP folder $dsp_folder already exists")
    else
        mkpath(dsp_folder)
    end

    @debug "Create logs folder"
    log_folder = joinpath(l200.tier[:log, :cal, period, run])
    if isdir(log_folder)
        @debug("Log folder $log_folder already exists")
    else
        mkpath(log_folder)
    end

    if reprocess
        @info "Reprocess all filekeys"
    else
        @info "Only reprocess filekeys that are not processed yet"
    end

    # move all variables to workers
    @everywhere begin
        l200 = $l200
        filekeys = $filekeys
        dsp_config = $dsp_config
        pars_tau = $pars_tau
        pars_optimization = $pars_optimization
        chinfo = $chinfo
        reprocess = $reprocess
    end

    @everywhere function single_file_dsp(idx::Int64)
        dsp_timer = TimerOutput()
        @timeit dsp_timer "Startup" begin
            filename    = l200.tier[:raw, filekeys[idx]]
            outfilename = l200.tier[:dsp, filekeys[idx]]

            @info "Processing file: $(basename(filename))"
            data    = LHDataStore(filename, "r")
            @info "Using output file: $(basename(outfilename))"
            if reprocess && isfile(outfilename)
                @info "Reprocess $(basename(outfilename)), remove old DSP."
                rm(outfilename)
            else
                try 
                    LHDataStore(outfilename, "cw")
                catch e
                    @warn "LoadError: $e"
                    @warn "Filename $(basename(outfilename)) seems broken, remove it."
                    rm(outfilename)
                end
            end
            outdata = LHDataStore(outfilename, "cw")
        end

        @info "Start DSP"
        n_detectors = 0
        @timeit dsp_timer "DSP" begin
            # loop over channels
            for (i, ch_short) in enumerate(chinfo.channel)
                ch_short = chinfo.channel[i]
                ch = format("ch{}", ch_short)
                det = chinfo.detector[i]

                # check if channel can be processed
                if !haskey(pars_tau, det)
                    @warn "No decay time for detector $det, skip channel $ch"
                    continue
                end
                if haskey(outdata, ch) && !reprocess
                    @info "Detector $det ($ch) already processed, skip"
                    continue
                end

                @debug "Processing channel $ch ($det)"
                @timeit dsp_timer "DSP $det" begin
                    # load data from HDF5
                    data_ch = data["$ch/raw"][:]
                    # process channel
                    if !haskey(pars_optimization, det)
                        @warn "No optimization parameters for detector $det, skip channel $ch"
                        continue
                    end
                    if !haskey(pars_optimization[det], :sg_wl)
                        @warn "No AoE window length optimization parameter for detector $det, use default."
                        pars_optimization[det].sg_wl.val = 100.0 # ns
                    end
                    outdata[ch]  = dsp_icpc(data_ch, dsp_config, pars_tau[det].tau.val*u"µs", pars_optimization[det])
                    # free memory
                    GC.gc()
                end
                n_detectors += 1
            end
        end

        @info "Finished processing file: $(basename(filename))"
        close(data)
        close(outdata)

        total_time      = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(dsp_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(dsp_timer))
        log_info = "| $(filekeys[idx]) | $n_detectors | Success | $total_time | $total_allocated | - |"
        return (timer = dsp_timer, log = log_info)
    end

    Base.exit_on_sigint(false)
    result_dsp = @showprogress pmap(eachindex(filekeys), batch_size = 1, on_error=identity) do idx
        try
            t_end = time() + timeout
            task = Threads.@spawn single_file_dsp(idx)
            while !istaskdone(task) && time() <= t_end
                sleep(0.1)
            end
            if !istaskdone(task)
                @debug "Timeout for $(filekeys[idx])"
                try
                    Base.throwto(task, InterruptException())
                catch e
                    throw(ErrorException("Timeout for $(filekeys[idx])"))
                end
                throw(ErrorException("Timeout for $(filekeys[idx])"))
            end
            idx => fetch(task)
        catch e
            if e isa TaskFailedException
                e = e.task.exception
            end
            @debug "Write Error log for $(filekeys[idx])"
            log_info = "| $(filekeys[idx]) | - | Failed | - | - | $e |"
            idx => (timer = TimerOutput(), log = log_info)
        end
    end


    @info "Finished DSP"
    @info "Remove all workers"
    rmprocs(workers()...)

    main_log = """# Main log 

    Time of processing: $(now())

    ## DSP
    This is the log for the dsp. The algorithm iterates through each file and process within each file each detector separate.

    # MetaData
    | Setup | Period | Run | Category |
    |-------|--------|-----|----------|
    | $(filekey.setup) | $(filekey.period) | $(filekey.run) | $(filekey.category) |

    # Results
    | FileKey | Number of Detectors | Status | Total Time | Total Allocated | Error |
    |---------|---------------------|--------|------------|-----------------|-------|
    """
    total_dsp_timer = TimerOutput()
    for (idx, res) in result_dsp
        # merge timer into total timer
        merge!(total_dsp_timer, res.timer)
        # add log to main log
        main_log = """
        $main_log$(res.log)
        """
    end
    # add total timer to main log
    main_log = """
$main_log
# Total Timing
```
$total_dsp_timer
```
    """

    @info "Write main log to disk"
    @info main_log

    log_filename = joinpath(log_folder, format("{}-{}-{}-{}-dsp.md", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
    open(log_filename, "w+") do file
        write(file, replace(main_log, "Success" => raw"$${\color{green}Success}$$", "Failed" => raw"$${\color{red}Failed}$$"))
    end
end