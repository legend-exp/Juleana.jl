function process_hit_cal(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Union{Int, Bool}=false)

    @info "Generate cal hit for period $period and run $run"

    filekeys = search_disk(FileKey, l200.tier[:jldsp, :cal, period, run])

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = Table(channelinfo(l200, filekey; system=:geds, only_processable=true))
    @info "Loaded channel info with $(length(chinfo)) channels"

    qc_config = dataprod_config(l200).qc(filekey)

    @debug "Create Hit folder"
    mkpath(l200.tier[:jlhitch, :cal, period, run])

    @debug "Create pars db"
    mkpath(data_path(l200.par.rpars.qc[period]))
    pars_db = PropDict(l200.par.rpars.qc[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" end

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Status, Symbol("Surrival Fraction"), Symbol("Number Pulser Events"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    function ch_hit_cal(chinfo_ch::NamedTuple)

        ch = chinfo_ch.channel
        det = chinfo_ch.detector

        hitchfilename = get_hitchfilename(l200, filekey, ch)

        if !reprocess && haskey(pars_db, det) && isfile(hitchfilename)
            log_ch = log_nt((ch, det, ProcessStatus(1), pars_db[det].sf, pars_db[det].n_pulser, "-"))
            try
                close(lh5open(hitchfilename, "r"))
                @debug "Channel $(det) already processed"
                return (processed = true, log = log_ch)
            catch e
                @warn "Error reading hit file for channel $ch ($det): $e"
                @info "Reprocess channel $ch ($det)"
                rm(hitchfilename)
            end
        end

        if reprocess
            @info "Remove old hit file"
            if isfile(hitchfilename)
                rm(hitchfilename)
            end
        end

        @debug "Processing channel $ch ($det)"
        
        data_ch = load_runch(lh5open, fast_flatten, l200, filekeys, :jldsp, ch; check_filekeys=true)
        
        if length(data_ch) < 5000
            @error "Not enough data points for channel $ch ($det), skip"
            throw(ErrorException("Not enough data points for channel $ch ($det)"))
        end

        qc_config_ch = merge(qc_config.default, get(qc_config, det, PropDict()))
        pulser_config_ch = merge(qc_config.pulser.default, get(qc_config.pulser, det, PropDict()))

        # generate qc cuts
        qc, data_ch_after_qc, cut_res = nothing, nothing, nothing
        try
            @debug "Get QC cuts"
            qc, cut_res = qc_cal_energy(data_ch, qc_config_ch)
            @debug "Total surrival fraction: $(round(count(qc.qc) / length(data_ch) * 100, digits=2))%"
            data_ch_after_qc =  data_ch[qc.qc]
        catch e
            @error "Error in QC for channel $ch: $e"
            throw(ErrorException("Error in QC cut generation: $e"))
        end
        yield()

        pulser_tag, data_pulser = nothing, nothing
        try
            @debug "Get Pulser tags"
            pulser_tag = pulser_cal_qc(data_ch, pulser_config_ch; n_pulser_identified=100)
            @debug "Found $(length(pulser_tag)) pulser events"
            data_pulser = data_ch[pulser_tag]
            data_ch_after_qc = data_ch[findall(x -> !(x in pulser_tag) && qc.qc[x], eachindex(data_ch))]
        catch e
            @error "Error in Pulser tag for channel $ch: $e"
            throw(ErrorException("Error in Pulser tag for channel: $e"))
        end

        p = stephist(data_ch_after_qc.e_trap, bins=0:15:maximum(data_ch_after_qc.e_trap), label="Trap - after QC", yscale=:log10)
        stephist!(p, data_ch.e_trap, bins=0:15:maximum(data_ch_after_qc.e_trap), label="Trap - before QC", yscale=:log10)
        if !isempty(data_pulser)
            stephist!(p, data_pulser.e_trap, bins=0:15:maximum(data_ch_after_qc.e_trap), label="Pulser", yscale=:log10)
        end
        plot!(p, xformatter=:plain, xlabel="Energy (ADC)", ylabel="Counts", title=get_plottitle(filekey, det, "Trap Raw Energy Spectrum"), legend=:topright)

        savelfig(savefig, p, l200, filekey, ch, :raw_energy_e_trap)

        # save hit file
        @debug "Save hit file"
        rm(hitchfilename, force=true)
        lh5open(hitchfilename, "cw") do outdata
            @info "Save QC"
            outdata["$ch/qc"] = qc;
            @info "Save Pulser Tags"
            outdata["$ch/pulserTag"] = pulser_tag;
            @info "Save data after QC"
            outdata["$ch/dataQC"] = data_ch_after_qc;
            @info "Save data pulser"
            if !isempty(data_pulser)
                outdata["$ch/dataPulser"] = data_pulser;
            else
                @error "No Pulser data written out!"
            end
        end

        sf, n_pulser = count(qc.qc) / length(data_ch) * 100u"percent", ifelse(!isempty(data_pulser), length(data_pulser), 0)
        log_ch = log_nt((ch, det, ProcessStatus(1), sf, n_pulser, "-"))


        for cut in columnnames(qc)
            @info "$(cut) cut: $(count(getproperty(qc, cut)) / length(qc) * 100u"percent")"
        end

        return (result = (sf = sf, n_pulser = n_pulser, cuts = cut_res), log = log_ch, processed=true)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_qc = parallel(chinfo, ch_hit_cal, log_nt, wpool; timeout=timeout)

    @info "Finished Hit channel processing"

    pars_db = create_pars(pars_db, result_qc)
    writelprops(l200.par.rpars.qc[period], run, pars_db)
    writevalidity(l200.par.rpars.qc, filekey; apply_to=:cal)
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, hit_cal_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_qc))


    @info "Write log report"
    writelreport(get_reportfilename(l200, filekey, :qc), report)
    @info report

    # flush stdout
    flush(stdout)
end