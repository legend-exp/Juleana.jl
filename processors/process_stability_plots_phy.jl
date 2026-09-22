function process_stability_plots_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)

    @info "Process detector stability plots for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    qc_config = dataprod_config(l200).qc(filekey)
    @debug "Loaded QC config: $(lstring(qc_config))"

    n_ref = qc_config.stability_plots.n_ref
    n_smooth = qc_config.stability_plots.n_smooth
    Qbb = qc_config.stability_plots.Qbb
    smooth_window = 20n_smooth * u"s"

    chinfo_puls = channelinfo(l200, filekey, Symbol(qc_config.pulser.puls_detector))
    det_puls = chinfo_puls.detector
    @info "Loaded pulser channel info: $chinfo_puls"

    if reprocess @info "Reprocess all detectors" end

    log_nt = NamedTuple{(:Detector, :Channel, :Plot, :Status, :Error)}

    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    @info "Loading pulser data for period $period and run $run"
    puls = read_ldata((:e_10410, :aux_trig), l200, DataTier(:jlpls), :phy, period, run, det_puls)

    start_time = now()

    function det_stability_plots(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector

        @info "Processing detector $det ($ch)"

        data = try
            read_ldata((:timestamp, :blmean, :blsigma, :e_10410), l200, DataTier(:jldsp), :phy, period, run, det)
        catch e
            @error "Stability data for $det cannot be loaded: $(truncate_error(e))"
            log_det = log_nt((det, ch, :all, ProcessStatus(0), "$(truncate_error(e))"))
            return (processed = Dict(:all => false), log = Dict(:all => log_det))
        end

        finite_data = isfinite.(data.timestamp) .&& isfinite.(data.blmean) .&& isfinite.(data.blsigma) .&& isfinite.(data.e_10410)
        timestamp = data.timestamp[finite_data]
        time_s    = ustrip.(timestamp)
        bl_f      = float.(data.blmean[finite_data])
        σbl       = float.(data.blsigma[finite_data])
        e10410    = float.(data.e_10410[finite_data])
        puls_e10410 = puls.e_10410[finite_data]
        aux_trig = puls.aux_trig[finite_data]

        log_info_dict = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        # Run, save, and log a plot without aborting the processor on failure.
        function run_plot(make_plot::Function, plot_name::Symbol)
            try
                p = make_plot()
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, plot_name)
                log_info_dict[plot_name] = log_nt((det, ch, plot_name, ProcessStatus(1), ""))
                processed_dict[plot_name] = true
            catch e
                @error "Failed plot $plot_name for detector $det ($ch): $(truncate_error(e))"
                log_info_dict[plot_name] = log_nt((det, ch, plot_name, ProcessStatus(0), "$(truncate_error(e))"))
                processed_dict[plot_name] = false
            end
        end

        heatmap_kwargs = (bins = 600, figsize = (900, 600), xlabel = "Time (s)", colormap = :viridis, colorbarlabel = "Counts")

        run_plot(:stability_time_vs_bl) do
            LegendMakie.lhist(time_s, bl_f; heatmap_kwargs..., ylabel = "Baseline (ADC)", title = get_plottitle(filekey, det, "Time vs Baseline"))
        end

        run_plot(:stability_time_vs_blsigma) do
            LegendMakie.lhist(time_s, σbl; heatmap_kwargs..., ylabel = "Baseline σ (ADC)", ylims = (0.0, 1000.0), title = get_plottitle(filekey, det, "Time vs Baseline σ"))
        end

        run_plot(:stability_time_vs_e10410) do
            LegendMakie.lhist(time_s, e10410; heatmap_kwargs..., ylabel = "E_10410 (ADC)", ylims = (0.0, 1e5), title = get_plottitle(filekey, det, "Time vs E_10410"))
        end

        run_plot(:stability_e10410_hist) do
            LegendMakie.lhist(e10410; bins = 0:1000:6e5, figsize = (900, 400), xlabel = "E_10410 (ADC)", ylabel = "Counts", yscale = Makie.log10, title = get_plottitle(filekey, det, "E_10410 Distribution"))
        end

        mask_trig = aux_trig .== true
        if any(mask_trig)
            run_plot(:stability_time_vs_e10410_trig) do
                LegendMakie.lhist(time_s[mask_trig], e10410[mask_trig]; heatmap_kwargs..., ylabel = "E_10410 (ADC)", title = get_plottitle(filekey, det, "Time vs E_10410 (Pulser-Triggered)"))
            end
            run_plot(:stability_pulser_rate) do
                LegendMakie.lplot(rate(timestamp[mask_trig], smooth_window); figsize = (900, 400), ylabel = "Pulser rate (Hz)", title = get_plottitle(filekey, det, "Pulser Rate"))
            end
        end

        mask_gain = isfinite.(puls_e10410) .&& mask_trig
        if count(mask_gain) > n_ref
            run_plot(:stability_gain_stability) do
                pulser_gain = smooth(relative(TimeEvolution(timestamp[mask_gain], puls_e10410[mask_gain]), n_ref), smooth_window)
                energy_gain = smooth(relative(TimeEvolution(timestamp[mask_gain], e10410[mask_gain]), n_ref), smooth_window)
                pulser_gain = TimeEvolution(pulser_gain.time, pulser_gain.values .* (Qbb / 100))
                energy_gain = TimeEvolution(energy_gain.time, energy_gain.values .* (Qbb / 100))

                p = LegendMakie.lplot(pulser_gain; figsize = (1000, 450), label = "Pulser", sigmas = (1,), ylabel = "ΔE (keV)", ylims = (-8, 8), title = get_plottitle(filekey, det, "Gain Stability"))
                ax = Makie.content(p[1, 1])
                LegendMakie.lplot!(ax, energy_gain; color = :red, label = "E_10410", sigmas = (1,))
                Makie.axislegend(ax; position = :rt)
                p
            end
        else
            @warn "Not enough pulser statistics for gain plot: $det"
        end

        return (processed = processed_dict, log = log_info_dict)
    end

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
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    flush(stdout)
end
