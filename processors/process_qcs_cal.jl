function process_qcs_cal(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0, stability_sigma::Real=5.0)

    isfinite(stability_sigma) && stability_sigma > 0 || throw(ArgumentError("stability_sigma must be finite and positive"))

    @info "Generate calibration QC flags for period $period and run $run"

    filekeys = filter(!in(bad_filekeys(l200; load_key=:unprocessable)), search_disk(FileKey, l200.tier[:jldsp, :cal, period, run]))
    removed_filekeys = bad_filekeys(l200; load_key=:removed)
    included_filekeys = .!in.(filekeys, Ref(removed_filekeys))
    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) detectors"
    qc_config = dataprod_config(l200).qc(filekey)
    energy_config = dataprod_config(l200).energy(filekey)
    @debug "Loaded QC config: $(lstring(qc_config))"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.qcs), string(period)))
    pars_db = PropDict(l200.par.rpars.qcs[period, run])
    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all detectors" end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Status, Symbol("Pulser SF"), Symbol("Tl-208 FEP SF"), Symbol("Number Pulser Events"), Symbol("Number Single-pulse Events"), Symbol("Single pulses with invalid energy"), :Error)}

    warning_nt = NamedTuple{(:Detector, :Filekey, :Selection, Symbol("Efficiency (%)"), Symbol("Reference (%)"), :Events, Symbol("Reference events"), Symbol("Deviation (σ)")), Tuple{DetectorId, FileKey, Symbol, Float64, Float64, Int, Int, Float64}}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    chinfo_puls = channelinfo(l200, filekey, Symbol(qc_config.pulser.puls_detector))
    det_puls = chinfo_puls.detector

    log_fk_nt = NamedTuple{(:Filekey, :Status, Symbol("Processed Detectors"), Symbol("Failed Detectors"), :Error)}
    function filekey_qcs(fk::FileKey)
        qcsfilename = l200.tier[:jlqcs, fk]
        n_processed = 0
        failed_detectors = DetectorId[]
        # Use raw pulser timestamps as the coincidence reference for all detectors in this filekey.
        pulser_timestamps = read_ldata(:timestamp, l200, :raw, fk, det_puls).timestamp
        write_files(qcsfilename, use_cache=true, mode=CreateOrModify()) do outfilename
            if reprocess && isfile(outfilename)
                rm(outfilename; force=true)
            end
            lh5open(outfilename, "cw") do outdata
                for chinfo_det in chinfo
                    det = chinfo_det.detector
                    try
                        if haskey(outdata, "jlqcs/$det")
                            @info "Detector $det already processed, skip"
                            continue
                        end
                        # Evaluate detector-specific QC labels and combine them into the saved event selections.
                        qc_config_det = merge(qc_config.default, get(qc_config, chinfo_det.usability, PropDict()), get(qc_config, det, PropDict()))
                        timestamps = read_ldata(:timestamp, l200, :jldsp, fk, det).timestamp
                        qc_labels = read_ldata(ljl_propfunc(qc_config_det.labels), l200, :jldsp, fk, det)
                        single_pulse_pf = ljl_propfunc(qc_config_det.is_single_pulse)
                        pulser_config_det = merge(qc_config.pulser.default, get(qc_config.pulser, det, PropDict()))
                        is_pulser = flag_coincidences(timestamps, pulser_timestamps; ts_window=pulser_config_det.puls_ts_window)
                        qc = Table(merge(columns(qc_labels), (timestamp=timestamps, is_single_pulse=single_pulse_pf.(qc_labels), is_pulser=is_pulser)))
                        outdata[:jlqcs, det] = qc
                        n_processed += 1
                    catch e
                        @error "QC failed for $det in $fk: $(truncate_error(e))"
                        push!(failed_detectors, det)
                    end
                end
            end
        end
        log_fk = log_fk_nt((fk, ProcessStatus(isempty(failed_detectors) ? 1 : 0), n_processed, string.(failed_detectors), ""))
        return (processed=n_processed > 0, log=log_fk)
    end

    function det_qcs_cal(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector

        qc_config_det = merge(qc_config.default, get(qc_config, chinfo_det.usability, PropDict()), get(qc_config, det, PropDict()))
        energy_config_det = merge(energy_config.default, get(energy_config, det, PropDict()))

        @debug "Summarize QC for detector $det ($ch)"
        qc_parts = [read_ldata(l200, :jlqcs, fk, det) for fk in filekeys]
        # Removed cycles remain diagnostic inputs but do not contribute to run efficiencies.
        qc = reduce(vcat, qc_parts[included_filekeys]; init=first(qc_parts)[1:0])
        data_parts = [read_ldata((:timestamp, :e_trap), l200, :jldsp, fk, det) for fk in filekeys]
        data_det = reduce(vcat, data_parts[included_filekeys]; init=first(data_parts)[1:0])
        data_det.timestamp == qc.timestamp || throw(DimensionMismatch("DSP and QC timestamps differ for $det in $period-$run"))
        single_pulse_pf = ljl_propfunc(qc_config_det.is_single_pulse)
        flag_names = [Symbol.(keys(qc_config_det.labels))...; :is_single_pulse]
        is_pulser = qc.is_pulser
        qc_propfunc = merge(qc_config_det.labels, PropDict(:is_single_pulse => qc_config_det.is_single_pulse))

        # Check single-pulse selections for invalid energy.
        n_single_pulse = count(qc.is_single_pulse)
        n_invalid_e_single_pulse = count(qc.is_single_pulse .&& .!qc.is_valid_e)
        if n_invalid_e_single_pulse > 0
            @warn "Detector $det ($ch): $n_invalid_e_single_pulse of $n_single_pulse single-pulse events fail is_valid_e; check the QC cuts"
        end

        # calculate survival fractions
        plot_flag_names = Symbol[first(typeof(path).parameters[1]) for path in PropertyFunctions.input_property_paths(single_pulse_pf)]
        n_pulser = count(is_pulser)
        pulser_sf_values = [(n_pulser == 0 ? NaN : count(getproperty(qc, flag_name)[is_pulser]) / n_pulser) * 100u"percent" for flag_name in flag_names]
        pulser_sf = NamedTuple{Tuple(flag_names)}(Tuple(pulser_sf_values))

        # Retain per-filekey counts for stability checks and diagnostics.
        filekey_summary = PropDict()
        for (fk, qc_part) in zip(filekeys, qc_parts)
            pulser = qc_part.is_pulser
            n_pulser_fk = count(pulser)
            n_nonpulser_fk = count(.!pulser)
            counts = (is_removed=fk in removed_filekeys, n_events=length(qc_part), n_pulser=n_pulser_fk, n_nonpulser=n_nonpulser_fk,
                n_single_pulse=count(qc_part.is_single_pulse),
                n_pulser_pass=count(qc_part.is_single_pulse .& pulser),
                n_nonpulser_pass=count(qc_part.is_single_pulse .& .!pulser))
            filekey_summary[Symbol(fk)] = PropDict(pairs(counts))
        end

        # Compare each filekey with the other nonremoved cycles, using an exact two-sample count test.
        summaries = [filekey_summary[Symbol(fk)] for fk in filekeys]
        for summary in summaries
            summary[:stability] = PropDict()
        end
        stability_warnings = warning_nt[]
        x_fk = collect(eachindex(filekeys))
        tick_indices = unique(round.(Int, range(1, length(filekeys); length=min(12, length(filekeys)))))
        fig = Makie.Figure(size=(1100, 500))
        ax = Makie.Axis(fig[1,1], title=get_plottitle(filekey, det, "QC Efficiency per Filekey"), xlabel="Filekey start (UTC)", ylabel="Survival fraction (%)",
            xticks=(tick_indices, [string(Timestamp(filekeys[i])) for i in tick_indices]), xticklabelrotation=pi/3, limits=(nothing, (-2, 102)))
        for (selection, n_key, k_key, color, label, monitor) in ((:pulser, :n_pulser, :n_pulser_pass, LegendMakie.AchatBlue, "Pulser single pulse", true),
                (:nonpulser, :n_nonpulser, :n_nonpulser_pass, LegendMakie.BEGeOrange, "Non-pulser single pulse", false))
            n = [getproperty(summary, n_key) for summary in summaries]
            k = [getproperty(summary, k_key) for summary in summaries]
            efficiency = [n[i] == 0 ? NaN : k[i] / n[i] for i in eachindex(n)]
            total_n, total_k = sum(n[included_filekeys]), sum(k[included_filekeys])
            outliers = Int[]
            for i in eachindex(filekeys)
                ref_n = total_n - (included_filekeys[i] ? n[i] : 0)
                ref_k = total_k - (included_filekeys[i] ? k[i] : 0)
                reference = ref_n == 0 ? NaN : ref_k / ref_n
                sigma = NaN
                if n[i] > 0 && ref_n > 0
                    # Conditioning on the total accepted/rejected counts includes reference uncertainty and handles 0/100%.
                    null = Hypergeometric(k[i] + ref_k, n[i] + ref_n - k[i] - ref_k, n[i])
                    tail = min(cdf(null, k[i]), ccdf(null, k[i] - 1), 0.5)
                    sigma = sign(efficiency[i] - reference) * -quantile(Normal(), max(tail, floatmin(Float64)))
                end
                flagged = monitor && included_filekeys[i] && abs(sigma) > stability_sigma
                summaries[i].stability[selection] = PropDict(:reference => 100 * reference, :reference_events => ref_n,
                    :sigma => sigma, :flagged => flagged, :available => isfinite(sigma))
                if flagged
                    push!(outliers, i)
                    push!(stability_warnings, warning_nt((det, filekeys[i], selection, 100 * efficiency[i], 100 * reference, n[i], ref_n, sigma)))
                end
            end
            # Wilson one-sigma intervals remain meaningful for small samples and efficiencies at 0/100%.
            center = [(k[i] + 0.5) / (n[i] + 1) for i in eachindex(n)]
            halfwidth = [n[i] == 0 ? NaN : sqrt(n[i] * efficiency[i] * (1 - efficiency[i]) + 0.25) / (n[i] + 1) for i in eachindex(n)]
            Makie.errorbars!(ax, x_fk, 100 .* efficiency, 100 .* (efficiency .- center .+ halfwidth),
                100 .* (center .+ halfwidth .- efficiency); color)
            Makie.scatterlines!(ax, x_fk, 100 .* efficiency; label, color)
            if total_n > 0
                Makie.hlines!(ax, [100 * total_k / total_n]; color, linestyle=:dash, linewidth=1)
            end
            if !isempty(outliers)
                Makie.scatter!(ax, x_fk[outliers], 100 .* efficiency[outliers]; color=:red, marker=:xcross,
                    markersize=16, label="$selection outlier")
            end
        end
        removed_indices = findall(in(removed_filekeys), filekeys)
        if !isempty(removed_indices)
            Makie.vlines!(ax, removed_indices; color=(:red, 0.3), linestyle=:dash, label="Removed cycle")
        end
        Makie.axislegend(ax; position=:lb)
        LegendMakie.add_watermarks!(final=true)
        savelfig(LegendMakie.lsavefig, fig, l200, filekey, det, :qc_filekey_efficiency)
        stability_message = isempty(stability_warnings) ? "" : "$(length(stability_warnings)) filekey efficiencies exceed $(stability_sigma)σ; see QC stability warnings."
        isempty(qc) && (stability_message = "No events in nonremoved filekeys.")

        try
            if length(qc) < 5000
                throw(ErrorException("Not enough data points for detector $det ($ch)"))
            end

            fep_idx = findfirst(==(:Tl208FEP), Symbol.(energy_config_det.th228_names))
            valid_energy = isfinite.(data_det.e_trap) .&& (data_det.e_trap .> 0) .&& .!is_pulser
            e_uncal = collect(data_det.e_trap[valid_energy])
            quantile_perc = if energy_config_det.quantile_perc isa String parse(Float64, energy_config_det.quantile_perc) else energy_config_det.quantile_perc end
            result_simple, _ = simple_calibration(e_uncal, energy_config_det.th228_lines, energy_config_det.left_window_sizes, energy_config_det.right_window_sizes,; calib_type = :th228, quantile_perc = quantile_perc, binning_peak_window = energy_config_det.binning_peak_window)
            e_cal = e_uncal .* result_simple.c
            fep_sf_values = map(flag_names) do flag_name
                result_fep, _ = get_peak_survival_fraction(e_cal, mvalue(energy_config_det.th228_lines[fep_idx]), (energy_config_det.left_window_sizes[fep_idx], energy_config_det.right_window_sizes[fep_idx]), getproperty(qc, flag_name)[valid_energy]; fit_func = Symbol(energy_config_det.th228_fit_func[fep_idx]), uncertainty = true)
                result_fep.sf
            end
            fep_sf = NamedTuple{Tuple(flag_names)}(Tuple(fep_sf_values))
            survival_fractions = (pulser=pulser_sf, Tl208FEP=fep_sf)

            # plot energy spectra before and after QC
            data_det_for_plot = data_det[qc.is_valid_e]
            data_det_after_qc = data_det[qc.is_single_pulse .&& .!is_pulser .&& qc.is_valid_e]
            data_pulser = data_det[qc.is_single_pulse .&& is_pulser .&& qc.is_valid_e]
            fig = Makie.Figure(size = (620, 400))
            binwidth = 8 * 15
            spectrum_range = range(0, maximum(data_det_after_qc.e_trap), step = binwidth)
            hall = StatsBase.fit(StatsBase.Histogram, data_det_for_plot.e_trap, spectrum_range)
            hqc = StatsBase.fit(StatsBase.Histogram, data_det_after_qc.e_trap, spectrum_range)
            hp = StatsBase.fit(StatsBase.Histogram, data_pulser.e_trap, spectrum_range)
            ax = Makie.Axis(fig[1,1], xlabel = "Energy (ADC)", ylabel = "Counts / $(binwidth) ADC", xtickformat = x -> string.(round.(Int,x)), yscale = Makie.log10, limits = (extrema(first(hall.edges)), (0.9, maximum(hall.weights) * 1.2)), title = get_plottitle(filekey, det, "Trap Raw Energy Spectrum"))
            Makie.stephist!(ax, StatsBase.midpoints(first(hall.edges)), weights = replace(hall.weights, 0 => 1e-10), bins = first(hall.edges), color = LegendMakie.BEGeOrange, label = "Trap - before QC")
            Makie.stephist!(ax, StatsBase.midpoints(first(hqc.edges)), weights = replace(hqc.weights, 0 => 1e-10), bins = first(hqc.edges), color = LegendMakie.AchatBlue, label = "Trap - after QC")
            Makie.stephist!(ax, StatsBase.midpoints(first(hp.edges)), weights = replace(hp.weights, 0 => 1e-10), bins = first(hp.edges), color = :red, label = "Pulser")
            Makie.axislegend(ax, position = :rt, framevisible = true, framecolor = :lightgray)
            LegendMakie.add_watermarks!(final = true)
            savelfig(LegendMakie.lsavefig, fig, l200, filekey, det, :raw_energy_e_trap)

            # plot survival fractions for the flags used by is_single_pulse
            x = collect(eachindex(plot_flag_names))
            pulser_sf_plot = mvalue.(ustrip.(u"percent", [getproperty(pulser_sf, flag_name) for flag_name in plot_flag_names]))
            fep_sf_plot = mvalue.(ustrip.(u"percent", [getproperty(fep_sf, flag_name) for flag_name in plot_flag_names]))
            fig = Makie.Figure(size = (max(800, 55 * length(plot_flag_names)), 500))
            ax = Makie.Axis(fig[1,1], title = get_plottitle(filekey, det, "QC Survival Fractions"), xlabel = "QC flag", ylabel = "Survival fraction (%)", xticks = (x, string.(plot_flag_names)), xticklabelrotation = pi / 3, limits = ((0.3, length(plot_flag_names) + 0.7), nothing))
            Makie.scatter!(ax, x .- 0.2, pulser_sf_plot, markersize = 12, color = LegendMakie.AchatBlue, label = "Pulser")
            Makie.scatter!(ax, x .+ 0.2, fep_sf_plot, markersize = 12, color = LegendMakie.BEGeOrange, label = "Tl-208 FEP")
            Makie.axislegend(ax, position = :lb, orientation = :horizontal, framevisible = true, framecolor = :lightgray)
            LegendMakie.add_watermarks!(final = true)
            savelfig(LegendMakie.lsavefig, fig, l200, filekey, det, :qc_survival_fractions)

            log_det = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(isempty(stability_message) ? 1 : -1), pulser_sf.is_single_pulse, fep_sf.is_single_pulse, n_pulser, n_single_pulse, n_invalid_e_single_pulse, stability_message))
            return (result = (filekey_summary = filekey_summary, func = qc_propfunc, survival_fractions = survival_fractions, n_pulser = n_pulser, n_single_pulse = n_single_pulse, n_invalid_e_single_pulse = n_invalid_e_single_pulse), warnings = stability_warnings, log = log_det, processed = true)
        catch e
            @error "QC calibration summary failed for $det: $(truncate_error(e))"
            return (warnings=stability_warnings, filekey_summary=filekey_summary, processed=false,
                log=log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(0), "-", "-", n_pulser,
                    n_single_pulse, n_invalid_e_single_pulse, truncate_error(e))))
        end

    end

    # get start time
    start_time = now()

    # Generate per-filekey QC data before calculating detector run summaries.
    result_cycles = parallel(filekeys, filekey_qcs, log_fk_nt, wpool; timeout=timeout, retry=false, process_name="$period-$run-QC-filekeys")

    result_qc = parallel(chinfo, det_qcs_cal, log_nt, wpool; timeout = timeout, retry = false, process_name = "$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished QC detector processing"

    # Clear previous detector results when the current summary fails.
    for (chinfo_det, result) in result_qc
        if !haskey(result, :result)
            delete!(pars_db, Symbol(chinfo_det.detector))
        end
    end
    pars_db = create_pars(pars_db, result_qc)
    # Replace filekey summaries to discard obsolete entries.
    for (chinfo_det, result) in result_qc
        if haskey(result, :result)
            pars_db[chinfo_det.detector][:filekey_summary] = result.result.filekey_summary
        elseif haskey(result, :filekey_summary)
            pars_db[chinfo_det.detector] = PropDict(:filekey_summary => result.filekey_summary)
        end
    end
    writelprops(l200.par.rpars.qcs[period], run, pars_db)
    writevalidity(l200.par.rpars.qcs, filekey, (period, run); category=:cal)
    @info "Saved QC-survival pars to disk"

    warning_rows = reduce(vcat, (res.warnings for (_, res) in result_qc if haskey(res, :warnings)); init=warning_nt[])

    report_filename = get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))"))
    # plot the final survival fractions for all detectors from the parameter database
    fig = Makie.Figure(size = (max(1600, 18 * length(chinfo)), 600))
    ax = Makie.Axis(fig[1,1])
    LegendMakie.parameterplot!(ax, chinfo, pars_db, [:survival_fractions, :pulser, :is_single_pulse]; ylabel = "Survival fraction (%)", color = LegendMakie.AchatBlue, label = "Pulser", detector_status_colors = true)
    LegendMakie.parameterplot!(ax, chinfo, pars_db, [:survival_fractions, :Tl208FEP, :is_single_pulse]; ylabel = "Survival fraction (%)", color = LegendMakie.BEGeOrange, label = "Tl-208 FEP", detector_status_colors = true)
    ax.title = get_plottitle(filekey, :all, "QC Survival Fractions")
    Makie.axislegend(ax, position = :lb, orientation = :horizontal, framevisible = true, framecolor = :lightgray)
    LegendMakie.add_watermarks!(fig, ax; final = true)
    savelfig(LegendMakie.lsavefig, fig, l200, filekey, :all, :qc_survival_fractions; cleanup = false)

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_cycles, result_qc)]))
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total processing time: $(canonicalize(now() - start_time))")
    lreport!(report, qcs_cal_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# QC stability warnings")
    lreport!(report, "Threshold: $(stability_sigma)σ, two-sided exact count comparison against the other nonremoved filekeys. Red crosses mark unexpected deviations; dashed reference lines pool nonremoved cycles. Error bars are one-sigma Wilson intervals. Non-pulser acceptance is diagnostic only.")
    lreport!(report, isempty(warning_rows) ? "No unexpected filekey efficiency deviations." : StructArray(warning_rows))
    lreport!(report, "# Detector overview")
    lreport!(report, fig)
    lreport!(report, "\n# Filekey Results")
    lreport!(report, isempty(result_cycles) ? "No filekeys processed." : StructArray([res.log for (_, res) in result_cycles]))
    lreport!(report, "\n# Results")
    lreport!(report, isempty(result_qc) ? "No detectors processed." : StructArray([res.log for (_, res) in result_qc]))

    @info "Write log report"
    writelreport(report_filename, report)
    @info report
    Base.empty!(fig)

    # flush stdout
    flush(stdout)
end
