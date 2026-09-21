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
    log_nt = NamedTuple{(:Detector, :Channel, :Status, Symbol("K-40 SF"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    function det_qcs_phy(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector

        qcsfilename = l200.tier[:jlqcs, filekey, det]
        qc_config_det = merge(qc_config.default, get(qc_config, chinfo_det.usability, PropDict()), get(qc_config, det, PropDict()))

        if !reprocess && haskey(pars_db, det) && isfile(qcsfilename)
            sf = pars_db[det].survival_fractions
            log_det = log_nt((det, ch, ProcessStatus(1), sf.K40.is_single_pulse, "Already processed --> skipped."))
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

        # calculate survival fractions
        flag_names = collect(columnnames(qc_flags))
        e_cal = get_ged_cal_propfunc(l200, filekey, det).(data_det).e_trap_cal
        valid_energy = isfinite.(e_cal)
        k40_config = qc_config_det.k40
        k40_window = [k40_config.left_window_size, k40_config.right_window_size]
        k40_sf_values = map(flag_names) do flag_name
            result_k40, _ = get_peak_survival_fraction(e_cal[valid_energy], k40_config.peak, k40_window, getproperty(qc_flags, flag_name)[valid_energy]; fit_func = Symbol(k40_config.fit_func), uncertainty = true)
            result_k40.sf
        end
        k40_sf = NamedTuple{Tuple(flag_names)}(Tuple(k40_sf_values))
        survival_fractions = (K40=k40_sf,)

        # plot survival fractions
        x = collect(eachindex(flag_names))
        k40_sf_plot = mvalue.(ustrip.(u"percent", collect(values(k40_sf))))
        fig = Makie.Figure(size = (max(800, 55 * length(flag_names)), 500))
        ax = Makie.Axis(fig[1,1], title = get_plottitle(filekey, det, "QC Survival Fractions"), xlabel = "QC flag", ylabel = "Survival fraction (%)", xticks = (x, string.(flag_names)), xticklabelrotation = pi / 3, limits = ((0.3, length(flag_names) + 0.7), (0, 105)))
        Makie.barplot!(ax, x, k40_sf_plot, width = 0.6, color = LegendMakie.BEGeOrange)
        LegendMakie.add_watermarks!(final = true)
        savelfig(LegendMakie.lsavefig, fig, l200, filekey, det, :qc_survival_fractions)

        # write QC flags
        write_files(qcsfilename, use_cache = true, mode = CreateOrReplace()) do outfilename
            lh5open(outfilename, "w") do outdata
                outdata[:jlqcs, det] = qc_flags
            end
        end

        log_det = log_nt((det, ch, ProcessStatus(1), k40_sf.is_single_pulse, "-"))
        return (result = (func = qc_propfunc, survival_fractions = survival_fractions), log = log_det, processed = true)
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

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total processing time: $(canonicalize(now() - start_time))")
    lreport!(report, qcs_phy_log_text)
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
