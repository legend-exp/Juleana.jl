function p_process_stability_plots_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod,; reprocess::Bool=false, timeout::Int=0, only_first_period::Bool=true)

    @info "Process detector stability plots for partitions conatining period $period"

    rinfo = runinfo(l200, period) |> filterby(@pf $phy.is_analysis_run)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).phy.startkey
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    if reprocess @info "Reprocess all detectors" end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :Partition, :Channel, :Plot, :Status, :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    chinfo_unfolded = get_partition_channelinfo(l200, chinfo, period, :phy; unfold_partitions=true)
    @info "Loaded channel info with $(length(chinfo_unfolded)) detector-partitions"
    # get start time
    start_time = now()

    function det_stability_plots(chinfo_det::NamedTuple)

        ch   = chinfo_det.channel
        det  = chinfo_det.detector
        part = chinfo_det.partition

        @info "Processing detector $det ($ch) in partition $part"

        partinfo_det = partitioninfo(l200, det, part)
        filekey_det = first(getproperty(partinfo_det, :phy)).startkey

        if only_first_period && period != first(partinfo_det.period)
            @info "Skip $det in partition $part for period $period, as it starts in period $(first(partinfo_det.period))"
            log_det = log_nt((det, part, ch, :all, ProcessStatus(0), "Skipped, starts in period $(first(partinfo_det.period))"))
            return (processed = Dict(:all => false), log = Dict(:all => log_det), skipped = true)
        end

        qc_config = dataprod_config(l200).qc(filekey_det)
        @debug "Loaded QC config for $filekey_det: $(lstring(qc_config))"

        n_ref = qc_config.stability_plots.n_ref
        n_smooth = qc_config.stability_plots.n_smooth
        Qbb = qc_config.stability_plots.Qbb

        chinfo_puls = channelinfo(l200, filekey_det, Symbol(qc_config.pulser.puls_detector))
        det_puls = chinfo_puls.detector
        @debug "Loaded pulser channel info for partition $part: $chinfo_puls"

        data = try
            read_ldata(l200, DataTier(:jldsp), :phy, partinfo_det, det)
        catch e
            @error "Stability data for $det in partition $part cannot be loaded: $(truncate_error(e))"
            log_det = log_nt((det, part, ch, :all, ProcessStatus(0), "$(truncate_error(e))"))
            return (processed = Dict(:all => false), log = Dict(:all => log_det))
        end

        puls = try
            read_ldata(l200, DataTier(:jlpls), :phy, partinfo_det, det_puls)
        catch e
            @error "Pulser data for $det_puls in partition $part cannot be loaded: $(truncate_error(e))"
            log_det = log_nt((det, part, ch, :all, ProcessStatus(0), "$(truncate_error(e))"))
            return (processed = Dict(:all => false), log = Dict(:all => log_det))
        end
        time_s = ustrip.(data.timestamp)
        bl_f   = float.(data.blmean)
        σbl    = float.(data.blsigma)
        e10410  = float.(data.e_10410)

        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        # Run, save, and log a plot without aborting the processor on failure.
        function run_plot(make_plot::Function, plot_name::Symbol)
            try
                p = make_plot()
                savelfig(LegendMakie.lsavefig, p, l200, part, filekey_det, det, plot_name)
                log_info_dict[plot_name]  = log_nt((det, part, ch, plot_name, ProcessStatus(1), ""))
                processed_dict[plot_name] = true
            catch e
                @error "Failed plot $plot_name for detector $det ($ch) in partition $part: $(truncate_error(e))"
                log_info_dict[plot_name]  = log_nt((det, part, ch, plot_name, ProcessStatus(0), "$(truncate_error(e))"))
                processed_dict[plot_name] = false
            end
        end

        heatmap_kwargs = (bins = 600, figsize = (900, 600), xlabel = "Time (s)", colormap = :viridis, colorbarlabel = "Counts")

        run_plot(:stability_time_vs_bl) do
            LegendMakie.lhist(time_s, bl_f; heatmap_kwargs..., ylabel = "Baseline (ADC)", title = get_plottitle(filekey_det, part, det, "Time vs Baseline"))
        end

        run_plot(:stability_time_vs_blsigma) do
            LegendMakie.lhist(time_s, σbl; heatmap_kwargs..., ylabel = "Baseline σ (ADC)", ylims = (0.0, 1000.0), title = get_plottitle(filekey_det, part, det, "Time vs Baseline σ"))
        end

        run_plot(:stability_time_vs_e10410) do
            LegendMakie.lhist(time_s, e10410; heatmap_kwargs..., ylabel = "E_10410 (ADC)", ylims = (0.0, 1e5), title = get_plottitle(filekey_det, part, det, "Time vs E_10410"))
        end

        run_plot(:stability_e10410_hist) do
            LegendMakie.lhist(e10410; bins = 0:1000:6e5, figsize = (900, 400), xlabel = "E_10410 (ADC)", ylabel = "Counts", yscale = Makie.log10, title = get_plottitle(filekey_det, part, det, "E_10410 Distribution"))
        end

        mask_trig = puls.aux_trig .== true
        if any(mask_trig)
            run_plot(:stability_time_vs_e10410_trig) do
                LegendMakie.lhist(time_s[mask_trig], e10410[mask_trig]; heatmap_kwargs..., ylabel = "E_10410 (ADC)", title = get_plottitle(filekey_det, part, det, "Time vs E_10410 (Pulser-Triggered)"))
            end
        end

        mask_gain = .!isnan.(puls.e_10410) .&& .!isnan.(e10410) .&& mask_trig
        if count(mask_gain) > n_ref
            run_plot(:stability_gain_stability) do
                LegendMakie.lgainstability(time_s[mask_gain], e10410[mask_gain], puls.e_10410[mask_gain]; Qbb, n_ref, n_smooth, energy_label = "E_10410", title = get_plottitle(filekey_det, part, det, "Gain Stability"))
            end
        else
            @warn "Not enough pulser statistics for gain plot: $det in partition $part"
        end

        return (processed = processed_dict, log = log_info_dict)
    end

    # execute in parallel
    result_stability = parallel(chinfo_unfolded, det_stability_plots, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

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
    return any(x -> get(last(x), :skipped, false), values(result_stability))
end
