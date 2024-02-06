function process_dsp_cal(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool = false, timeout::Int=3600, max_wvfs::Int=10000)
    @info "Process DSP for period $period and run $run"

    filekeys = search_disk(FileKey, l200.tier[:raw, :cal, period, run])
    
    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found start filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) channels"

    dsp_config = create_dsp_config(dataprod_config(l200).dsp(filekey).default)
    @debug "Loaded DSP config: $(dsp_config)"

    pars_tau = l200.par.rpars.pz[period, run]
    @debug "Loaded decay times"

    pars_optimization = l200.par.rpars.fltopt[period, run]
    @debug "Loaded optimization parameters"

    mkpath(l200.tier[:jldsp, :cal, period, run])
    @debug "Created DSP folder"

    if reprocess
        @info "Reprocess all filekeys"
    else
        @info "Only reprocess filekeys that are not processed yet"
    end

    # create workers
    create_workers(processing_config, :dsp_cal)

    # move all variables to workers
    @everywhere begin
        l200 = $l200
        filekeys = $filekeys
        dsp_config = $dsp_config
        pars_tau = $pars_tau
        pars_optimization = $pars_optimization
        chinfo = $chinfo
        reprocess = $reprocess
        max_wvfs = $max_wvfs
    end

    @everywhere function single_file_dsp(fk::FileKey)
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
        @timeit dsp_timer "DSP" begin
            # loop over channels
            for (ch, det) in zip(chinfo.channel, chinfo.detector)

                # check if channel can be processed
                if haskey(outdata, ch) && !reprocess
                    @info "Detector $det ($ch) already processed, skip"
                    continue
                end
                # check for decay time
                if !haskey(pars_tau, det)
                    @warn "No decay time for detector $det, skip channel $ch"
                    continue
                end
                # check if channel has values for RT and FT for different filters
                if !haskey(pars_optimization, det)
                    @warn "No optimization parameters for detector $det, skip channel $ch"
                    continue
                end
                # check if channel has values for SG optimization, otherwise use standard value
                if !haskey(pars_optimization[det], :sg)
                    @warn "No AoE window length optimization parameter for detector $det, use default."
                    pars_optimization[det].sg.wl.val = 100.0 # ns
                end

                @debug "Processing channel $ch ($det)"
                error_dets = ""
                @timeit dsp_timer "DSP $det" begin
                    # process data
                    outdata_ch = nothing
                    try
                        outdata_ch = fast_flatten([
                                dsp_icpc(data_part[:], dsp_config, pars_tau[det].tau.val*u"µs", pars_optimization[det]) 
                                for data_part in Iterators.partition(data[ch].raw, max_wvfs)])
                    catch e
                        if e isa TaskFailedException
                            e = e.task.exception
                        end
                        @error "Error processing channel $ch ($det) in $(fk): $e"
                        error_dets *= "$det, "
                        continue
                    end
                    # save data to hdf5
                    outdata[ch] = outdata_ch
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

        # create total timer by summing over memory usage and time
        total_time      = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(dsp_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(dsp_timer))
        # create log
        log_line = MarkdownLogLine(fk, true, error_dets, [n_detectors, total_time, total_allocated])
        return (timer = dsp_timer, log = log_line, error = false)
    end

    # Base.exit_on_sigint(false)
    # result_dsp = @showprogress pmap(eachindex(filekeys), batch_size = 1, retry_check=retry_check, retry_delays=ExponentialBackOff(n=3)) do idx
    #     try
    #         t_end = time() + timeout
    #         task = Threads.@spawn single_file_dsp(idx)
    #         while !istaskdone(task) && time() <= t_end
    #             sleep(0.1)
    #         end
    #         if !istaskdone(task)
    #             @debug "Timeout for $(filekeys[idx])"
    #             try
    #                 Base.throwto(task, InterruptException())
    #             catch e
    #                 throw(ErrorException("Timeout for $(filekeys[idx])"))
    #             end
    #             throw(ErrorException("Timeout for $(filekeys[idx])"))
    #         end
    #         idx => fetch(task)
    #     catch e
    #         if e isa TaskFailedException
    #             e = e.task.exception
    #         end
    #         @debug "Write Error log for $(filekeys[idx]): $e"
    #         log_info = "| $(filekeys[idx]) | - | Failed | - | - | $e |"
    #         idx => (timer = TimerOutput(), log = log_info)
    #     end
    # end


    # @info "Finished DSP"
    # @info "Remove all workers"
    # rmprocs(workers()...)

    result_dsp = parallel(filekeys, single_file_dsp, :dsp_cal, processing_config,; timeout=timeout, n_logentries=3)
    
    @info "Remove all workers"
    rmprocs(workers()...)
    
    # main_log = """# Main log 

    # Time of processing: $(now())

    # ## DSP
    # This is the log for the dsp. The algorithm iterates through each file and process within each file each detector separate.

    # # MetaData
    # | Setup | Period | Run | Category |
    # |-------|--------|-----|----------|
    # | $(filekey.setup) | $(filekey.period) | $(filekey.run) | $(filekey.category) |

    # # Results
    # | FileKey | Number of Detectors | Status | Total Time | Total Allocated | Error |
    # |---------|---------------------|--------|------------|-----------------|-------|
    # """

    logger = MarkdownLogger(l200, filekey, :dsp_cal, result_dsp; footer=:timer)
    

#     total_dsp_timer = TimerOutput()
#     for (idx, res) in result_dsp
#         # merge timer into total timer
#         merge!(total_dsp_timer, res.timer)
#         # add log to main log
#         main_log = """
#         $main_log$(res.log)
#         """
#     end
#     # add total timer to main log
#     main_log = """
# $main_log
# # Total Timing
# ```
# $total_dsp_timer
# ```
#     """

    @info "Write main log to disk"
    @info logger
    
    # write main log to disk
    write(logger)
    # log_filename = joinpath(log_folder, format("{}-{}-{}-{}-dsp.md", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
    # open(log_filename, "w+") do file
    #     write(file, replace(main_log, "Success" => raw"$${\color{green}Success}$$", "Failed" => raw"$${\color{red}Failed}$$"))
    # end
end
