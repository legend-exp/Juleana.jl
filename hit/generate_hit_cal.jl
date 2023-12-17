function process_hit_cal(l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=300)

    @info "Generate cal hit for period $period and run $run"

    filekeys = sort(search_disk(FileKey, l200.tier[:dsp, :cal, period, run]), by = x-> x.time)
    filekey = filekeys[1]
    @info "Found filekey $filekey"

    chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable && $usability != :off)

    sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)

    @debug "Create Hit folder"
    hit_folder = l200.tier[:hit_ch, :cal, period, run]
    if isdir(hit_folder)
        @debug("Hit folder $hit_folder already exists")
    else
        mkpath(hit_folder)
    end

    @debug "Create figures folder"
    figures_folder = joinpath(l200.tier[:plt, :cal, period, run], "qc")
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
    if !(haskey(l200.par[:cal, :qc], Symbol(period)))
        # path folder for current period seems not to exist, will create it first to avoid errors
        mkpath(joinpath(l200.tier[:par, :cal], "qc", "$period"))
    elseif haskey(l200.par[:cal, :qc, period], Symbol(run))
        @info "Pars file already exists."
        pars_db = l200.par[:cal, :qc, period, run]
    end

    if reprocess
        @info "Reprocess all channels"
        for det in keys(pars_db)
            if !haskey(pars_db[det], :cal)
                pars_db[det].cal = nothing
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
        reprocess = $reprocess
        figures_folder = $figures_folder
        hit_folder = $hit_folder
        pars_db = $pars_db
    end

    # for (i, ch_short) in enumerate(chinfo.channel)
    @everywhere function ch_hit_cal(i::Int64)

        ch_short = chinfo.channel[i]
        ch = format("ch{}", ch_short)
        string_number = chinfo.string[i]
        det = chinfo.detector[i]

        figures_folder_string = joinpath(figures_folder, format("string{:02d}", string_number))

        hitchfilename = joinpath(hit_folder, format("{}-{}-{}-{}-{}-tier_hit.lh5", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch))

        if !reprocess && haskey(pars_db, det) && haskey(pars_db[det], :cal)
            @debug "Channel $(chinfo.detector[i]) already processed"
            log_info = "| $ch | $det | Success | $(round(pars_db[det].cal.qc * 100, digits=2))% | Already processed --> skipped. |"
            result_dict = Dict{Symbol, Float64}()
            return (result = result_dict, log = log_info)
        end

        if reprocess
            @info "Remove old hit file"
            if isfile(hitchfilename)
                rm(hitchfilename)
            end
        end

        @debug "Processing channel $ch ($det)"
        

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

        if length(data_ch) < 5000
            @error "Not enough data points for channel $ch ($det), skip"
            throw(ErrorException("Not enough data points for channel $ch ($det)"))
        end

        if haskey(l200.metadata.dataprod.config.qc(sel), det)
            qc_config = merge(l200.metadata.dataprod.config.qc(sel).default, l200.metadata.dataprod.config.qc(sel)[det])
            @debug "Use config for detector $det"
        else
            qc_config = l200.metadata.dataprod.config.qc(sel).default
            @debug "Use default config"
        end
        yield()

        # generate qc cuts
        qc, data_ch_after_qc = nothing, nothing
        try
            @debug "Get QC cuts"
            qc = qc_cal_energy(data_ch, qc_config)
            @debug "Total surrival fraction: $(round(count(qc.qc) / length(data_ch) * 100, digits=2))%"
            data_ch_after_qc =  data_ch[qc.qc]
        catch e
            @error "Error in QC for channel $ch: $e"
            throw(ErrorException("Error in QC cut generation: $e"))
        end
        yield()

        histogram(data_ch_after_qc.e_trap, bins=0:15:maximum(data_ch_after_qc.e_trap), label="Trap - after QC", xlabel="Energy (ADC)", ylabel="Counts", title="Energy spectrum for channel $ch ($det)", legend=:topleft)
        histogram!(data_ch.e_trap, bins=0:15:maximum(data_ch_after_qc.e_trap), label="Trap - before QC")
        savefig(joinpath(figures_folder_string,  format("{}-{}-{}-{}-{}-raw_energy_e_trap.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

        # save hit file
        @debug "Save hit file"
        outdata = LHDataStore(hitchfilename, "cw")
        outdata["$ch/qc"] = qc;
        outdata["$ch/dataQC"] = data_ch_after_qc;
        close(outdata)

        log_info = "| $ch | $det | Success | $(round(count(qc.qc) / length(data_ch) * 100, digits=2))% | - |"

        result_dict = Dict{Symbol, Float64}()

        for cut in columnnames(qc)
            @info "$(cut) cut: $(round(count(getproperty(qc, cut)) / length(qc) * 100, digits=2))%"
            result_dict[cut] = round(count(getproperty(qc, cut)) / length(qc) * 100, digits=2)
        end

        return (result = result_dict, log = log_info)
    end

    Base.exit_on_sigint(false)
    result_ctc =  @showprogress pmap(eachindex(chinfo.channel); batch_size = 1, retry_check=retry_check, retry_delays=ExponentialBackOff(n=3)) do idx
        try
            t_end = time() + timeout
            task = Threads.@spawn ch_hit_cal(idx)
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
            log_info = "| ch$(chinfo.channel[idx]) | $(chinfo.detector[idx]) | Failed | - | $(e) |"
            chinfo.detector[idx] => (result = Dict{Symbol, Float64}(), log = log_info)
        end
    end

    @info "Finished Hit channel processing"    
    @info "Remove all workers"
    rmprocs(workers()...)

    main_log = """# Main log
    Time of processing: $(now())
    ## QC Cal generation
    This is the log for the qualtiy cuts generation for calibration data. The algorithm generates the QC cuts and saves a hit file per detector
    for the following processing.
    # MetaData
    | Setup | Period | Run | Category |
    |-------|--------|-----|----------|
    | $(filekey.setup) | $(filekey.period) | $(filekey.run) | $(filekey.category) |

    # Results
    | Channel | Detector | Status | QC SF | Error |
    |---------|----------|--------|-------|-------|
    """
    # extract results into pars_db and append to main log
    for (det, res) in result_ctc
        # save pars to db
        if !isempty(res.result)
            pars_det = pars_db[det].cal
            for (cut, cut_sf) in res.result
                pars_det[cut].sf = cut_sf
            end
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
    writeprops(joinpath(l200.tier[:par, :cal], "qc", "$period/$run.json"), pars_db, multiline=true)

    # write validity
    pars_validTimeStamp = string(filekey.time)
    add_validity = true
    for ln in eachline(open(joinpath(l200.tier[:par, :cal], "qc", "validity.jsonl"), "r"))
        if (contains(ln, "$pars_validTimeStamp"))
            add_validity = false
        end
    end
    if add_validity
        open(joinpath(l200.tier[:par, :cal], "qc", "validity.jsonl"), "a") do io
            println(io, "{\"valid_from\":\"$pars_validTimeStamp\", \"category\":\"cal\", \"apply\":[\"$period/$run.json\"]}")
        end
    end

    @info "Write main log to disk"
    @info main_log

    log_filename = joinpath(log_folder, format("{}-{}-{}-{}-qc.md", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
    open(log_filename, "w+") do file
        write(file, replace(main_log, "Success" => raw"$${\color{green}Success}$$", "Failed" => raw"$${\color{red}Failed}$$"))
    end
end