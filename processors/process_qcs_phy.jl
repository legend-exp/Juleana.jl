function process_qcs_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0, stability_sigma::Real=5.0)

    isfinite(stability_sigma) && stability_sigma > 0 || throw(ArgumentError("stability_sigma must be finite and positive"))

    @info "Generate physics QC flags for period $period and run $run"

    filekeys = filter(!in(bad_filekeys(l200; load_key=:unprocessable)), search_disk(FileKey, l200.tier[:jldsp, :phy, period, run]))
    removed_filekeys = bad_filekeys(l200; load_key=:removed)
    included_filekeys = .!in.(filekeys, Ref(removed_filekeys))
    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) detectors"
    event_detectors = filterby(get_ged_evt_detsel_propfunc(l200, filekey))(channelinfo(l200, filekey; system=:geds)).detector
    qc_config = dataprod_config(l200).qc(filekey)
    @debug "Loaded QC config: $(lstring(qc_config))"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.qcs), string(period)))
    pars_file = Symbol("$(run)-phy")
    pars_db = PropDict(l200.par.rpars.qcs[period, pars_file])
    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all detectors" end

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :usability, :Status, Symbol("Pulser single-pulse SF"), Symbol("Forced-trigger empty-trace SF"), Symbol("Number Pulser Events"), Symbol("Number Forced-trigger Events"), Symbol("Number Physics Events"), Symbol("Single pulses with invalid DSP properties"), :Error)}

    warning_nt = NamedTuple{(:Detector, :Filekey, :Selection, Symbol("Efficiency (%)"), Symbol("Reference (%)"), :Events, Symbol("Reference events"), Symbol("Deviation (σ)")), Tuple{DetectorId, FileKey, Symbol, Float64, Float64, Int, Int, Float64}}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    chinfo_puls = channelinfo(l200, filekey, Symbol(qc_config.pulser.puls_detector))
    det_puls = chinfo_puls.detector
    chinfo_forced = channelinfo(l200, filekey, Symbol(qc_config.forced_trigger.detector))
    det_forced = chinfo_forced.detector

    log_fk_nt = NamedTuple{(:Filekey, :Status, Symbol("Processed Detectors"), Symbol("Failed Detectors"), :Error)}
    function filekey_qcs(fk::FileKey)
        qcsfilename = l200.tier[:jlqcs, fk]
        n_processed = 0
        failed_detectors = DetectorId[]
        # Aligned auxiliary trigger flags are shared by all detectors in a filekey.
        # jlaux groups are LH5 structs, for which a single-column read returns the bare column.
        is_pulser = read_ldata(:aux_trig, l200, DataTier(:jlaux), fk, det_puls)
        is_forced = read_ldata(:aux_trig, l200, DataTier(:jlaux), fk, det_forced) .& .!is_pulser
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
                        empty_trace_pf = ljl_propfunc(qc_config_det.is_empty_trace)
                        qc = Table(merge(columns(qc_labels), (timestamp=timestamps, is_single_pulse=single_pulse_pf.(qc_labels), is_empty_trace=empty_trace_pf.(qc_labels), is_pulser=is_pulser, is_forced=is_forced)))
                        outdata[:jlqcs, det] = qc
                        n_processed += 1
                    catch e
                        @error "QC failed for $det in $fk: $(truncate_error(e))"
                        push!(failed_detectors, det)
                    end
                end
            end
        end
        # After QC-file generation, combine detector rows into global events for this filekey.
        # Apply event-tier QC acceptance and return scalar counts for the run summary.
        event_data = Dict{DetectorId, StructArray}()
        for det in event_detectors
            qc = read_ldata(l200, :jlqcs, fk, det)
            is_crosstalk = get_ged_qc_is_crosstalk_propfunc(l200, filekey, det).(qc)
            event_data[det] = StructArray(timestamp=qc.timestamp,
                is_valid_qc=qc.is_single_pulse .| qc.is_empty_trace .| is_crosstalk,
                is_pulser=qc.is_pulser, is_forced=qc.is_forced)
        end
        events = build_global_events(event_data, event_detectors)
        passed = all.(events.is_valid_qc)
        pulser = any.(events.is_pulser)
        forced = any.(events.is_forced) .& .!pulser
        other = .!pulser .& .!forced
        event_counts = (n_events=length(events), n_pass=count(passed), n_pulser=count(pulser),
            n_pulser_pass=count(passed .& pulser), n_forced=count(forced), n_forced_pass=count(passed .& forced),
            n_other=count(other), n_other_pass=count(passed .& other))
        log_fk = log_fk_nt((fk, ProcessStatus(isempty(failed_detectors) ? 1 : 0), n_processed, string.(failed_detectors), ""))
        return (result=(event_counts=event_counts,), processed=n_processed > 0, log=log_fk)
    end

    function det_qcs_phy(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector

        qc_config_det = merge(qc_config.default, get(qc_config, chinfo_det.usability, PropDict()), get(qc_config, det, PropDict()))

        @debug "Summarize QC for detector $det ($ch)"
        qc_parts = [read_ldata(l200, :jlqcs, fk, det) for fk in filekeys]
        # Removed cycles remain diagnostic inputs but do not contribute to run efficiencies.
        qc = reduce(vcat, qc_parts[included_filekeys]; init=first(qc_parts)[1:0])
        single_pulse_pf = ljl_propfunc(qc_config_det.is_single_pulse)
        empty_trace_pf = ljl_propfunc(qc_config_det.is_empty_trace)
        flag_names = [Symbol.(keys(qc_config_det.labels))...; :is_single_pulse; :is_empty_trace]
        is_pulser = qc.is_pulser
        is_forced = qc.is_forced
        qc_propfunc = merge(qc_config_det.labels, PropDict(:is_single_pulse => qc_config_det.is_single_pulse, :is_empty_trace => qc_config_det.is_empty_trace))

        n_single_pulse = count(qc.is_single_pulse)
        n_physics = count(qc.is_single_pulse .&& .!is_pulser)
        n_invalid_dsp_single_pulse = count(qc.is_single_pulse .&& .!qc.is_valid_dsp)
        if n_invalid_dsp_single_pulse > 0
            @warn "Detector $det ($ch): $n_invalid_dsp_single_pulse of $n_single_pulse single-pulse events fail is_valid_dsp; check the QC cuts"
        end

        # calculate survival fractions
        plot_flag_names = Symbol[first(typeof(path).parameters[1]) for path in PropertyFunctions.input_property_paths(single_pulse_pf)]
        forced_plot_flag_names = [Symbol[first(typeof(path).parameters[1]) for path in PropertyFunctions.input_property_paths(empty_trace_pf)]; :is_empty_trace]
        n_pulser = count(is_pulser)
        pulser_sf_values = [(n_pulser == 0 ? NaN : count(getproperty(qc, flag_name)[is_pulser]) / n_pulser) * 100u"percent" for flag_name in flag_names]
        pulser_sf = NamedTuple{Tuple(flag_names)}(Tuple(pulser_sf_values))
        n_forced = count(is_forced)
        forced_trigger_sf_values = [(n_forced == 0 ? NaN : count(getproperty(qc, flag_name)[is_forced]) / n_forced) * 100u"percent" for flag_name in flag_names]
        forced_trigger_sf = NamedTuple{Tuple(flag_names)}(Tuple(forced_trigger_sf_values))
        survival_fractions = (pulser=pulser_sf, forced_trigger=forced_trigger_sf)

        # Retain per-filekey counts for stability checks and diagnostics.
        filekey_summary = PropDict()
        for (fk, qc_part) in zip(filekeys, qc_parts)
            pulser = qc_part.is_pulser
            n_pulser_fk = count(pulser)
            n_nonpulser_fk = count(.!pulser)
            counts = (is_removed=fk in removed_filekeys, n_events=length(qc_part), n_pulser=n_pulser_fk, n_nonpulser=n_nonpulser_fk,
                n_single_pulse=count(qc_part.is_single_pulse),
                n_pulser_pass=count(qc_part.is_single_pulse .& pulser),
                n_nonpulser_pass=count(qc_part.is_single_pulse .& .!pulser),
                n_forced=count(qc_part.is_forced), n_forced_pass=count(qc_part.is_empty_trace .& qc_part.is_forced))
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
                (:nonpulser, :n_nonpulser, :n_nonpulser_pass, LegendMakie.BEGeOrange, "Non-pulser single pulse", false),
                (:forced_trigger, :n_forced, :n_forced_pass, :purple, "Forced trigger empty trace", true))
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

        log_det = log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(isempty(stability_message) ? 1 : -1), pulser_sf.is_single_pulse, forced_trigger_sf.is_empty_trace, n_pulser, n_forced, n_physics, n_invalid_dsp_single_pulse, stability_message))
        return (result = (filekey_summary = filekey_summary, func = qc_propfunc, survival_fractions = survival_fractions, n_pulser = n_pulser, n_forced = n_forced, n_single_pulse = n_single_pulse, n_physics = n_physics, n_invalid_dsp_single_pulse = n_invalid_dsp_single_pulse), warnings = stability_warnings, log = log_det, processed = true)
    end

    # get start time
    start_time = now()

    # Generate per-filekey QC data before calculating detector run summaries.
    result_cycles = parallel(filekeys, filekey_qcs, log_fk_nt, wpool; timeout=timeout, retry=false, process_name="$period-$run-QC-filekeys")

    result_qc = parallel(chinfo, det_qcs_phy, log_nt, wpool; timeout = timeout, retry = false, process_name = "$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished physics QC detector processing"

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
        end
    end
    # Count each global event once; run totals exclude removed filekeys, while their diagnostics remain saved.
    event_survival = PropDict(:filekey_summary => PropDict(), :survival_fractions => PropDict(),
        :n_detectors => length(event_detectors), :complete => all(haskey(res, :result) for (_, res) in result_cycles))
    for (fk, res) in result_cycles
        if haskey(res, :result)
            event_survival.filekey_summary[Symbol(fk)] = PropDict(pairs(merge(res.result.event_counts, (is_removed=fk in removed_filekeys,))))
        end
    end
    event_row_nt = NamedTuple{(:Selection, :Events, :Accepted, Symbol("Survival (%)")), Tuple{String, Int, Int, Float64}}
    event_rows = event_row_nt[]
    for (selection, n_key, k_key, label) in ((:all, :n_events, :n_pass, "All events"),
            (:pulser, :n_pulser, :n_pulser_pass, "Pulser"), (:forced_trigger, :n_forced, :n_forced_pass, "Forced trigger"),
            (:other, :n_other, :n_other_pass, "Other triggers"))
        n = sum(getproperty(res.result.event_counts, n_key) for (fk, res) in result_cycles if !(fk in removed_filekeys) && haskey(res, :result); init=0)
        k = sum(getproperty(res.result.event_counts, k_key) for (fk, res) in result_cycles if !(fk in removed_filekeys) && haskey(res, :result); init=0)
        efficiency = n == 0 ? NaN : 100 * k / n
        event_survival.survival_fractions[selection] = PropDict(:n_events => n, :n_pass => k, :efficiency => efficiency)
        push!(event_rows, event_row_nt((label, n, k, efficiency)))
    end
    pars_db[:event_survival] = event_survival
    writelprops(l200.par.rpars.qcs[period], pars_file, pars_db)
    writevalidity(l200.par.rpars.qcs, filekey, "$(period)/$(pars_file).yaml"; category=:phy)
    @info "Saved QC-survival pars to disk"

    warning_rows = reduce(vcat, (res.warnings for (_, res) in result_qc if haskey(res, :warnings)); init=warning_nt[])

    report_filename = get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))"))
    # plot the final survival fractions for all detectors from the parameter database
    fig = Makie.Figure(size = (max(1600, 18 * length(chinfo)), 600))
    ax = Makie.Axis(fig[1,1])
    LegendMakie.parameterplot!(ax, chinfo, pars_db, [:survival_fractions, :pulser, :is_single_pulse]; ylabel = "Survival fraction (%)", color = LegendMakie.AchatBlue, label = "Pulser", detector_status_colors = true)
    LegendMakie.parameterplot!(ax, chinfo, pars_db, [:survival_fractions, :forced_trigger, :is_empty_trace]; ylabel = "Survival fraction (%)", color = LegendMakie.BEGeOrange, label = "Forced trigger empty trace", detector_status_colors = true)
    ax.title = get_plottitle(filekey, :all, "QC Survival Fractions")
    Makie.axislegend(ax, position = :lb, orientation = :horizontal, framevisible = true, framecolor = :lightgray)
    LegendMakie.add_watermarks!(fig, ax; final = true)
    savelfig(LegendMakie.lsavefig, fig, l200, filekey, :all, :qc_survival_fractions; cleanup = false)

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_cycles, result_qc)]))
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total processing time: $(canonicalize(now() - start_time))")
    lreport!(report, qcs_phy_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Overall event QC survival")
    lreport!(report, "An event passes when every participating germanium row passes is_single_pulse, is_empty_trace, or is_crosstalk, using the event-tier detector selection and timestamp grouping. Each global event is counted once. Removed filekeys are excluded; no trigger multiplicity, energy, or PSD selection is applied. Other triggers exclude pulser and forced-trigger events.")
    lreport!(report, StructArray(event_rows))
    if !event_survival.complete
        lreport!(report, "Incomplete event summary: one or more filekeys failed. Counts cover only successfully summarized filekeys; see Filekey Results.")
    end
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
