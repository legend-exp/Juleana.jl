function process_qcs_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)

    @info "Generate physics QC flags for period $period and run $run"

    filekeys = filter(!in(bad_filekeys(l200; load_key=:unprocessable)), search_disk(FileKey, l200.tier[:jldsp, :phy, period, run]))
    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) detectors"
    qc_config = dataprod_config(l200).qc(filekey)
    @debug "Loaded QC config: $(lstring(qc_config))"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.qcs), string(period)))
    pars_file = Symbol("$(run)-phy")
    pars_db = PropDict(l200.par.rpars.qcs[period, pars_file])
    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all detectors" end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :Channel, :Status, Symbol("Pulser single-pulse SF"), Symbol("Forced-trigger empty-trace SF"), Symbol("Number Pulser Events"), Symbol("Number Forced-trigger Events"), Symbol("Number Physics Events"), Symbol("Single pulses with invalid DSP properties"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    # load pulser flags
    chinfo_puls = channelinfo(l200, filekey, Symbol(qc_config.pulser.puls_detector))
    det_puls = chinfo_puls.detector
    @info "Load pulser flags for $det_puls"
    is_pulser = read_ldata(:aux_trig, l200, DataTier(:jlaux), :phy, period, run, det_puls)
    @info "Loaded $(count(is_pulser)) pulser flags"

    # load forced-trigger flags
    chinfo_forced = channelinfo(l200, filekey, Symbol(qc_config.forced_trigger.detector))
    det_forced = chinfo_forced.detector
    @info "Load forced-trigger flags for $det_forced"
    is_forced = read_ldata(:aux_trig, l200, DataTier(:jlaux), :phy, period, run, det_forced)
    is_forced = is_forced .&& .!is_pulser
    @info "Loaded $(count(is_forced)) forced-trigger events excluding pulsers"

    function det_qcs_phy(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector

        qcsfilename = l200.tier[:jlqcs, filekey, det]
        qc_config_det = merge(qc_config.default, get(qc_config, chinfo_det.usability, PropDict()), get(qc_config, det, PropDict()))

        if !reprocess && haskey(pars_db, det) && haskey(pars_db[det].survival_fractions, :pulser) && haskey(pars_db[det].survival_fractions, :forced_trigger) && haskey(pars_db[det].survival_fractions.pulser, :is_valid_dsp) && haskey(pars_db[det], :n_pulser) && haskey(pars_db[det], :n_forced) && haskey(pars_db[det], :n_physics) && haskey(pars_db[det], :n_invalid_dsp_single_pulse) && isfile(qcsfilename)
            sf = pars_db[det].survival_fractions
            log_det = log_nt((det, ch, ProcessStatus(1), sf.pulser.is_single_pulse, sf.forced_trigger.is_empty_trace, pars_db[det].n_pulser, pars_db[det].n_forced, pars_db[det].n_physics, pars_db[det].n_invalid_dsp_single_pulse, "Already processed --> skipped."))
            @debug "Detector $det already processed"
            return (processed = false, log = log_det)
        end

        @debug "Processing detector $det ($ch)"
        qc_labels = read_ldata(ljl_propfunc(qc_config_det.labels), l200, DataTier(:jldsp), filekeys, det)
        if length(qc_labels) < 5000
            @error "Not enough data points for detector $det ($ch), skip"
            throw(ErrorException("Not enough data points for detector $det ($ch)"))
        end

        # generate QC flags
        single_pulse_pf = ljl_propfunc(qc_config_det.is_single_pulse)
        empty_trace_pf = ljl_propfunc(qc_config_det.is_empty_trace)
        qc_flags = Table(merge(columns(qc_labels), (
            is_single_pulse = single_pulse_pf.(qc_labels),
            is_empty_trace = empty_trace_pf.(qc_labels),
        )))
        qc_propfunc = merge(qc_config_det.labels, PropDict(
            :is_single_pulse => qc_config_det.is_single_pulse,
            :is_empty_trace => qc_config_det.is_empty_trace,
        ))

        n_single_pulse = count(qc_flags.is_single_pulse)
        n_physics = count(qc_flags.is_single_pulse .&& .!is_pulser)
        n_invalid_dsp_single_pulse = count(qc_flags.is_single_pulse .&& .!qc_labels.is_valid_dsp)
        if n_invalid_dsp_single_pulse > 0
            @warn "Detector $det ($ch): $n_invalid_dsp_single_pulse of $n_single_pulse single-pulse events fail is_valid_dsp; check the QC cuts"
        end

        # calculate survival fractions
        qc = Table(merge(columns(qc_flags), (is_pulser = is_pulser,)))
        flag_names = collect(columnnames(qc_flags))
        plot_flag_names = Symbol[first(typeof(path).parameters[1]) for path in PropertyFunctions.input_property_paths(single_pulse_pf)]
        forced_plot_flag_names = [Symbol[first(typeof(path).parameters[1]) for path in PropertyFunctions.input_property_paths(empty_trace_pf)]; :is_empty_trace]
        n_pulser = count(is_pulser)
        pulser_sf_values = [count(getproperty(qc_flags, flag_name)[is_pulser]) / n_pulser * 100u"percent" for flag_name in flag_names]
        pulser_sf = NamedTuple{Tuple(flag_names)}(Tuple(pulser_sf_values))
        n_forced = count(is_forced)
        forced_trigger_sf_values = [count(getproperty(qc_flags, flag_name)[is_forced]) / n_forced * 100u"percent" for flag_name in flag_names]
        forced_trigger_sf = NamedTuple{Tuple(flag_names)}(Tuple(forced_trigger_sf_values))
        survival_fractions = (pulser=pulser_sf, forced_trigger=forced_trigger_sf)

        # plot pulser survival fractions for the flags used by is_single_pulse
        x = collect(eachindex(plot_flag_names))
        pulser_sf_plot = mvalue.(ustrip.(u"percent", [getproperty(pulser_sf, flag_name) for flag_name in plot_flag_names]))
        fig = Makie.Figure(size = (max(800, 55 * length(plot_flag_names)), 500))
        ax = Makie.Axis(fig[1,1], title = get_plottitle(filekey, det, "Pulser QC Survival Fractions"), xlabel = "QC flag", ylabel = "Survival fraction (%)", xticks = (x, string.(plot_flag_names)), xticklabelrotation = pi / 3, limits = ((0.3, length(plot_flag_names) + 0.7), nothing))
        Makie.scatter!(ax, x, pulser_sf_plot, markersize = 12, color = LegendMakie.AchatBlue, label = "Pulser")
        LegendMakie.add_watermarks!(final = true)
        savelfig(LegendMakie.lsavefig, fig, l200, filekey, det, :qc_survival_fractions)

        # plot forced-trigger survival fractions for is_empty_trace and its component flags
        x_forced = collect(eachindex(forced_plot_flag_names))
        forced_trigger_sf_plot = mvalue.(ustrip.(u"percent", [getproperty(forced_trigger_sf, flag_name) for flag_name in forced_plot_flag_names]))
        fig = Makie.Figure(size = (max(800, 55 * length(forced_plot_flag_names)), 500))
        ax = Makie.Axis(fig[1,1], title = get_plottitle(filekey, det, "Forced-trigger QC Survival Fractions"), xlabel = "QC flag", ylabel = "Survival fraction (%)", xticks = (x_forced, string.(forced_plot_flag_names)), xticklabelrotation = pi / 3, limits = ((0.3, length(forced_plot_flag_names) + 0.7), nothing))
        Makie.scatter!(ax, x_forced, forced_trigger_sf_plot, markersize = 12, color = LegendMakie.BEGeOrange, label = "Forced trigger")
        LegendMakie.add_watermarks!(final = true)
        savelfig(LegendMakie.lsavefig, fig, l200, filekey, det, :qc_survival_fractions_forced_trigger)

        # write QC flags
        write_files(qcsfilename, use_cache = true, mode = CreateOrReplace()) do outfilename
            lh5open(outfilename, "w") do outdata
                outdata[:jlqcs, det] = qc
            end
        end

        log_det = log_nt((det, ch, ProcessStatus(1), pulser_sf.is_single_pulse, forced_trigger_sf.is_empty_trace, n_pulser, n_forced, n_physics, n_invalid_dsp_single_pulse, "-"))
        return (result = (func = qc_propfunc, survival_fractions = survival_fractions, n_pulser = n_pulser, n_forced = n_forced, n_single_pulse = n_single_pulse, n_physics = n_physics, n_invalid_dsp_single_pulse = n_invalid_dsp_single_pulse), log = log_det, processed = true)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_qc = parallel(chinfo, det_qcs_phy, log_nt, wpool; timeout = timeout, retry = false, process_name = "$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished physics QC detector processing"

    pars_db = create_pars(pars_db, result_qc)
    writelprops(l200.par.rpars.qcs[period], pars_file, pars_db)
    writevalidity(l200.par.rpars.qcs, filekey, "$(period)/$(pars_file).yaml"; category=:phy)
    @info "Saved QC-survival pars to disk"

    # plot the final survival fractions for all detectors from the parameter database
    fig = LegendMakie.lplot(chinfo, pars_db, [:survival_fractions, :pulser, :is_single_pulse]; figsize = (max(1600, 18 * length(chinfo)), 600), ylabel = "Survival fraction (%)", color = LegendMakie.AchatBlue, label = "Pulser", watermark = false)
    ax = Makie.current_axis()
    LegendMakie.parameterplot!(ax, chinfo, pars_db, [:survival_fractions, :forced_trigger, :is_empty_trace]; ylabel = "Survival fraction (%)", color = LegendMakie.BEGeOrange, label = "Forced trigger empty trace")
    ax.title = get_plottitle(filekey, :all, "QC Survival Fractions")
    Makie.axislegend(ax, position = :lb, orientation = :horizontal, framevisible = true, framecolor = :lightgray)
    LegendMakie.add_watermarks!(final = true)
    savelfig(LegendMakie.lsavefig, fig, l200, filekey, :all, :qc_survival_fractions; cleanup = false)

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total processing time: $(canonicalize(now() - start_time))")
    lreport!(report, qcs_phy_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Detector overview")
    lreport!(report, fig)
    lreport!(report, "\n# Results")
    lreport!(report, create_logtbl(result_qc))

    report_filename = get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))"))

    @info "Write log report"
    writelreport(report_filename, report)
    @info report
    Base.empty!(fig)

    # flush stdout
    flush(stdout)
end
