function process_dsp_aux_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)

    @info "Process auxiliary detector DSP for period $period and run $run"

    filekeys = filter(!in(bad_filekeys(l200; load_key=:unprocessable)), search_disk(FileKey, l200.tier[:raw, :phy, period, run]))

    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey)
    @info "Loaded channel info with $(length(chinfo)) channels"

    chinfo_aux = filterby(get_aux_evt_detsel_propfunc(l200, filekey))(chinfo)
    @info "Loaded auxiliary detectors: $(join(string.(chinfo_aux.detector), ", "))"

    # create log line Tuple
    log_nt = NamedTuple{(:Detector, :Channel, :Status, Symbol("Number Events"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    function plot_dsp_aux_crosscheck(dsp_data, det, energy_type, threshold)
        energy = filter(x -> isfinite(x) && x > 0, ustrip.(getproperty(dsp_data, energy_type)))
        p = LegendMakie.lhist(energy;
            figsize = (700, 450),
            title = get_plottitle(filekey, det, "Auxiliary DSP cross-check"),
            xlabel = "$energy_type (ADC)",
            ylabel = "Counts / bin",
            xscale = Makie.log10,
            yscale = Makie.log10,
            xlims = extrema(energy),
            legend_position = :none,
        )
        ax = Makie.current_axis()
        Makie.vlines!(ax, [threshold]; color=LegendMakie.BEGeOrange, linestyle=:dash,
            linewidth=2, label="$energy_type > $threshold")
        Makie.axislegend(ax; position=:lt)
        p
    end

    function det_dsp_aux(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector

        @info "Processing DSP for auxiliary detector $det ($ch)"
        dspfilename = l200.tier[:jlaux, filekey, det]

        if !reprocess && isfile(dspfilename)
            try
                n_evts = lh5open(dspfilename, "r") do dsp_file
                    length(dsp_file[det, :jlaux])
                end
                @info "DSP for auxiliary detector $det ($ch) already exists, skip"
                return (result = (n_evts = n_evts,), processed = false,
                    log = log_nt((det, ch, ProcessStatus(1), "$n_evts", "Already processed --> skipped.")))
            catch e
                @warn "Error reading existing DSP file for auxiliary detector $det ($ch): $(truncate_error(e))"
                @info "Reprocess auxiliary detector $det ($ch)"
            end
        end

        try
            raw_data = read_ldata(l200, DataTier(:raw), filekeys, det)

            dsp_config_pd = dataprod_config(l200).dsp(filekey)
            dsp_config_pd_det = merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict()))
            dsp_config_det = DSPConfig(dsp_config_pd_det)
            @debug "Loaded DSP config: $(lstring(dsp_config_det))"

            @debug "Generate DSP for $det"
            dsp_data = getfield(LegendDSP, Symbol(dsp_config_pd.additional_detectors[det]))(raw_data, dsp_config_det)

            @debug "Calibrate DSP data"
            evt_config_pd_det = dataprod_config(l200).evt(filekey).aux[det]
            auxcal_pf = get_aux_cal_propfunc(l200, filekey, det)
            cal_output = auxcal_pf.(dsp_data)

            merged_table = merge(columns(dsp_data), columns(cal_output))

            @info "Generate auxiliary DSP cross-check plot for $det"
            energy_type, threshold = split(evt_config_pd_det.cal.aux_trig, '>'; limit=2)
            energy_type, threshold = Symbol(strip(energy_type)), parse(Float64, strip(threshold))
            p = plot_dsp_aux_crosscheck(dsp_data, det, energy_type, threshold)
            savelfig(LegendMakie.lsavefig, p, l200, filekey, det, :dsp_aux_energy)

            @info "Write DSP data to disk"
            write_files(dspfilename, use_cache=true, mode = CreateOrReplace()) do outfilename
                lh5open(outfilename, "w") do outdata
                    outdata[det, :jlaux] = merged_table
                end
            end

            log_det = log_nt((det, ch, ProcessStatus(1), "$(length(dsp_data))", ""))
            @info "Finished DSP for auxiliary detector $det ($ch): $(length(dsp_data)) events"

            return (result = (n_evts = length(dsp_data),), processed = true, log = log_det)
        catch e
            @error "Error while running DSP for auxiliary detector $det: $(e)"
            return (processed = false, log = log_nt((det, ch, ProcessStatus(0), "0", "$e")))
        end
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_dsp_aux = parallel(chinfo_aux, det_dsp_aux, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished auxiliary detector DSP"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_dsp_aux))

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    flush(stdout)
end
