function process_hit_cal(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0, quality_cuts::Symbol=:classical)

    @info "Generate cal hit for period $period and run $run"

    filekeys = search_disk(FileKey, l200.tier[:jldsp, :cal, period, run])
    
    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    qc_config = dataprod_config(l200).qc(filekey)
    @debug "Loaded QC config: $(qc_config)"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.qc), string(period)))
    pars_db = PropDict(l200.par.rpars.qc[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all detectors" end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :Channel, :Status, Symbol("Survival Fraction"), Symbol("Number Pulser Events"), :Error)}
    log_nt_puls = NamedTuple{(:Detector, :Channel, :Status, Symbol("Number Pulser Events"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    # write out pulser events
    chinfo_puls = channelinfo(l200, filekey, Symbol(qc_config.pulser.puls_detector))
    @info "Loaded pulser channel info: $(chinfo_puls)"

    # get information about pulser events from raw trigger
    function det_puls_cal(chinfo_puls::NamedTuple)
        
        ch_puls = chinfo_puls.channel
        det_puls = chinfo_puls.detector
        
        # get pulser filename
        pulserfilename = l200.tier[:jlpls, filekey, det_puls]

        if !reprocess && isfile(pulserfilename)
            return (processed = false, log = log_nt_puls((det_puls, ch_puls, ProcessStatus(1), length(lh5open(pulserfilename)[det_puls, :jlpls, :tags]), "Already processed --> skipped.")))
        end
        # extract pulser events by loading data from raw files
        @info "Get pulser events from raw data"
        data_puls = read_ldata((:daqenergy, :timestamp), l200, DataTier(:raw), DataCategory(:cal), period, run, det_puls)
        
        @info "Write Pulser events to disk"
        write_files(pulserfilename, use_cache=true, mode = CreateOrReplace()) do outfilename
            lh5open(outfilename, "w") do outdata
                @info "Save Pulser Tags"
                outdata[det_puls, :jlpls, :tags] = data_puls;
            end
        end
        return (processed = false, log = log_nt_puls((det_puls, ch_puls, ProcessStatus(1), length(data_puls), "-")))
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_puls = parallel([chinfo_puls], det_puls_cal, log_nt_puls, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished Pulser detector processing"
    pulser_processing_time = now() - start_time

    # generate hit cal files
    function det_hit_cal(chinfo_det::NamedTuple)

        ch = chinfo_det.channel
        det = chinfo_det.detector

        ch_puls = chinfo_puls.channel
        det_puls = chinfo_puls.detector

        hitdetfilename = l200.tier[:jlhit, filekey, det]
        pulserfilename = l200.tier[:jlpls, filekey, det_puls]

        if !reprocess && haskey(pars_db, det) && isfile(hitdetfilename)
            log_det = log_nt((det, ch, ProcessStatus(1), pars_db[det].sf, pars_db[det].n_pulser, "Already processed --> skipped."))
            try
                close(lh5open(hitdetfilename, "r"))
                @debug "Detector $(det) already processed"
                return (processed = true, log = log_det)
            catch e
                @warn "Error reading hit file for detector $det ($ch): $(truncate_error(e))"
                @info "Reprocess detector $det ($ch)"
                rm(hitdetfilename)
            end
        end

        if reprocess @info "Overwrite old hit file" end

        @debug "Processing detector $det ($ch)"
        
        data_det = read_ldata(l200, DataTier(:jldsp), filekeys, det)
        
        if length(data_det) < 5000
            @error "Not enough data points for detector $det ($ch), skip"
            throw(ErrorException("Not enough data points for detector $det ($ch)"))
        end

        qc_config_det = merge(qc_config.default, get(qc_config, det, PropDict()))
        pulser_config_det = merge(qc_config.pulser.default, get(qc_config.pulser, det, PropDict()))

        # generate qc cuts
        if quality_cuts ∉ (:classical, :ml)
            throw(ArgumentError("Invalid value for `quality_cuts`: $quality_cuts. Valid options are `:classical` and `:ml`."))
        end
        qc, is_physical = nothing, nothing
        try
            @debug "Get QC cuts"
            # result_qc, report_qc  = baseline_qc(data_det, qc_config_det)
            qc = Table(ljl_propfunc(qc_config_det.labels).(data_det))
            if quality_cuts == :classical
                @debug "Using classical QC cuts"
                is_physical = ljl_propfunc(qc_config_det.is_physical_classical).(qc)
            elseif quality_cuts == :ml
                @debug "Using ML-based QC cuts"
                is_physical = ljl_propfunc(qc_config_det.is_physical_ml).(qc)
            end
            @debug "Total survival fraction: $(round(count(is_physical) / length(is_physical) * 100, digits=2))%"
        catch e
            @error "Error in QC for detector $det: $(truncate_error(e))"
            throw(ErrorException("Error in QC cut generation: $(truncate_error(e))"))
        end
        yield()

        is_pulser = nothing
        try
            @debug "Get Pulser tags"
            # pulser_tag = pulser_cal_qc(data_det, pulser_config_det; n_pulser_identified=100)
            data_pulser = lh5open(pulserfilename)[det_puls, :jlpls, :tags][:]
            is_pulser = flag_coincidences(data_det.timestamp, data_pulser.timestamp, ts_window = pulser_config_det.puls_ts_window)
            @debug "Found $(count(is_pulser)) pulser events"
        catch e
            @error "Error in Pulser tag for detector $det: $(truncate_error(e))"
            throw(ErrorException("Error in Pulser tag for detector: $(truncate_error(e))"))
        end

        data_det_after_qc = data_det[is_physical .&& .!is_pulser]
        data_pulser = data_det[is_physical .&& is_pulser]

        fig = Makie.Figure(size = (620, 400))
        binwidth = 8*15
        hall = StatsBase.fit(StatsBase.Histogram, data_det.e_trap, range(0, maximum(data_det_after_qc.e_trap), step = binwidth))
        hqc  = StatsBase.fit(StatsBase.Histogram, data_det_after_qc.e_trap, range(0, maximum(data_det_after_qc.e_trap), step = binwidth))
        hp   = StatsBase.fit(StatsBase.Histogram, data_pulser.e_trap, range(0, maximum(data_det_after_qc.e_trap), step = binwidth))
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
        write_files(hitdetfilename, use_cache = true, mode = CreateOrReplace()) do outfilename
            lh5open(outfilename, "w") do outdata
                @info "Save QC"
                outdata[det, :jlhit, :qc] = Table(merge(columns(qc), (is_physical = is_physical,)));
                @info "Save Pulser Tags"
                outdata[det, :jlhit, :pulserTag] = is_pulser;
                @info "Save data after QC"
                outdata[det, :jlhit, :dataQC] = data_det_after_qc;
                @info "Save data pulser"
                outdata[det, :jlhit, :dataPulser] = data_pulser;
            end
        end

        sf, n_pulser = count(is_physical) / length(is_physical) * 100u"percent", ifelse(!isempty(data_pulser), length(data_pulser), 0)
        log_det = log_nt((det, ch, ProcessStatus(1), sf, n_pulser, "-"))


        for cut in columnnames(qc)
            @info "SF: $(cut) cut: $(count(getproperty(qc, cut)) / length(qc) * 100u"percent")"
        end

        return (result = (sf = sf, n_pulser = n_pulser), log = log_det, processed=true)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_qc = parallel(chinfo, det_hit_cal, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished Hit detector processing"

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