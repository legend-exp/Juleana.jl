function p_process_stability_plots_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod,; reprocess::Bool=false, timeout::Int=0, only_first_period::Bool=true)

    @info "Process detector stability plots for period $period"

    rinfo = runinfo(l200, period) |> filterby(@pf $phy.is_analysis_run)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).phy.startkey
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    qc_config = dataprod_config(l200).qc(filekey)
    @debug "Loaded QC config: $(lstring(qc_config))"

    n_ref = qc_config.stability_plots.n_ref
    n_smooth = qc_config.stability_plots.n_smooth
    Qbb = qc_config.stability_plots.Qbb

    chinfo_puls = channelinfo(l200, filekey, Symbol(qc_config.pulser.puls_detector))
    det_puls = chinfo_puls.detector
    @info "Loaded pulser channel info: $chinfo_puls"

    if reprocess @info "Reprocess all detectors" end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :Channel, :Plot, :Status, :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    @info "Loading pulser data for period $period"
    puls = read_ldata(l200, :jlpls, :phy, period, det_puls)

    # get start time
    start_time = now()

    function det_stability_plots(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector

        @info "Processing detector $det ($ch)"

        data = try
            read_ldata(l200, :jldsp, :phy, period, det)
        catch e
            @error "Stability data for $det cannot be loaded: $(truncate_error(e))"
            log_det = log_nt((det, ch, :all, ProcessStatus(0), "$(truncate_error(e))"))
            return (processed = Dict(:all => false), log = Dict(:all => log_det))
        end

        time_s = ustrip.(data.timestamp)
        bl_f   = float.(data.blmean)
        σbl    = float.(data.blsigma)
        e10410  = float.(data.e_10410)

        # -----------------------------------------------------------------
        # list of stability-plot recipes to run for this detector — append
        # a `plot_name => report` pair here to add a check; reuse
        # TimeSeriesHeatmapReport / EnergyHistReport for anything of that
        # shape, or define a new report struct + lplot method in
        # LegendMakie.jl for something structurally new.
        # -----------------------------------------------------------------
        plot_jobs = Pair{Symbol, Any}[
            :time_vs_bl      => TimeSeriesHeatmapReport(time_s, bl_f;  ylabel = "Baseline (ADC)",   title = get_plottitle(filekey, det, "Time vs Baseline")),
            :time_vs_blsigma => TimeSeriesHeatmapReport(time_s, σbl;   ylabel = "Baseline σ (ADC)",  title = get_plottitle(filekey, det, "Time vs Baseline σ"), ylims = (0.0, 1000.0)),
            :time_vs_e10410   => TimeSeriesHeatmapReport(time_s, e10410; ylabel = "E_10410 (ADC)",      title = get_plottitle(filekey, det, "Time vs E_10410"),     ylims = (0.0, 1e5)),
            :e10410_hist      => EnergyHistReport(e10410; xlabel = "E_10410 (ADC)", title = get_plottitle(filekey, det, "E_10410 Distribution")),
        ]

        mask_trig = puls.aux_trig .== true
        if any(mask_trig)
            push!(plot_jobs, :time_vs_e10410_trig => TimeSeriesHeatmapReport(time_s[mask_trig], e10410[mask_trig]; ylabel = "E_10410 (ADC)", title = get_plottitle(filekey, det, "Time vs E_10410 (Pulser-Triggered)")))
        end

        mask_gain = .!isnan.(puls.e_10410) .&& .!isnan.(e10410) .&& mask_trig
        if count(mask_gain) > n_ref
            push!(plot_jobs, :gain_stability => GainStabilityReport(time_s[mask_gain], e10410[mask_gain], puls.e_10410[mask_gain]; Qbb=Qbb, n_ref=n_ref, n_smooth=n_smooth, title = get_plottitle(filekey, det, "Gain Stability")))
        else
            @warn "Not enough pulser statistics for gain plot: $det"
        end

        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        for (plot_name, report) in plot_jobs
            try
                p = LegendMakie.lplot(report)
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, plot_name)
                log_info_dict[plot_name]  = log_nt((det, ch, plot_name, ProcessStatus(1), ""))
                processed_dict[plot_name] = true
            catch e
                @error "Failed plot $plot_name for detector $det ($ch): $(truncate_error(e))"
                log_info_dict[plot_name]  = log_nt((det, ch, plot_name, ProcessStatus(0), "$(truncate_error(e))"))
                processed_dict[plot_name] = false
            end
        end

        return (processed = processed_dict, log = log_info_dict)
    end

    # execute in parallel
    result_stability = parallel(chinfo, det_stability_plots, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished stability plot generation"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_stability))

    @info "Write log report"
    writelreport(get_preportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    flush(stdout)
end