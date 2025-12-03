function process_hit_cal(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)

    @info "Generate cal hit for period $period and run $run"

    filekeys = search_disk(FileKey, l200.tier[:jldsp, :cal, period, run])

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) channels"

    qc_config = dataprod_config(l200).qc(filekey)
    @debug "Loaded QC config: $(qc_config)"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.qc), string(period)))
    pars_db = PropDict(l200.par.rpars.qc[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :Channel, :Status, Symbol("Survival Fraction"), Symbol("Number Pulser Events"), :Error)}
    log_nt_puls = NamedTuple{(:Detector, :Channel, :Status, Symbol("Number Pulser Events"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    function resolve_data_key(ds, ch::ChannelIdLike, det::DetectorIdLike)
        det_key = string(det)
        ch_key = string(ch)
        if haskey(ds, det_key)
            return det_key
        elseif haskey(ds, ch_key)
            return ch_key
        else
            return nothing
        end
    end

    function ensure_data_key(ds, ch::ChannelIdLike, det::DetectorIdLike)
        data_key = resolve_data_key(ds, ch, det)
        if data_key === nothing
            det_label = string(det)
            ch_label = string(ch)
            throw(ErrorException("Channel $(det_label) ($(ch_label)) not found in \"$(basename(ds.data_store.filename))\""))
        end
        return data_key
    end

    # write out pulser events
    chinfo_puls = channelinfo(l200, filekey, Symbol(qc_config.pulser.puls_channel))
    @info "Loaded pulser channel info: $(chinfo_puls)"

    function pulser_filenames(l200::LegendData, filekey, ch::ChannelIdLike, det::DetectorIdLike)
        channel_path = l200.tier[:jlpls, filekey, ch]
        det_label = string(det)
        if occursin(det_label, channel_path)
            return channel_path, channel_path
        end
        ch_label = string(ch)
        base = basename(channel_path)
        new_base = occursin(ch_label, base) ? replace(base, ch_label => det_label) : replace(base, "-tier_jlpls" => "-$(det_label)-tier_jlpls")
        new_path = joinpath(dirname(channel_path), new_base)
        return new_path, channel_path
    end

    # get information about pulser events from raw trigger
    function ch_puls_cal(chinfo_puls::NamedTuple)
        
        ch_puls = chinfo_puls.channel
        det_puls = chinfo_puls.detector
        
        det_label_puls = string(det_puls)
        pulserfilename, legacyfilename = pulser_filenames(l200, filekey, ch_puls, det_puls)

        if pulserfilename != legacyfilename && !isfile(pulserfilename) && isfile(legacyfilename)
            mkpath(dirname(pulserfilename))
            mv(legacyfilename, pulserfilename; force=true)
            @info "Moved legacy pulser file $(basename(legacyfilename)) to detector path $(basename(pulserfilename))"
        end

        if !reprocess && isfile(pulserfilename)
            n_tags = try
                lh5open(pulserfilename, "r") do ds
                    key = ensure_data_key(ds, ch_puls, det_puls)
                    length(ds[key, :jlpls, :tags])
                end
            catch e
                @warn "Error reading pulser file for $det_puls ($ch_puls): $(truncate_error(e))"
                nothing
            end
            return (processed = false, log = log_nt_puls((det_puls, ch_puls, ProcessStatus(1), something(n_tags, 0), "Already processed --> skipped.")))
        end
        # extract pulser events by loading data from raw files
        @info "Get pulser events from raw data"
        data_puls = read_ldata((:daqenergy, :timestamp), l200, DataTier(:raw), DataCategory(:cal), period, run, ch_puls)
        
        @info "Write Pulser events to disk"
        write_files(pulserfilename, use_cache=true, mode = CreateOrReplace()) do outfilename
            lh5open(outfilename, "w") do outdata
                @info "Save Pulser Tags"
                outdata[det_label_puls, :jlpls, :tags] = data_puls;
            end
        end
        return (processed = false, log = log_nt_puls((det_puls, ch_puls, ProcessStatus(1), length(data_puls), "Already processed --> skipped.")))
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_puls = parallel([chinfo_puls], ch_puls_cal, log_nt_puls, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished Pulser channel processing"
    pulser_processing_time = now() - start_time

    # generate hit cal files
    function ch_hit_cal(chinfo_ch::NamedTuple)

        ch = chinfo_ch.channel
        det = chinfo_ch.detector

        ch_puls = chinfo_puls.channel
        det_puls = chinfo_puls.detector

        det_label = string(det)
        det_label_puls = string(det_puls)

        hitchfilename = l200.tier[:jlhit, filekey, det]
        pulserfilename, legacyfilename = pulser_filenames(l200, filekey, ch_puls, det_puls)

        if pulserfilename != legacyfilename && !isfile(pulserfilename) && isfile(legacyfilename)
            mkpath(dirname(pulserfilename))
            mv(legacyfilename, pulserfilename; force=true)
            @info "Moved legacy pulser file $(basename(legacyfilename)) to detector path $(basename(pulserfilename))"
        end

        if !reprocess && haskey(pars_db, det) && isfile(hitchfilename)
            log_ch = log_nt((det, ch, ProcessStatus(1), pars_db[det].sf, pars_db[det].n_pulser, "Already processed --> skipped."))
            try
                close(lh5open(hitchfilename, "r"))
                @debug "Channel $(det) already processed"
                return (processed = true, log = log_ch)
            catch e
                @warn "Error reading hit file for channel $ch ($det): $(truncate_error(e))"
                @info "Reprocess channel $ch ($det)"
                rm(hitchfilename)
            end
        end

        if reprocess @info "Overwrite old hit file" end

        @debug "Processing channel $ch ($det)"
        
        # Load DSP data: try det name first, fallback to channel id
        data_ch = read_ldata(l200, DataTier(:jldsp), filekeys, det)
        
        if length(data_ch) < 5000
            @error "Not enough data points for channel $ch ($det), skip"
            throw(ErrorException("Not enough data points for channel $ch ($det)"))
        end

        qc_config_ch = merge(qc_config.default, get(qc_config, det, PropDict()))
        pulser_config_ch = merge(qc_config.pulser.default, get(qc_config.pulser, det, PropDict()))

        # generate qc cuts
        qc, is_physical = nothing, nothing
        try
            @debug "Get QC cuts"
            # result_qc, report_qc  = baseline_qc(data_ch, qc_config_ch)
            qc = Table(ljl_propfunc(qc_config_ch.labels).(data_ch))
            is_physical = ljl_propfunc(qc_config_ch.is_physical).(qc)
            @debug "Total survival fraction: $(round(count(is_physical) / length(is_physical) * 100, digits=2))%"
        catch e
            @error "Error in QC for channel $ch: $(truncate_error(e))"
            throw(ErrorException("Error in QC cut generation: $(truncate_error(e))"))
        end
        yield()

        is_pulser = nothing
        try
            @debug "Get Pulser tags"
            # pulser_tag = pulser_cal_qc(data_ch, pulser_config_ch; n_pulser_identified=100)
            data_pulser = lh5open(pulserfilename) do ds
                key = ensure_data_key(ds, ch_puls, det_puls)
                ds[key, :jlpls, :tags][:]
            end
            is_pulser = flag_coincidences(data_ch.timestamp, data_pulser.timestamp, ts_window = pulser_config_ch.puls_ts_window)
            @debug "Found $(count(is_pulser)) pulser events"
        catch e
            @error "Error in Pulser tag for channel $ch: $(truncate_error(e))"
            throw(ErrorException("Error in Pulser tag for channel: $(truncate_error(e))"))
        end

        data_ch_after_qc = data_ch[is_physical .&& .!is_pulser]
        data_pulser = data_ch[is_physical .&& is_pulser]

        fig = Makie.Figure(size = (620, 400))
        binwidth = 8*15
        hall = StatsBase.fit(StatsBase.Histogram, data_ch.e_trap, range(0, maximum(data_ch_after_qc.e_trap), step = binwidth))
        hqc  = StatsBase.fit(StatsBase.Histogram, data_ch_after_qc.e_trap, range(0, maximum(data_ch_after_qc.e_trap), step = binwidth))
        hp   = StatsBase.fit(StatsBase.Histogram, data_pulser.e_trap, range(0, maximum(data_ch_after_qc.e_trap), step = binwidth))
        ax = Makie.Axis(fig[1,1], xlabel = "Energy (ADC)", ylabel = "Counts / $(binwidth) ADC", 
            xtickformat = x -> string.(round.(Int,x)),
            yscale = Makie.log10, limits = (extrema(first(hall.edges)), (0.9,maximum(hall.weights)*1.2)),
            title = get_plottitle(filekey, det, "Trap Raw Energy Spectrum"))
        Makie.stephist!(ax, StatsBase.midpoints(first(hall.edges)), weights = replace(hall.weights, 0 => 1e-10), bins = first(hall.edges), color = LegendMakie.BEGeOrange, label = "Trap - before QC")
        Makie.stephist!(ax, StatsBase.midpoints(first(hqc.edges)), weights = replace(hqc.weights, 0 => 1e-10), bins = first(hqc.edges), label = "Trap - after QC", color = LegendMakie.AchatBlue)
        Makie.stephist!(ax, StatsBase.midpoints(first(hp.edges)), weights = replace(hp.weights, 0 => 1e-10), bins = first(hp.edges), color = :red, label = "Pulser")
        Makie.axislegend(ax, position = :rt, framevisible = true, framecolor = :lightgray)
        LegendMakie.add_watermarks!(final = true)
        savelfig(LegendMakie.lsavefig, fig, l200, filekey, det, :raw_energy_e_trap)

        # save hit file
        @debug "Save hit file"
        write_files(hitchfilename, use_cache = true, mode = CreateOrReplace()) do outfilename
            lh5open(outfilename, "w") do outdata
                @info "Save QC"
                outdata[det_label, :jlhit, :qc] = Table(merge(columns(qc), (is_physical = is_physical,)));
                @info "Save Pulser Tags"
                outdata[det_label, :jlhit, :pulserTag] = is_pulser;
                @info "Save data after QC"
                outdata[det_label, :jlhit, :dataQC] = data_ch_after_qc;
                @info "Save data pulser"
                outdata[det_label, :jlhit, :dataPulser] = data_pulser;
            end
        end

        sf, n_pulser = count(is_physical) / length(is_physical) * 100u"percent", ifelse(!isempty(data_pulser), length(data_pulser), 0)
        log_ch = log_nt((det, ch, ProcessStatus(1), sf, n_pulser, "-"))


        for cut in columnnames(qc)
            @info "SF: $(cut) cut: $(count(getproperty(qc, cut)) / length(qc) * 100u"percent")"
        end

        return (result = (sf = sf, n_pulser = n_pulser), log = log_ch, processed=true)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_qc = parallel(chinfo, ch_hit_cal, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished Hit channel processing"

    pars_db = create_pars(pars_db, result_qc)
    writelprops(l200.par.rpars.qc[period], run, pars_db)
    writevalidity(l200.par.rpars.qc, filekey, (period, run); category=:cal)
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Pulser Processing time: $(canonicalize(pulser_processing_time))")
    lreport!(report, "Filekeys Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, hit_cal_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results Pulser")
    lreport!(report, create_logtbl(result_puls))
    lreport!(report, "# Results Filekeys")
    lreport!(report, create_logtbl(result_qc))


    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    # flush stdout
    flush(stdout)
end