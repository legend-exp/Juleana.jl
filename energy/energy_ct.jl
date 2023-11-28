function process_ct_correction(l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=300)

    @info "CT correction for period $period and run $run"

    filekeys = sort(search_disk(FileKey, l200.tier[:raw, :cal, period, run]), by = x-> x.time)
    filekey = filekeys[1]
    @info "Found filekey $filekey"

    chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable && $usability != :off)

    sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)

    @debug "Create Hit folder"
    hit_folder = l200.tier[:hit, :cal, period, run]
    if isdir(hit_folder)
        @debug("Hit folder $hit_folder already exists")
    else
        mkpath(hit_folder)
    end

    @debug "Create figures folder"
    figures_folder = joinpath(l200.tier[:plt, :cal, period, run], "energy")
    if isdir(figures_folder)
        @debug("Figure folder $figures_folder already exists")
    else
        mkpath(figures_folder)
    end

    for str in unique(chinfo.string)
        figures_folder_string = joinpath(figures_folder, format("string{:02d}", str))
        if isdir(figures_folder_string)
            @debug("String Figure folder $figures_folder_string already exists")
        else
            mkpath(figures_folder_string)
        end
    end

    @debug "Create logs folder"
    log_folder = joinpath(l200.tier[:log, :cal, period, run])
    if isdir(log_folder)
        @debug("Log folder $figures_folder already exists")
    else
        mkpath(log_folder)
    end

    @debug "Create pars db"
    pars_db = PropDict()
    # read params if exist
    if !(haskey(l200.par[:cal, :energy], Symbol(period)))
        # path folder for current period seems not to exist, will create it first to avoid errors
        mkpath(joinpath(l200.tier[:par, :cal], "energy", "$period"))
    elseif haskey(l200.par[:cal, :energy, period], Symbol(run))
        @info "Pars file already exists."
        pars_db = l200.par[:cal, :energy, period, run]
    end

    if reprocess
        @info "Reprocess all channels"
        for det in keys(pars_db)
            for e_type in keys(pars_db[det])
                pars_db[det][e_type].ctc = nothing
            end
        end
        PropDicts.trim_null!(pars_db)
    else
        @info "Only reprocess channels that are not in pars_db"
    end

    # move all variables to workers
    @everywhere begin
        l200 = $l200
        sel = $sel
        filekey = $filekey
        filekeys = $filekeys
        chinfo = $chinfo
        figures_folder = $figures_folder
        hit_folder = $hit_folder
        pars_db = $pars_db
        reprocess = $reprocess
    end

    # for (i, ch_short) in enumerate(chinfo.channel)
    @everywhere function ch_ct_correction(i::Int64)

        ch_short = chinfo.channel[i]
        ch = format("ch{}", ch_short)
        string_number = chinfo.string[i]
        det = chinfo.detector[i]

        figures_folder_string = joinpath(figures_folder, format("string{:02d}", string_number))

        @debug "Processing channel $ch ($det)"

        result_dict    = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, String}()

        if haskey(l200.metadata.dataprod.config.cal.energy(sel), det)
            energy_config = merge(l200.metadata.dataprod.config.cal.energy(sel).default, l200.metadata.dataprod.config.cal.energy(sel)[det])
            @debug "Use config for detector $det"
        else
            energy_config = l200.metadata.dataprod.config.cal.energy(sel).default
            @debug "Use default config"
        end

        energy_types = Symbol.(energy_config.energy_types)

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(chinfo.detector[i]) already processed, check missing energy types"
            for e_type in energy_types
                if haskey(pars_db[det], e_type) && haskey(pars_db[det][e_type], :ctc)
                    log_info = "| $ch | $det | Success | $e_type | $(round(pars_db[det][e_type].ctc.fct*1e6, digits=2))E-6 | $(round(ustrip(pars_db[det][e_type].ctc.fwhm_before), digits=2))±$(round(ustrip(pars_db[det][e_type].ctc.err.fwhm_before), digits=2)) | $(round(ustrip(pars_db[det][e_type].ctc.fwhm_after), digits=2))±$(round(ustrip(pars_db[det][e_type].ctc.err.fwhm_after), digits=2)) | Already processed --> skipped. |"
                    result_dict[e_type] = NamedTuple()
                    log_info_dict[e_type] = log_info
                end
            end
        end

        ch_filekeys = Vector{FileKey}()
        for fk in filekeys
            if !isfile(l200.tier[:dsp, fk])
                @warn "File $(basename(l200.tier[:dsp, fk])) does not exist, skip"
                continue
            end
            if !haskey(LHDataStore(l200.tier[:dsp, fk], "r"), ch)
                @warn "Channel $ch not found in $(basename(l200.tier[:dsp, fk])), skip"
                continue
            end
            push!(ch_filekeys, fk)
        end

        if isempty(ch_filekeys)
            @error "No valid filekeys found for channel $ch ($det), skip"
            throw(LoadError("$det", 154,"No filekeys found for channel $ch ($det)"))
        end
        yield()

        data_ch = fast_flatten([
            LHDataStore(
                ds -> begin
                    # @debug "Reading from \"$(ds.data_store.filename)\""
                    ds[ch][:]
                end,
                l200.tier[:dsp, fk]
            ) for fk in ch_filekeys
        ])
        yield()

        if length(data_ch) < 50000
            @error "Not enough data points for channel $ch ($det), skip"
            throw(ErrorException("Not enough data points for channel $ch ($det)"))
        end

        if haskey(l200.metadata.dataprod.config.cal.qc(sel), det)
            qc_config = merge(l200.metadata.dataprod.config.cal.qc(sel).default, l200.metadata.dataprod.config.cal.qc(sel)[det])
            @debug "Use config for detector $det"
        else
            qc_config = l200.metadata.dataprod.config.cal.qc(sel).default
            @debug "Use default config"
        end
        yield()

        th228_lines = Vector{Float64}(energy_config.th228_lines)
        th228_names = Symbol.(energy_config.th228_names)
        th228_names_dict  = Dict{Float64, Symbol}(th228_lines .=> Symbol.(energy_config.th228_names))
        window_sizes = Vector{Tuple{Float64, Float64}}([(l,r) for (l,r) in zip(Vector{Float64}(energy_config.left_window_sizes), Vector{Float64}(energy_config.right_window_sizes))])
        n_bins = energy_config.n_bins
        quantile_perc = nothing
        if !(energy_config.quantile_perc isa Number)
            quantile_perc = parse(Float64, energy_config.quantile_perc)
        else
            quantile_perc = energy_config.quantile_perc
        end
        # get special config for CTC
        ctc_cal_peak = Float64(energy_config.ctc.peak)
        ctc_cal_window = (Float64(energy_config.ctc.left_window_size),Float64(energy_config.ctc.right_window_size))

        # generate qc cuts
        qc, data_ch_after_qc = nothing, nothing
        try
            @debug "Get QC cuts"
            qc = qc_cal_energy(data_ch, qc_config)
            @debug "Total surrival fraction: $(round(count(qc) / length(data_ch) * 100, digits=2))%"
            data_ch_after_qc =  data_ch[qc]
        catch e
            @error "Error in QC for channel $ch: $e"
            throw(ErrorException("Error in QC cut generation: $e"))
        end
        yield()

        for e_type in energy_types
            if haskey(result_dict, e_type)
                continue
            end
            
            try
                @debug "Correct $e_type"

                result_simple, report_simple = nothing, nothing
                try
                    @debug "Get $e_type simple calibration"
                    result_simple, report_simple = simple_calibration(getproperty(data_ch_after_qc, e_type), th228_lines, window_sizes,; n_bins=n_bins, quantile_perc=quantile_perc)
                catch e
                    @error "Error in $e_type simple calibration for channel $ch: $e"
                    throw(ErrorException("Error in $e_type simple calibration"))
                end

                # get simple calibration constant
                m_cal_simple = result_simple.c
                # save plots for simple calibration for control
                plot(report_simple, margin=5mm, yformatter=:plain, thickness_scaling=1.5, cal=true, title=format("{} Simple Calibration ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
                savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-simple_calibration_{}.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch, string(e_type))))

                yield()

                result_ctc, report_ctc = nothing, nothing
                try
                    @debug "Get $e_type Charge Trapping Alpha"
                    result_ctc, report_ctc = ctc_energy(getproperty(data_ch_after_qc, e_type) .* m_cal_simple, data_ch_after_qc.qdrift, ctc_cal_peak, ctc_cal_window)
                catch e
                    @error "Error in $e_type alpha generation $ch: $e"
                    throw(ErrorException("Error in $e_type alpha generation"))
                end
                @debug "Found Best $e_type FWHM: $(round(result_ctc.fwhm_after, digits=2)) +- $(round(result_ctc.err.fwhm_after, digits=2))keV"
                @debug "Found $e_type FCT: $(round(result_ctc.fct*1e6, digits=2))E-6"
                
                plot(report_ctc, plot_title=format("{} {}keV Charge Trapping Correction ({}-{}-{}-{})", string(det), string(ctc_cal_peak), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
                savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-ctc_{}.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch, string(e_type))))

                yield()

                result = (
                    fct = result_ctc.fct / m_cal_simple,
                    fwhm_before = result_ctc.fwhm_before,
                    fwhm_after = result_ctc.fwhm_after,
                    peak = ctc_cal_peak,
                    err = (fwhm_before = result_ctc.err.fwhm_before, fwhm_after = result_ctc.err.fwhm_after)
                )
                log_info = "| $ch | $det | Success | $e_type | $(round(ustrip(result.fct*1e6), digits=2))E-6 | $(round(ustrip(result.fwhm_before), digits=2))±$(round(ustrip(result.err.fwhm_before), digits=2)) | $(round(ustrip(result.fwhm_after), digits=2))±$(round(ustrip(result.err.fwhm_after), digits=2)) | - |"

                # add results to dict
                result_dict[e_type]   = result
                log_info_dict[e_type] = log_info
            catch e
                @error "Error in $e_type CT correction: $e"
                log_info = "| ch$(chinfo.channel[i]) | $(chinfo.detector[i]) | Failed | $e_type | - | - | - | $(e) |"
                # add results to dict
                result_dict[e_type] = NamedTuple()
                log_info_dict[e_type] = log_info
            end
        end

        return (result = result_dict, log = log_info_dict)
    end

    Base.exit_on_sigint(false)
    result_ctc = pmap(eachindex(chinfo.channel); on_error = e->(isa(e, ProcessExitedException) ? NaN : rethrow())) do idx
        try
            t_end = time() + timeout
            task = Threads.@spawn ch_ct_correction(idx)
            while !istaskdone(task) && time() <= t_end
                sleep(0.1)
            end
            if !istaskdone(task)
                @debug "Timeout for $(chinfo.detector[idx])"
                try
                    Base.throwto(task, InterruptException())
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
            @debug "Write Error log for $(chinfo.detector[idx]): $(e)"
            log_info = "| ch$(chinfo.channel[idx]) | $(chinfo.detector[idx]) | Failed | ? | - | - | - | $(e) |"
            chinfo.detector[idx] => (result = Dict{Symbol, NamedTuple}(), log = log_info)
        end
    end

    @info "Finished CT correction"
    @info "Remove all workers"
    rmprocs(workers()...)

    main_log = """# Main log
    Time of processing: $(now())
    ## CT Correction
    This is the log for the charge trapping correction. The algorithm loads all data for a channel and performs the correction while optimizing maximum height and FWHM of a defined peak in the energy spectrum.
    Before the parameters are extracted, QC cuts are applied to increase the quality of the data.
    # MetaData
    | Setup | Period | Run | Category |
    |-------|--------|-----|----------|
    | $(filekey.setup) | $(filekey.period) | $(filekey.run) | $(filekey.category) |

    # Results
    | Channel | Detector | Status | Energy | FCT | FWHM Before (keV) | FWHM After (keV) | Error |
    |---------|----------|--------|--------|-----|-------------------|------------------|-------|
    """
    # extract results into pars_db and append to main log
    for (det, res) in result_ctc
        # save pars to db
        if !isempty(res.result)
            pars_det = pars_db[det]
            for (e_type, res_e_type) in res.result
                if isempty(res_e_type)
                    continue
                end
                pars_det_e_type = pars_det[e_type].ctc
                # save calibration results
                pars_det_e_type.fct             = res_e_type.fct
                pars_det_e_type.fwhm_before     = res_e_type.fwhm_before
                pars_det_e_type.fwhm_after      = res_e_type.fwhm_after
                pars_det_e_type.peak            = res_e_type.peak
                pars_det_e_type.err.fwhm_before = res_e_type.err.fwhm_before
                pars_det_e_type.err.fwhm_after  = res_e_type.err.fwhm_after
            end
            for (e_type, log_info) in res.log
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
            # main_log *= res.log
        end
    end
    # save pars to disk
    @info "Save pars to disk"

    # write pars
    writeprops(joinpath(l200.tier[:par, :cal], "energy", "$period/$run.json"), pars_db, multiline=true)

    # write validity
    pars_validTimeStamp = string(filekey.time)
    add_validity = true
    for ln in eachline(open(joinpath(l200.tier[:par, :cal], "energy", "validity.jsonl"), "r"))
        if (contains(ln, "$pars_validTimeStamp"))
            add_validity = false
        end
    end
    if add_validity
        open(joinpath(l200.tier[:par, :cal], "energy", "validity.jsonl"), "a") do io
            println(io, "{\"valid_from\":\"$pars_validTimeStamp\", \"category\":\"all\", \"apply\":[\"$period/$run.json\"]}")
        end
    end

    @info "Write main log to disk"
    @info main_log

    log_filename = joinpath(log_folder, format("{}-{}-{}-{}-ct_correction.md", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
    open(log_filename, "w+") do file
        write(file, replace(main_log, "Success" => raw"$${\color{green}Success}$$", "Failed" => raw"$${\color{red}Failed}$$"))
    end
end