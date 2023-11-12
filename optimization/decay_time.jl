function process_decay_time(l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false)
    @info "Process decay time for period $period and run $run"

    filekey = sort(search_disk(FileKey, l200.tier[:raw, :cal, period, run]), by = x-> x.time)[1]
    @info "Found filekey $filekey"

    chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable && $usability != :off)

    sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)
    dsp_meta = l200.metadata.dataprod.config.cal.dsp(sel).default
    dsp_config = create_dsp_config(dsp_meta)
    @debug "Loaded DSP config: $(dsp_config)"

    @debug "Create figures folder"
    figures_folder = joinpath(l200.tier[:plt, :cal, period, run], "decay_time")
    if isdir(figures_folder)
        @debug("Figure folder $figures_folder already exists")
    else
        mkpath(figures_folder)
    end

    @debug "Create logs folder"
    log_folder = joinpath(l200.tier[:log, :cal, period, run])
    if isdir(log_folder)
        @debug "Log folder $log_folder already exists"
    else
        mkpath(log_folder)
    end

    @debug "Create pars db"
    pars_db = PropDict()
    # read params if exist
    if !(haskey(l200.par[:cal, :decay_time], Symbol(period)))
        # path folder for current period seems not to exist, will create it first to avoid errors
        mkpath(joinpath(l200.tier[:par, :cal], "decay_time", "$period"))
        # write validity
        pars_validTimeStamp = string(filekey.time)
        open(joinpath(l200.tier[:par, :cal], "decay_time", "validity.jsonl"), "a") do io
            println(io, "{\"valid_from\":\"$pars_validTimeStamp\", \"category\":\"all\", \"apply\":[\"$period/$run.json\"]}")
        end
    elseif haskey(l200.par[:cal, :decay_time, period], Symbol(run))
        @info "Pars file already exists."
        pars_db = l200.par[:cal, :decay_time, period, run]
    else
        # write validity
        pars_validTimeStamp = string(filekey.time)
        open(joinpath(l200.tier[:par, :cal], "decay_time", "validity.jsonl"), "a") do io
            println(io, "{\"valid_from\":\"$pars_validTimeStamp\", \"category\":\"all\", \"apply\":[\"$period/$run.json\"]}")
        end
    end

    if reprocess
        @info "Reprocess all channels"
        pars_db = PropDict()
    else
        @info "Only reprocess channels that are not in pars_db"
    end

    # move all variables to workers
    @everywhere begin
        l200 = $l200
        sel = $sel
        dsp_config = $dsp_config
        filekey = $filekey
        chinfo = $chinfo
        figures_folder = $figures_folder
        pars_db = $pars_db
        reprocess = $reprocess
    end


    @everywhere function ch_decay_time(i::Int64)

        ch_short = chinfo.channel[i]
        ch = format("ch{}", ch_short)
        det = chinfo.detector[i]

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(chinfo.detector[i]) already processed, skip"
            log = "| $ch | $det | Success | $(round(pars_db[det].tau.val, digits=2)) | $(round(pars_db[det].tau_err.val, digits=2)) | $(pars_db[det].n_tau) | Already processed --> skipped. |"
            result_dt = (
                μ = NaN*u"μs",
                μ_err = NaN*u"μs",
                σ = NaN*u"μs",
                σ_err = NaN*u"μs",
                n = NaN
            )
            return (result = result_dt, log = log)
        end

        @debug "Processing channel $ch ($det)"

        if haskey(l200.metadata.dataprod.config.cal.dsp(sel).decay_time, det)
            decay_time_config = merge(l200.metadata.dataprod.config.cal.dsp(sel).decay_time.default, l200.metadata.dataprod.config.cal.dsp(sel).decay_time[det])
            @debug "Use config for detector $det"
        else
            decay_time_config = l200.metadata.dataprod.config.cal.dsp(sel).decay_time.default
            @debug "Use default config"
        end

        # unpack config
        min_τ, max_τ = decay_time_config.min_tau*u"µs", decay_time_config.max_tau*u"µs"
        nbins = decay_time_config.nbins
        rel_cut_fit = decay_time_config.rel_cut_fit


        filename = joinpath(l200.tier[DataTier(:peaks), :cal, filekey.period, filekey.run], format("{}-{}-{}-{}-{}-tier_peaks.lh5", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch))
        if !isfile(filename)
            @warn "File $filename does not exist, Skip channel $ch"
            throw(LoadError(string(basename(filename)), 154,"File $(basename(filename)) does not exist"))
        end

        # load data
        wvfs_ch_fep = nothing
        try
            data = LHDataStore(filename, "r")
            @debug "Loading Tl208 FEP data from $(filename)"
            wvfs_ch_fep = data[ch].Tl208FEP.waveform[:]
            close(data)    
        catch e
            @error "FEP data from $(basename(filename)) cannot be loaded"
            throw(LoadError(string(basename(filename)), 154,"FEP data from $(basename(filename)) cannot be loaded"))
        end
        
        # DSP
        decay_times = nothing
        try
            @debug "Generating DSP for FEP decay times"
            decay_times = dsp_decay_times(wvfs_ch_fep, dsp_config)
        catch e
            @error "Error in DSP for FEP"
            throw(ErrorException("Error in DSP for FEP."))
        end

        # get decay time
        cuts_τ =  nothing
        result = nothing
        report = nothing
        try
            cuts_τ = cut_single_peak(decay_times, min_τ, max_τ,; n_bins=nbins, relative_cut=rel_cut_fit)

            result, report = fit_single_trunc_gauss(decay_times, cuts_τ)
        catch e
            @error "Failed decay time extraction"
            throw(ErrorException("Error in decay time extraction."))
        end

        plot(report, decay_times, cuts_τ, xlabel="Decay Time [µs]")
        title!(format("{} Decay Time Distribution ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))

        savefig(joinpath(figures_folder, format("{}-{}-{}-{}-{}-decay_time.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

        @info """Found decay time at $(round(ustrip(result.μ), digits=2)) ± $(round(ustrip(result.μ_err), digits=2))µs for channel $ch ($det)"""

        log_info = "| $ch | $det | Success | $(round(ustrip(result.μ), digits=2)) | $(round(ustrip(result.μ_err), digits=2)) | $(result.n) | - |"

        return (result = result, log = log_info)
    end

    result_decay_time = @showprogress pmap(eachindex(chinfo.channel), batch_size = 3) do idx
        try
            chinfo.detector[idx] => ch_decay_time(idx)
        catch e
            @debug "Write Error log for $(chinfo.detector[idx])"
            log_info = "| ch$(chinfo.channel[idx]) | $(chinfo.detector[idx]) | Failed | - | - | - | $(e) |"
            result_dt = (
                μ = NaN*u"μs",
                μ_err = NaN*u"μs",
                σ = NaN*u"μs",
                σ_err = NaN*u"μs",
                n = NaN
            )
            chinfo.detector[idx] => (result = result_dt, log = log_info)
        end
    end

    @info "Finished decay time extraction"
    @info "Remove all workers"
    rmprocs(workers()...)

    main_log = """
    # Main log 
    Time of processing: $(now())
    ## Decay Time Extraction
    This is the log for the decay time extraction. The algorithm loads the FEP data of each channel.
    After a mini DSP, the decay times are extracted by fittiing an exponential function to the tail.
    Then, the distribution is truncated around the peak to fit a truncated gaussian function.
    The centroid of the distribution is extracted as the decay time.

    # MetaData
    | Setup | Period | Run | Category |
    |-------|--------|-----|----------|
    | $(filekey.setup) | $(filekey.period) | $(filekey.run) | $(filekey.category) |

    # Results
    | Channel | Detector | Status | Decay Time | Decay Time Error | Number of Events | Error |
    |---------|----------|--------|------------|------------------|------------------|-------|
    """
    # extract results into pars_db and append to main log
    for (det, res) in result_decay_time
        # save pars to db
        if !isnan(res.result.n)
            pars_det                    = pars_db[det]
            pars_det.tau                = res.result.μ
            pars_det.tau_err            = res.result.μ_err
            pars_det.sigma              = res.result.σ
            pars_det.sigma_err          = res.result.σ_err
            pars_det.n_tau              = res.result.n
        end
        # add log to main log
        main_log = """
        $main_log$(res.log)
        """
        # main_log *= res.log
    end

    # save pars to disk
    @info "Save pars to disk"
    
    # write pars
    writeprops(joinpath(l200.tier[:par, :cal], "decay_time", "$period/$run.json"), pars_db, multiline=true)

    @info "Write main log to disk"
    @info main_log

    log_filename = joinpath(log_folder, format("{}-{}-{}-{}-decay_time.md", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
    open(log_filename, "w+") do file
        write(file, replace(main_log, "Success" => raw"$${\color{green}Success}$$", "Failed" => raw"$${\color{red}Failed}$$"))
    end
end