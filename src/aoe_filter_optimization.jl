function process_aoe_optimization(l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=300)

    @info "Optimize PSD filter for period $period and run $run"

    filekey = sort(search_disk(FileKey, l200.tier[:raw, :cal, period, run]), by = x-> x.time)[1]
    @info "Found filekey $filekey"

    chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable && $usability == :on)

    sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)
    dsp_meta = l200.metadata.dataprod.config.cal.dsp(sel).default
    dsp_config = create_dsp_config(dsp_meta)
    @debug "Loaded DSP config: $(dsp_config)"

    pars_tau = l200.par[:cal, :decay_time, period, run]
    @debug "Loaded decay times"

    pars_optimization = l200.par[:cal, :optimization, period, run]
    @debug "Loaded optimization parameters"

    @debug "Create figures folder"
    figures_folder = joinpath(l200.tier[:plt, :cal, period, run], "optimization")
    if isdir(figures_folder)
        @debug("Figure folder $figures_folder already exists")
    else
        mkpath(figures_folder)
    end

    @debug "Create logs folder"
    log_folder = joinpath(l200.tier[:log, :cal, period, run])
    if isdir(log_folder)
        @debug("Log folder $log_folder already exists")
    else
        mkpath(log_folder)
    end

    @debug "Create pars db"
    pars_db = PropDict()
    # read params if exist
    if !(haskey(l200.par[:cal, :optimization], Symbol(period)))
        # path folder for current period seems not to exist, will create it first to avoid errors
        mkpath(joinpath(l200.tier[:par, :cal], "optimization", "$period"))
    elseif haskey(l200.par[:cal, :optimization, period], Symbol(run))
        @info "Pars file already exists."
        pars_db = l200.par[:cal, :optimization, period, run]
    end

    if reprocess
        @info "Reprocess all channels"
        for det in keys(pars_db)
            pars_db[det].sg = nothing
            PropDicts.trim_null!(pars_db[det])
        end
        PropDicts.trim_null!(pars_db)
    else
        @info "Only reprocess channels that are not in pars_db"
    end
    
    # move all variables to workers
    @everywhere begin
        l200 = $l200
        sel = $sel
        dsp_config = $dsp_config
        filekey = $filekey
        pars_tau = $pars_tau
        pars_optimization = $pars_optimization
        chinfo = $chinfo
        figures_folder = $figures_folder
        pars_db = $pars_db
        reprocess = $reprocess
    end


    @everywhere function ch_sg_optimization(i::Int64)

        ch_short = chinfo.channel[i]
        ch = format("ch{}", ch_short)
        det = chinfo.detector[i]

        if !reprocess && haskey(pars_db, det) && haskey(pars_db[det], :sg)
            @debug "Channel $(chinfo.detector[i]) already processed, skip"
            log = "| $ch | $det | Success | $(pars_db[det].sg.wl.val*u"ns") | $(round(pars_db[det].sg.min_sep_sf, digits=2)) | $(round(pars_db[det].sg.min_sep_sf_err, digits=2)) | Already processed --> skipped. |"
            result_sg_wl = (
                wl = NaN*u"ns",
                sf = NaN,
                sf_err = NaN
            )
            return (result = result_sg_wl, log = log)
        end

        @info "Processing channel $ch ($det)"

        if haskey(l200.metadata.dataprod.config.cal.dsp(sel).optimization, det)
            optimization_config = merge(l200.metadata.dataprod.config.cal.dsp(sel).optimization.default, l200.metadata.dataprod.config.cal.dsp(sel).optimization[det])
            @debug "Use config for detector $det"
        else
            optimization_config = l200.metadata.dataprod.config.cal.dsp(sel).optimization.default
            @debug "Use default config"
        end
        
        filename = joinpath(l200.tier[DataTier(:peaks), :cal, filekey.period, filekey.run], format("{}-{}-{}-{}-{}-tier_peaks.lh5", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch))
        if !isfile(filename)
            @warn "File $filename does not exist, Skip channel $ch"
            # throw(LoadError(string(basename(filename)), 154,"File $(basename(filename)) does not exist"))
        end
        
        wvfs_ch_dep = nothing
        wvfs_ch_sep = nothing
        
        try 
            data = LHDataStore(filename, "r")

            @debug "Loading Tl208 FEP data from $(filename)"
            wvfs_ch_dep_bi121fep = data[ch].Tl208DEP_Bi212FEP.waveform[:]
            e_ch_dep_bi121fep    = data[ch].Tl208DEP_Bi212FEP.daqenergy[:]
            wvfs_ch_dep   = wvfs_ch_dep_bi121fep[e_ch_dep_bi121fep .< quantile(e_ch_dep_bi121fep, optimization_config.sg.dep_sep_quantile)]
            wvfs_ch_sep   = data[ch].Tl208SEP.waveform[:]

            close(data)
        catch e
            @error "DEP and SEP data from $(basename(filename)) cannot be loaded"
            throw(LoadError(string(basename(filename)), 154,"DEP and SEP data from $(basename(filename)) cannot be loaded"))
        end
        
        dsp_dep = nothing
        dsp_sep = nothing

        try
            # DSP
            @debug "Generating DSP AoE grid for SEP and DEP data"
            dsp_dep = dsp_sg_optimization(wvfs_ch_dep, dsp_config, pars_tau[det].tau.val*u"µs", pars_optimization[det])
            dsp_sep = dsp_sg_optimization(wvfs_ch_sep, dsp_config, pars_tau[det].tau.val*u"µs", pars_optimization[det])
        catch e
            @error "Failed DSP for DEP or SEP"
            throw(ErrorException("Error in DSP for DEP or SEP."))
        end

        # free memory
        GC.gc()

        dep_sep_after_qc = nothing

        try
            # generate simple QC cuts
            @debug "Use simple QC cuts for SEP and DEP"
            dep_sep_after_qc = qc_sg_optimization(dsp_dep, dsp_sep, optimization_config)
        catch e
            @error "Failed QC for DEP or SEP"
            throw(ErrorException("QC for DEP or SEP."))
        end
        
        # free memory
        GC.gc()

        result_sg_wl, report_sg_wl = nothing, nothing

        try
            # fit SG window length
            @debug "Sweep through window lengths for SEP and DEP and get SEP survival fraction after simple PSD cut on DEP"
            result_sg_wl, report_sg_wl = fit_sg_wl(dep_sep_after_qc, dsp_config.a_grid_wl_sg, optimization_config)    
        catch e
            @error "Failed SG window length optimization"
            throw(ErrorException("SG window length optimization."))
        end
        
        plot(report_sg_wl, title=format("{} SG Filter Optimization ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))

        savefig(joinpath(figures_folder, format("{}-{}-{}-{}-{}-sg_sweep.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

        @info """Found optimal window length at $(result_sg_wl.wl) with survival fraction $(round(result_sg_wl.sf, digits=2)) ± $(round(result_sg_wl.sf_err, digits=2))%"""

        # write log
        log_info = "| $ch | $det | Success | $(result_sg_wl.wl) | $(round(result_sg_wl.sf, digits=2)) | $(round(result_sg_wl.sf_err, digits=2)) | - |"
        
        # free memory
        GC.gc()

        return (result = result_sg_wl, log = log_info)
    end

    Base.exit_on_sigint(false)
    result_sg = @showprogress pmap(eachindex(chinfo.channel), batch_size = 1, retry_check=retry_check, retry_delays=ExponentialBackOff(n=3)) do idx
        try
            t_end = time() + timeout
            task = Threads.@spawn ch_sg_optimization(idx)
            while !istaskdone(task) && time() <= t_end
                sleep(0.1)
            end
            if !istaskdone(task)
                @debug "Timeout for $(chinfo.detector[idx])"
                # try
                schedule(task, ErrorException("Timeout for $(chinfo.detector[idx])"), error=true)
                # catch e
                    # throw(ErrorException("Timeout for $(chinfo.detector[idx])"))
                # end
                throw(ErrorException("Timeout for $(chinfo.detector[idx])"))
            end
            chinfo.detector[idx] => fetch(task)
        catch e
            if e isa TaskFailedException
                e = e.task.exception
            end
            @debug "Write Error log for $(chinfo.detector[idx])"
            log_info = "| ch$(chinfo.channel[idx]) | $(chinfo.detector[idx]) | Failed | - | - | - | $(e) |"
            result_sg_wl = (
                wl = NaN*u"ns",
                sf = NaN,
                sf_err = NaN
            )
            chinfo.detector[idx] => (result = result_sg_wl, log = log_info)
        end
    end

    @info "Finished SG filter optimization"
    @info "Remove all workers"
    rmprocs(workers()...)

    main_log = """
    # Main log 
    Time of processing: $(now())
    ## SG window length optimization
    This is the log for the savitzky-golay filter optimization for the PSD analysis. The processing involves
    a small DSP routine on the waveforms in the DEP and SEP, a simple AoE cut for different window lengths
    and the calculation of the survival fraction in the SEP after a simple PSD cut on the DEP. Then, the 
    window length with the lowest survival fraction is chosen.

    # MetaData
    | Setup | Period | Run | Category |
    |-------|--------|-----|----------|
    | $(filekey.setup) | $(filekey.period) | $(filekey.run) | $(filekey.category) |

    # Results
    | Channel | Detector | Status | Window length | SF    | SF Error | Error |
    |---------|----------|--------|---------------|-------|----------|-------|
    """
    # extract results into pars_db and append to main log
    for (det, res) in result_sg
        # save pars to db
        if !isnan(res.result.sf)
            pars_det                    = pars_db[det]
            pars_det.sg.wl              = res.result.wl
            pars_det.sg.min_sep_sf      = res.result.sf
            pars_det.sg.min_sep_sf_err  = res.result.sf_err
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

    # write validity
    pars_validTimeStamp = string(filekey.time)
    add_validity = true
    for ln in eachline(open(joinpath(l200.tier[:par, :cal], "optimization", "validity.jsonl"), "r"))
        if (contains(ln, "$pars_validTimeStamp"))
            add_validity = false
        end
    end
    if add_validity
        open(joinpath(l200.tier[:par, :cal], "optimization", "validity.jsonl"), "a") do io
            println(io, "{\"valid_from\":\"$pars_validTimeStamp\", \"category\":\"all\", \"apply\":[\"$period/$run.json\"]}")
        end
    end

    @info "Write main log to disk"
    @info main_log

    log_filename = joinpath(log_folder, format("{}-{}-{}-{}-sg_filter_optimization.md", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
    open(log_filename, "w+") do file
        write(file, replace(main_log, "Success" => raw"$${\color{green}Success}$$", "Failed" => raw"$${\color{red}Failed}$$"))
    end
end

