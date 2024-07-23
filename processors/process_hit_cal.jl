function process_hit_cal(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Union{Int, Bool}=false)

    @info "Generate cal hit for period $period and run $run"

    filekeys = search_disk(FileKey, l200.tier[:jldsp, :cal, period, run])

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) channels"

    qc_config = dataprod_config(l200).qc(filekey)

    @debug "Create Hit folder"
    mkpath(l200.tier[:jlhitch, :cal, period, run])
    mkpath(l200.tier[:jlpulsch, :cal, period, run])

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.qc), string(period)))
    pars_db = PropDict(l200.par.rpars.qc[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" end

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Status, Symbol("Surrival Fraction"), Symbol("Number Pulser Events"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    # write out pulser events
    chinfo_puls = channelinfo(l200, filekey, Symbol(qc_config.pulser.puls_channel))
    onworker(; tries=1, label="Pulser") do
        # get pulser filename
        pulserfilename = l200.tier[:jlpulsch, filekey, chinfo_puls.channel]

        if !reprocess && isfile(pulserfilename)
            return
        end
        @info "Get pulser events from raw data"
        data_puls = load_runch(lh5open, fast_flatten, l200, filekey, :raw, chinfo_puls.channel; check_filekeys=true, keys=(:daqenergy, :timestamp))
        @info "Write Pulser events to disk"
        touch(pulserfilename)
        modify_files(pulserfilename, use_cache=true) do outfilename
            lh5open(outfilename, "w") do outdata
                @info "Save Pulser Tags"
                outdata[chinfo_puls.channel, :jlpuls] = data_puls;
            end
        end
        return 
    end

    function ch_hit_cal(chinfo_ch::NamedTuple)

        ch = chinfo_ch.channel
        det = chinfo_ch.detector

        hitchfilename = l200.tier[:jlhitch, filekey, ch]
        pulserfilename = l200.tier[:jlpulsch, filekey, chinfo_puls.channel]

        if !reprocess && haskey(pars_db, det) && isfile(hitchfilename)
            log_ch = log_nt((ch, det, ProcessStatus(1), pars_db[det].sf, pars_db[det].n_pulser, "-"))
            try
                close(lh5open(hitchfilename, "r"))
                @debug "Channel $(det) already processed"
                return (processed = true, log = log_ch)
            catch e
                @warn "Error reading hit file for channel $ch ($det): $(truncate_string(string(e)))"
                @info "Reprocess channel $ch ($det)"
                rm(hitchfilename)
            end
        end

        if reprocess @info "Overwrite old hit file" end

        @debug "Processing channel $ch ($det)"
        
        data_ch = load_runch(lh5open, fast_flatten, l200, filekeys, :jldsp, ch; check_filekeys=true)
        
        if length(data_ch) < 5000
            @error "Not enough data points for channel $ch ($det), skip"
            throw(ErrorException("Not enough data points for channel $ch ($det)"))
        end

        qc_config_ch = merge(qc_config.default, get(qc_config, det, PropDict()))
        pulser_config_ch = merge(qc_config.pulser.default, get(qc_config.pulser, det, PropDict()))

        # generate qc cuts
        qc, is_physical, result_qc, report_qc = nothing, nothing, nothing, nothing
        try
            @debug "Get QC cuts"
            # result_qc, report_qc  = baseline_qc(data_ch, qc_config_ch)
            qc = Table(ljl_propfunc(qc_config_ch.labels).(data_ch))
            is_physical = ljl_propfunc(qc_config_ch.is_physical).(qc)
            @debug "Total surrival fraction: $(round(count(is_physical) / length(is_physical) * 100, digits=2))%"
        catch e
            @error "Error in QC for channel $ch: $(truncate_string(string(e)))"
            throw(ErrorException("Error in QC cut generation: $(truncate_string(string(e)))"))
        end
        yield()

        # for k in keys(report_qc)
        #     p = plot(report_qc[k])
        #     plot!(p, xlabel=string(k), title=get_plottitle(filekey, det, string(k)))
        #     savelfig(savefig, p, l200, filekey, ch, k)
        # end

        is_pulser = nothing
        try
            @debug "Get Pulser tags"
            # pulser_tag = pulser_cal_qc(data_ch, pulser_config_ch; n_pulser_identified=100)
            data_pulser = lh5open(pulserfilename)[chinfo_puls.channel].jlpuls[:]
            is_pulser = flag_coincidences(data_ch.timestamp, data_pulser.timestamp, ts_window = pulser_config_ch.puls_ts_window)
            @debug "Found $(count(is_pulser)) pulser events"
        catch e
            @error "Error in Pulser tag for channel $ch: $(truncate_string(string(e)))"
            throw(ErrorException("Error in Pulser tag for channel: $(truncate_string(string(e)))"))
        end

        data_ch_after_qc = data_ch[is_physical .&& .!is_pulser]
        data_pulser = data_ch[is_physical .&& is_pulser]

        p = stephist(data_ch_after_qc.e_trap, bins=0:8*15:maximum(data_ch_after_qc.e_trap), label="Trap - after QC", yscale=:log10)
        stephist!(p, data_ch.e_trap, bins=0:8*15:maximum(data_ch_after_qc.e_trap), label="Trap - before QC", yscale=:log10)
        stephist!(p, data_pulser.e_trap, bins=0:8*15:maximum(data_ch_after_qc.e_trap), label="Pulser", yscale=:log10)
        plot!(p, xlabel="Energy (ADC)", ylabel="Counts", title=get_plottitle(filekey, det, "Trap Raw Energy Spectrum"))
        plot!(p, xformatter=:plain, legend=:topright, framestyle=:box, xticks=0:20e3:200e3, thickness_scaling=1.7)

        savelfig(savefig, p, l200, filekey, ch, :raw_energy_e_trap)

        # save hit file
        @debug "Save hit file"
        touch(hitchfilename)
        modify_files(hitchfilename, use_cache=true) do outfilename
            lh5open(outfilename, "w") do outdata
                @info "Save QC"
                outdata[ch, :jlhit, :qc] = Table(merge(columns(qc), (is_physical = is_physical,)));
                @info "Save Pulser Tags"
                outdata[ch, :jlhit, :pulserTag] = is_pulser;
                @info "Save data after QC"
                outdata[ch, :jlhit, :dataQC] = data_ch_after_qc;
                @info "Save data pulser"
                outdata[ch, :jlhit, :dataPulser] = data_pulser;
            end
        end

        sf, n_pulser = count(is_physical) / length(is_physical) * 100u"percent", ifelse(!isempty(data_pulser), length(data_pulser), 0)
        log_ch = log_nt((ch, det, ProcessStatus(1), sf, n_pulser, "-"))


        for cut in columnnames(qc)
            @info "SF: $(cut) cut: $(count(getproperty(qc, cut)) / length(qc) * 100u"percent")"
        end

        # return (result = (sf = sf, n_pulser = n_pulser, baseline = result_qc), log = log_ch, processed=true)
        return (result = (sf = sf, n_pulser = n_pulser), log = log_ch, processed=true)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_qc = parallel(chinfo, ch_hit_cal, log_nt, wpool; timeout=timeout)

    @info "Finished Hit channel processing"

    pars_db = create_pars(pars_db, result_qc)
    writelprops(l200.par.rpars.qc[period], run, pars_db)
    writevalidity(l200.par.rpars.qc, filekey, (period, run); apply_to=:cal)
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
    writelreport(get_rreportfilename(l200, filekey, :qc), report)
    @info report

    # flush stdout
    flush(stdout)
end