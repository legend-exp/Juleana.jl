using LegendDataManagement, PropertyFunctions, TypedTables, PropDicts
using Unitful, Formatting, LaTeXStrings, Measures
using Plots, StatsBase
using LegendHDF5IO, LegendDSP, LegendSpecFits
using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked

ENV["JULIA_DEBUG"] = Main # enable debug

gr()
plotlyjs(size=(800, 500))
# plotlyjs(size=(1200, 800))

@info "Loading Legend MetaData"
l200 = LegendData(:l200)

period = DataPeriod(3)
run    = DataRun(0)
reprocess = true

# function process_sipm(l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool = false, timeout::Int=3600)
    @info "Process SiPM DSP for period $period and run $run"

    filekeys = sort(search_disk(FileKey, l200.tier[:raw, :phy, period, run]), by = x-> x.time)
    filekey = filekeys[1]
    @info "Found filekey $filekey"
    chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :spms && $processable) 

    sel = LegendDataManagement.ValiditySelection(filekey.time, :phy)

    dsp_meta = l200.metadata.dataprod.config.phy.sipm(sel)
    @debug "Loaded DSP config: $(dsp_meta)"

    pars_sipm = l200.par[:phy, :sipm](sel)
    @debug "Loaded SiPM parameters"

    filename    = l200.tier[:raw, filekey]

    i=1
    ch_short = chinfo.channel[i]
    ch = format("ch{}", ch_short)
    det = chinfo.detector[i]
    data_ch = LHDataStore(filename, "r")["$ch/raw"][:]
    close(data_ch)
    test_dsp = dsp_sipm(data_ch, dsp_meta.default, pars_sipm[det])

    rm("/home/iwsatlas1/henkes/l200/auto/sipm/test.lh5")
    test_t = TypedTables.Table(a = [Float64[NaN],Float64[1,2],Float64[3]], b = [4,5,6])
    outtest = LHDataStore("/home/iwsatlas1/henkes/l200/auto/sipm/test.lh5", "w")
    outtest[ch] = test_dsp
    close(outtest)
    
    
    
    @debug "Create DSP folder"
    dsp_folder = l200.tier[:dsp, :phy, period, run]
    if isdir(dsp_folder)
        @debug("DSP folder $dsp_folder already exists")
    else
        mkpath(dsp_folder)
    end

    @debug "Create logs folder"
    log_folder = joinpath(l200.tier[:log, :phy, period, run])
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
        dsp_meta = $dsp_meta
        pars_sipm = $pars_sipm
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
                if !haskey(pars_sipm, det)
                    @warn "No thresholds for detector $det, skip channel $ch"
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
                    dsp_meta_ch = nothing
                    if haskey(dsp_meta, det)
                        dsp_meta_ch = merge(dsp_meta.default, dsp_meta[det])
                    else
                        dsp_meta_ch = dsp_meta.default
                    end
                    outdata[ch]  = dsp_sipm(data_ch, dsp_meta_ch, pars_sipm[det])
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
# end