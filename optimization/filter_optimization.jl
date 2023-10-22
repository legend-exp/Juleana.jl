function process_filter_optimization(l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false)
    @info "Optimize filter for period $period and run $run"

    filekey = sort(search_disk(FileKey, l200.tier[:raw, :cal, period, run]), by = x-> x.time)[1]
    @info "Found filekey $filekey"

    chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable)

    sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)
    dsp_meta = l200.metadata.dataprod.config.cal.dsp(sel).default
    dsp_config = create_dsp_config(dsp_meta)
    @debug "Loaded DSP config: $(dsp_config)"

    pars_tau = l200.par[:cal, :decay_time, period, run]
    @debug "Loaded decay times"

    @debug "Create figures folder"
    figures_folder = joinpath(l200.tier[:plt, :cal, period, run], "optimization")
    ifelse(isdir(figures_folder), @debug("Figure folder $figures_folder already exists"), mkpath(figures_folder))

    @debug "Create logs folder"
    log_folder = joinpath(l200.tier[:log, :cal, period, run])
    ifelse(isdir(log_folder), @debug("Log folder $log_folder already exists"), mkpath(log_folder))

    @debug "Create pars db"
    pars_db = PropDict()
    # read params if exist
    if !(Symbol(period) in keys(l200.par[:cal, :optimization]))
        # path folder for current period seems not to exist, will create it first to avoid errors
        mkpath(joinpath(l200.tier[:par, :cal], "optimization", "$period"))
        # write validity
        pars_validTimeStamp = string(filekey.time)
        open(joinpath(l200.tier[:par, :cal], "optimization", "validity.jsonl"), "a") do io
            println(io, "{\"valid_from\":\"$pars_validTimeStamp\", \"category\":\"all\", \"apply\":[\"$period/$run.json\"]}")
        end
    elseif !(l200.par[:cal, :optimization, period, run] isa LegendDataManagement.NoSuchPropsDBEntry)
        @info "Pars file already exists."
        pars_db = l200.par[:cal, :optimization, period, run]
    else
        # write validity
        pars_validTimeStamp = string(filekey.time)
        open(joinpath(l200.tier[:par, :cal], "optimization", "validity.jsonl"), "a") do io
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
        pars_tau = $pars_tau
    end


    @everywhere function ch_filter_optimization(i::Int64)

        ch_short = chinfo.channel[i]
        ch = format("ch{}", ch_short)
        det = chinfo.detector[i]

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(chinfo.detector[i]) already processed, skip"
            log = "| $ch | $det | Success | $(pars_db[det].trap_rt.val*u"µs") | $(pars_db[det].trap_ft.val*u"µs") | $(round(pars_db[det].trap_min_fwhm, digits=2)) | Already processed --> skipped. |"
            return (result_rt = (rt = NaN*u"µs", ), result_ft = (ft = NaN*u"µs", ), log = log)
        end


        @debug "Processing channel $ch ($det)"

        if haskey(l200.metadata.dataprod.config.cal.dsp(sel).optimization, det)
            optimization_config = l200.metadata.dataprod.config.cal.dsp(sel).optimization[det]
            @debug "Use config for detector $det"
        else
            optimization_config = l200.metadata.dataprod.config.cal.dsp(sel).optimization.default
            @debug "Use default config"
        end

        # unpack config
        min_enc, max_enc = optimization_config.trap.min_enc, optimization_config.trap.max_enc
        nbins = optimization_config.trap.nbins_enc_sigmas
        rel_cut_fit = optimization_config.trap.rel_cut_fit_enc_sigmas


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

        # optimize RT
        enc_trap_grid = nothing
        try
            @debug "Generate trap ENC filter grid"
            enc_trap_grid = dsp_trap_rt_optimization(wvfs_ch_fep, dsp_config, pars_tau[det].tau.val*u"µs",; ft=1.0u"µs")
        catch e
            @error "Error in RT DSP for FEP: $e"
            throw(ErrorException("Error in RT DSP for FEP."))
        end

        result_rt, report_rt = nothing, nothing
        try
            result_rt, report_rt = fit_enc_sigmas(enc_trap_grid, dsp_config.e_grid_rt_trap, min_enc, max_enc, nbins, rel_cut_fit)
        catch e
            @error "Failed rise time extraction: $e"
            throw(ErrorException("Error in rise time extraction."))
        end
        @debug format("Found optimal RT at $(result_rt.rt) with ENC {:.2f} ADC", result_rt.min_enc)

        plot(report_rt, title=format("{} Noise Sweep ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
        savefig(joinpath(figures_folder, format("{}-{}-{}-{}-{}-noise_sweep.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))


        # optimize FT
        e_trap_grid = nothing
        try
            @debug "Generate trap FT energy grid"
            e_trap_grid = dsp_trap_ft_optimization(wvfs_ch_fep, dsp_config, pars_tau[det].tau.val*u"µs", result_rt.rt)
        catch e
            @error "Error in FT DSP for FEP: $e"
            throw(ErrorException("Error in FT DSP for FEP."))
        end
        result_ft, report_ft = nothing, nothing
        try
            result_ft, report_ft = fit_fwhm_ft_fep(e_trap_grid, dsp_config.e_grid_ft_trap)
        catch e
            @error "Failed flat-top time extraction: $e"
            throw(ErrorException("Error in flat-top time extraction."))
        end
        @debug format("Found optimal FT at $(result_ft.ft) with FWHM {:.2f} keV", result_ft.min_fwhm)
        
        plot(report_ft, title=format("{} FWHM FEP FT Scan ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))

        savefig(joinpath(figures_folder, format("{}-{}-{}-{}-{}-fwhm_ft_scan.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

        log_info = "| $ch | $det | Success | $(result_rt.rt) | $(result_ft.ft) | $(round(result_ft.min_fwhm, digits=2)) | - |"
        
        return (result_rt = result_rt, result_ft = result_ft, log = log_info)
    end

    result_filter = @showprogress pmap(eachindex(chinfo.channel), batch_size = 1) do idx
        try
            chinfo.detector[idx] => ch_filter_optimization(idx)
        catch e
            @debug "Write Error log for $(chinfo.detector[idx]): $e"
            log_info = "| ch$(chinfo.channel[idx]) | $(chinfo.detector[idx]) | Failed | - | - | - | $(e) |"
            chinfo.detector[idx] => (result_rt = (rt = NaN*u"µs", ), result_ft = (ft = NaN*u"µs", ), log = log_info)
        end
    end

    @info "Finished filter optimization"
    @info "Remove all workers"
    rmprocs(workers()...)

    main_log = """# Main log
    Time of processing: $(now())
    ## Filter Optimization
    This is the log for the energy filter optimization. The algorithm loads the FEP data of each channel.
    After a mini DSP, the optimal rise time is determined by performing a noise sweep on the baseline and look for minimal ENC with a fixed flat-top time.
    Then, the optimal rise time is used for a mini DSP while sweeping through flat-top times and selecting the one which has minimal FWHM at the FEP.

    # MetaData
    | Setup | Period | Run | Category |
    |-------|--------|-----|----------|
    | $(filekey.setup) | $(filekey.period) | $(filekey.run) | $(filekey.category) |

    # Results
    | Channel | Detector | Status | Rise Time | Flat-Top Time | Min. FWHM (keV) | Error |
    |---------|----------|--------|-----------|---------------|-----------------|-------|
    """
    # extract results into pars_db and append to main log
    for (det, res) in result_filter
        # save pars to db
        if !isnan(res.result_rt.rt)
            pars_det                    = pars_db[det]
            pars_det.trap_rt            = res.result_rt.rt
            pars_det.trap_rt_err        = step(dsp_config.e_grid_rt_trap)
            pars_det.trap_min_enc       = res.result_rt.min_enc
            pars_det.trap_ft            = res.result_ft.ft
            pars_det.trap_ft_err        = step(dsp_config.e_grid_ft_trap)
            pars_det.trap_min_fwhm      = res.result_ft.min_fwhm
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
    writeprops(joinpath(l200.tier[:par, :cal], "optimization", "$period/$run.json"), pars_db, multiline=true)

    @info "Write main log to disk"
    @info main_log

    log_filename = joinpath(log_folder, format("{}-{}-{}-{}-filter_optimization.md", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
    open(log_filename, "w+") do file
        write(file, replace(main_log, "Success" => raw"$${\color{green}Success}$$", "Failed" => raw"$${\color{red}Failed}$$"))
    end
end

