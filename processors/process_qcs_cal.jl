function process_qcs_cal(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)

    @info "Generate calibration QC flags for period $period and run $run"

    filekeys = filter(!in(bad_filekeys(l200; load_key=:all)), search_disk(FileKey, l200.tier[:jldsp, :cal, period, run]))
    raw_filekeys = filter(!in(bad_filekeys(l200; load_key=:all)), search_disk(FileKey, l200.tier[:raw, :cal, period, run]))
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
    log_nt = NamedTuple{(:Detector, :Channel, :Status, Symbol("Pulser SF"), Symbol("Tl-208 FEP SF"), Symbol("Number Pulser Events"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    # load pulser timestamps
    chinfo_puls = channelinfo(l200, filekey, Symbol(qc_config.pulser.puls_detector))
    det_puls = chinfo_puls.detector
    @info "Load pulser timestamps for $det_puls"
    pulser_timestamps = read_ldata(:timestamp, l200, DataTier(:raw), raw_filekeys, det_puls).timestamp
    @info "Loaded $(length(pulser_timestamps)) pulser timestamps"

    function det_qcs_cal(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector

        qcsfilename = l200.tier[:jlqcs, filekey, det]
        qc_config_det = merge(qc_config.default, get(qc_config, chinfo_det.usability, PropDict()), get(qc_config, det, PropDict()))
        energy_config_det = merge(energy_config.default, get(energy_config, det, PropDict()))

        if !reprocess && haskey(pars_db, det) && isfile(qcsfilename)
            sf = pars_db[det].survival_fractions
            log_det = log_nt((det, ch, ProcessStatus(1), sf.pulser.is_single_pulse, sf.Tl208FEP.is_single_pulse, pars_db[det].n_pulser, "Already processed --> skipped."))
            @debug "Detector $det already processed"
            return (processed = false, log = log_det)
        end

        @debug "Processing detector $det ($ch)"
        data_det = read_ldata(l200, DataTier(:jldsp), filekeys, det)
        if length(data_det) < 5000
            @error "Not enough data points for detector $det ($ch), skip"
            throw(ErrorException("Not enough data points for detector $det ($ch)"))
        end

        # generate QC flags
        qc_labels = Table(ljl_propfunc(qc_config_det.labels).(data_det))
        qc_flags = Table(merge(
            columns(qc_labels),
            (
                is_single_pulse = ljl_propfunc(qc_config_det.is_single_pulse).(qc_labels),
            ),
        ))
        qc_propfunc = merge(qc_config_det.labels, PropDict(:is_single_pulse => qc_config_det.is_single_pulse))

        # generate pulser tags
        pulser_config_det = merge(qc_config.pulser.default, get(qc_config.pulser, det, PropDict()))
        is_pulser = flag_coincidences(data_det.timestamp, pulser_timestamps; ts_window = pulser_config_det.puls_ts_window)
        @debug "Found $(count(is_pulser)) pulser events"

        # calculate survival fractions
        qc = Table(merge(columns(qc_flags), (is_pulser = is_pulser,)))
        flag_names = collect(columnnames(qc_flags))
        n_pulser = count(is_pulser)
        pulser_sf_values = [count(getproperty(qc_flags, flag_name)[is_pulser]) / n_pulser * 100u"percent" for flag_name in flag_names]
        pulser_sf = NamedTuple{Tuple(flag_names)}(Tuple(pulser_sf_values))

        fep_idx = findfirst(==(:Tl208FEP), Symbol.(energy_config_det.th228_names))
        valid_energy = isfinite.(data_det.e_trap) .&& (data_det.e_trap .> 0) .&& .!is_pulser
        e_uncal = collect(data_det.e_trap[valid_energy])
        quantile_perc = if energy_config_det.quantile_perc isa String parse(Float64, energy_config_det.quantile_perc) else energy_config_det.quantile_perc end
        result_simple, _ = simple_calibration(e_uncal, energy_config_det.th228_lines, energy_config_det.left_window_sizes, energy_config_det.right_window_sizes,; calib_type = :th228, quantile_perc = quantile_perc, binning_peak_window = energy_config_det.binning_peak_window)
        e_cal = e_uncal .* result_simple.c
        fep_peak = energy_config_det.th228_lines[fep_idx]
        fep_window = [energy_config_det.left_window_sizes[fep_idx], energy_config_det.right_window_sizes[fep_idx]]
        fep_fit_func = Symbol(energy_config_det.th228_fit_func[fep_idx])
        ones_vec = ones(length(e_cal))
        fep_sf_values = map(flag_names) do flag_name
            result_fep, _ = get_peak_survival_fraction(ones_vec, e_cal, fep_peak, fep_window, -Inf, BitVector(getproperty(qc_flags, flag_name)[valid_energy]); fit_func = fep_fit_func, uncertainty = true)
            result_fep.sf
        end
        fep_sf = NamedTuple{Tuple(flag_names)}(Tuple(fep_sf_values))
        survival_fractions = (pulser=pulser_sf, Tl208FEP=fep_sf)

        # plot energy spectra before and after QC
        data_det_after_qc = data_det[qc_flags.is_single_pulse .&& .!is_pulser]
        data_pulser = data_det[qc_flags.is_single_pulse .&& is_pulser]
        fig = Makie.Figure(size = (620, 400))
        binwidth = 8 * 15
        hall = StatsBase.fit(StatsBase.Histogram, data_det.e_trap, range(0, maximum(data_det_after_qc.e_trap), step = binwidth))
        hqc = StatsBase.fit(StatsBase.Histogram, data_det_after_qc.e_trap, range(0, maximum(data_det_after_qc.e_trap), step = binwidth))
        hp = StatsBase.fit(StatsBase.Histogram, data_pulser.e_trap, range(0, maximum(data_det_after_qc.e_trap), step = binwidth))
        ax = Makie.Axis(fig[1,1], xlabel = "Energy (ADC)", ylabel = "Counts / $(binwidth) ADC", xtickformat = x -> string.(round.(Int,x)), yscale = Makie.log10, limits = (extrema(first(hall.edges)), (0.9, maximum(hall.weights) * 1.2)), title = get_plottitle(filekey, det, "Trap Raw Energy Spectrum"))
        Makie.stephist!(ax, StatsBase.midpoints(first(hall.edges)), weights = replace(hall.weights, 0 => 1e-10), bins = first(hall.edges), color = LegendMakie.BEGeOrange, label = "Trap - before QC")
        Makie.stephist!(ax, StatsBase.midpoints(first(hqc.edges)), weights = replace(hqc.weights, 0 => 1e-10), bins = first(hqc.edges), color = LegendMakie.AchatBlue, label = "Trap - after QC")
        Makie.stephist!(ax, StatsBase.midpoints(first(hp.edges)), weights = replace(hp.weights, 0 => 1e-10), bins = first(hp.edges), color = :red, label = "Pulser")
        Makie.axislegend(ax, position = :rt, framevisible = true, framecolor = :lightgray)
        LegendMakie.add_watermarks!(final = true)
        savelfig(LegendMakie.lsavefig, fig, l200, filekey, det, :raw_energy_e_trap)

        # plot survival fractions
        x = collect(eachindex(flag_names))
        pulser_sf_plot = mvalue.(ustrip.(u"percent", collect(values(pulser_sf))))
        fep_sf_plot = mvalue.(ustrip.(u"percent", collect(values(fep_sf))))
        fig = Makie.Figure(size = (max(800, 55 * length(flag_names)), 500))
        ax = Makie.Axis(fig[1,1], title = get_plottitle(filekey, det, "QC Survival Fractions"), xlabel = "QC flag", ylabel = "Survival fraction (%)", xticks = (x, string.(flag_names)), xticklabelrotation = pi / 3, limits = ((0.3, length(flag_names) + 0.7), (0, 105)))
        Makie.barplot!(ax, x .- 0.2, pulser_sf_plot, width = 0.38, color = LegendMakie.AchatBlue, label = "Pulser")
        Makie.barplot!(ax, x .+ 0.2, fep_sf_plot, width = 0.38, color = LegendMakie.BEGeOrange, label = "Tl-208 FEP")
        Makie.axislegend(ax, position = :lb, orientation = :horizontal, framevisible = true, framecolor = :lightgray)
        LegendMakie.add_watermarks!(final = true)
        savelfig(LegendMakie.lsavefig, fig, l200, filekey, det, :qc_survival_fractions)

        # write QC flags
        write_files(qcsfilename, use_cache = true, mode = CreateOrReplace()) do outfilename
            lh5open(outfilename, "w") do outdata
                outdata[det, :jlqcs] = qc
            end
        end

        log_det = log_nt((det, ch, ProcessStatus(1), pulser_sf.is_single_pulse, fep_sf.is_single_pulse, n_pulser, "-"))
        return (result = (func = qc_propfunc, survival_fractions = survival_fractions, n_pulser = n_pulser), log = log_det, processed = true)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_qc = parallel(chinfo, det_qcs_cal, log_nt, wpool; timeout = timeout, retry = false, process_name = "$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished QC detector processing"

    pars_db = create_pars(pars_db, result_qc)
    writelprops(l200.par.rpars.qcs[period], run, pars_db)
    writevalidity(l200.par.rpars.qcs, filekey, (period, run); category=:cal)
    @info "Saved QC-survival pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total processing time: $(canonicalize(now() - start_time))")
    lreport!(report, qcs_cal_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_qc))

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    # flush stdout
    flush(stdout)
end
