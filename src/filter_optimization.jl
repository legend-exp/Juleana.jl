function process_filter_optimization(l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=300)
    @info "Optimize filter for period $period and run $run"

    filekey = sort(search_disk(FileKey, l200.tier[:raw, :cal, period, run]), by = x-> x.time)[1]
    @info "Found filekey $filekey"

    chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable && $usability != :off)

    sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)
    dsp_meta = l200.metadata.dataprod.config.dsp(sel).default
    dsp_config = create_dsp_config(dsp_meta)
    @debug "Loaded DSP config: $(dsp_config)"

    pars_tau = l200.par[:cal, :decay_time, period, run]
    @debug "Loaded decay times"

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

        @debug "Processing channel $ch ($det)"

        if haskey(l200.metadata.dataprod.config.dsp(sel).optimization, det)
            optimization_config = merge(l200.metadata.dataprod.config.dsp(sel).optimization.default, l200.metadata.dataprod.config.dsp(sel).optimization[det])
            @debug "Use config for detector $det"
        else
            optimization_config = l200.metadata.dataprod.config.dsp(sel).optimization.default
            @debug "Use default config"
        end

        result_rt_dict = Dict{Symbol, NamedTuple}()
        result_ft_dict = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, String}()

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(chinfo.detector[i]) already processed, check missing filters"
            for filter_type in keys(optimization_config)
                if filter_type == :sg
                    continue
                end
                if haskey(pars_db[det], filter_type)
                    @debug "Filter $filter_type already processed, skip"
                    if haskey(pars_db[det][filter_type], :min_fwhm)
                        min_fwhm = "$(round(pars_db[det][filter_type].min_fwhm, digits=2))"
                    else
                        min_fwhm = "NaN"
                    end
                    log_info = "| $ch | $det | Success | $filter_type | $(pars_db[det][filter_type].rt.val*u"µs") | $(pars_db[det][filter_type].ft.val*u"µs") | $min_fwhm | Already processed --> skipped. |"
                    # add results to dict
                    result_rt_dict[filter_type] = NamedTuple()
                    result_ft_dict[filter_type] = NamedTuple()
                    log_info_dict[filter_type] = log_info
                end
            end
        end

        # check if all filters are already processed
        if length(keys(result_rt_dict)) == length(keys(optimization_config)) - 1
            @debug "All filters already processed, skip channel"
            return (result_rt = result_rt_dict, result_ft = result_ft_dict, log = log_info_dict)
        end

        filename = joinpath(l200.tier[DataTier(:peaks), :cal, filekey.period, filekey.run], format("{}-{}-{}-{}-{}-tier_peaks.lh5", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch))
        if !isfile(filename)
            @warn "File $filename does not exist, Skip channel $ch"
            throw(LoadError(string(basename(filename)), 154,"File $(basename(filename)) does not exist"))
        end

        yield()
        # load data
        wvfs_ch_fep = nothing
        try
            data = LHDataStore(filename, "r")
            @debug "Loading Tl208 FEP data from $(filename)"
            wvfs_ch_fep = data[ch].Tl208FEP.waveform[:]
            close(data)
            if length(wvfs_ch_fep) > 15000
                @warn "Tl208 FEP events exceed 15000, keep only first 15000 events"
                wvfs_ch_fep = wvfs_ch_fep[1:15000]
            end
        catch e
            @error "FEP data from $(basename(filename)) cannot be loaded"
            throw(LoadError(string(basename(filename)), 154,"FEP data from $(basename(filename)) cannot be loaded"))
        end
        yield()

        GC.gc()

        for filter_type in keys(optimization_config)
            if filter_type == :sg
                continue
            end
            if haskey(result_rt_dict, filter_type)
                continue
            end
            
            try
                @debug "Optimize $filter_type filter"

                # unpack config
                min_enc, max_enc = optimization_config[filter_type].min_enc, optimization_config[filter_type].max_enc
                nbins = optimization_config[filter_type].nbins_enc_sigmas
                rel_cut_fit = optimization_config[filter_type].rel_cut_fit_enc_sigmas
                min_e_fep, max_e_fep = optimization_config[filter_type].min_e_fep, optimization_config[filter_type].max_e_fep
                nbins_fep = optimization_config[filter_type].nbins_e_fep
                rel_cut_fit_fep = optimization_config[filter_type].rel_cut_fit_e_fep
                e_grid_rt = eval(Meta.parse(optimization_config[filter_type].e_grid_rt))
                e_grid_ft = eval(Meta.parse(optimization_config[filter_type].e_grid_ft))
                ft_fixed = optimization_config[filter_type].ft_fixed*u"µs"

                # optimize RT
                enc_grid = nothing
                try
                    @debug "Generate $filter_type ENC filter grid"
                    enc_grid = getfield(Main, Symbol(optimization_config[filter_type].dsp_rt_func))(wvfs_ch_fep, dsp_config, pars_tau[det].tau.val*u"µs",; ft=ft_fixed)
                catch e
                    @error "Error in $filter_type RT DSP for FEP: $e"
                    throw(ErrorException("Error in $filter_type RT DSP for FEP."))
                end

                GC.gc()
                result_rt, report_rt = nothing, nothing
                try
                    result_rt, report_rt = fit_enc_sigmas(enc_grid, e_grid_rt, min_enc, max_enc, nbins, rel_cut_fit)
                catch e
                    @error "Failed $filter_type rise time extraction: $e"
                    throw(ErrorException("Error in $filter_type rise time extraction."))
                end
                @debug format("Found optimal $filter_type RT at $(result_rt.rt) with ENC {:.2f} ADC", result_rt.min_enc)

                plot(report_rt, title=format("{} {} Noise Sweep ({}-{}-{}-{})", string(det), string(filter_type), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
                savefig(joinpath(figures_folder, format("{}-{}-{}-{}-{}-noise_sweep_{}.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch, string(filter_type))))

                # optimize FT
                GC.gc()
                e_grid = nothing
                try
                    @debug "Generate $filter_type FT energy grid"
                    e_grid = getfield(Main, Symbol(optimization_config[filter_type].dsp_ft_func))(wvfs_ch_fep, dsp_config, pars_tau[det].tau.val*u"µs", result_rt.rt)
                catch e
                    @error "Error in $filter_type FT DSP for FEP: $e"
                    throw(ErrorException("Error in $filter_type FT DSP for FEP."))
                end
                GC.gc()
                result_ft, report_ft = nothing, nothing
                try
                    result_ft, report_ft = fit_fwhm_ft_fep(e_grid, e_grid_ft, result_rt.rt, min_e_fep, max_e_fep, nbins_fep, rel_cut_fit_fep)
                catch e
                    @error "Failed $filter_type flat-top time extraction: $e"
                    throw(ErrorException("Error in $filter_type flat-top time extraction."))
                end
                @debug format("Found optimal $filter_type FT at $(result_ft.ft) with FWHM {:.2f} keV", result_ft.min_fwhm)
                
                plot(report_ft, title=format("{} {} FWHM FEP FT Scan ({}-{}-{}-{})", string(det), string(filter_type), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))

                savefig(joinpath(figures_folder, format("{}-{}-{}-{}-{}-fwhm_ft_scan_{}.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch, string(filter_type))))

                log_info = "| $ch | $det | Success | $filter_type | $(result_rt.rt) | $(result_ft.ft) | $(round(result_ft.min_fwhm, digits=2)) | - |"

                # add results to dict
                result_rt_dict[filter_type] = result_rt
                result_ft_dict[filter_type] = result_ft
                log_info_dict[filter_type] = log_info

                # call garbage collector
                GC.gc()
            catch e
                @error "Error in $filter_type filter optimization: $e"
                log_info = "| ch$(chinfo.channel[i]) | $(chinfo.detector[i]) | Failed | $filter_type | - | - | $(e) |"
                # add results to dict
                result_rt_dict[filter_type] = NamedTuple()
                result_ft_dict[filter_type] = NamedTuple()
                log_info_dict[filter_type] = log_info
            end
        end

        return (result_rt = result_rt_dict, result_ft = result_ft_dict, log = log_info_dict)
    end

    Base.exit_on_sigint(false)
    result_filter = @showprogress pmap(reverse(eachindex(chinfo.channel)), batch_size = 1, retry_check=retry_check, retry_delays=ExponentialBackOff(n=3)) do idx
        try
            t_end = time() + timeout
            task = Threads.@spawn ch_filter_optimization(idx)
            while !istaskdone(task) && time() <= t_end
                sleep(0.1)
            end
            if !istaskdone(task)
                @debug "Timeout for $(chinfo.detector[idx])"
                try
                    schedule(task, ErrorException("Timeout"), error=true)
                catch e
                    throw(ErrorException("Timeout for $(chinfo.detector[idx])"))
                end
                throw(ErrorException("Timeout for $(chinfo.detector[idx])"))
            end
            chinfo.detector[idx] => fetch(task)
        catch e
            if e isa TaskFailedException
                e = e.task.exception
            end
            @debug "Write Error log for $(chinfo.detector[idx]): $e"
            log_info = "| ch$(chinfo.channel[idx]) | $(chinfo.detector[idx]) | Failed | ? | - | - | - | $(e) |"
            chinfo.detector[idx] => (result_rt = Dict{Symbol, NamedTuple}(), result_ft = Dict{Symbol, NamedTuple}(), log = log_info)
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
    | Channel | Detector | Status | Filter | Rise Time | Flat-Top Time | Min. FWHM (keV) | Error |
    |---------|----------|--------|--------|-----------|---------------|-----------------|-------|
    """
    # extract results into pars_db and append to main log
    for (det, res) in result_filter
        # save pars to db
        if !isempty(res.result_rt)
            pars_det = pars_db[det]
            for (flt_type, res_rt) in res.result_rt
                if isempty(res_rt)
                    continue
                end
                pars_det_flt_type           = pars_det[flt_type]
                pars_det_flt_type.rt        = res_rt.rt
                pars_det_flt_type.rt_err    = res_rt.rt_err
                pars_det_flt_type.min_enc   = res_rt.min_enc
            end
            for (flt_type, res_ft) in res.result_ft
                if isempty(res_ft)
                    continue
                end
                pars_det_flt_type           = pars_det[flt_type]
                pars_det_flt_type.ft        = res_ft.ft
                pars_det_flt_type.ft_err    = res_ft.ft_err
                pars_det_flt_type.min_fwhm  = res_ft.min_fwhm
            end
            for (flt_type, log_info) in res.log
                # add log to main log
                main_log = """
                $main_log$(log_info)
                """
            end
        else
            # add log to main log
            main_log = """
            $main_log$(res.log)
            """
        end
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

    log_filename = joinpath(log_folder, format("{}-{}-{}-{}-filter_optimization.md", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
    open(log_filename, "w+") do file
        write(file, replace(main_log, "Success" => raw"$${\color{green}Success}$$", "Failed" => raw"$${\color{red}Failed}$$"))
    end
end

