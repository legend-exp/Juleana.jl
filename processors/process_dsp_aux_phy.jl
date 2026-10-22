function process_dsp_aux_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)

    @info "Process auxiliary detector DSP for period $period and run $run"

    filekeys = filter(!in(bad_filekeys(l200; load_key=:unprocessable)), search_disk(FileKey, l200.tier[:raw, :phy, period, run]))

    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey)
    @info "Loaded channel info with $(length(chinfo)) channels"

    chinfo_aux = filterby(get_aux_evt_detsel_propfunc(l200, filekey))(chinfo)
    @info "Loaded auxiliary detectors: $(join(string.(chinfo_aux.detector), ", "))"

    dsp_config_pd = dataprod_config(l200).dsp(filekey)
    evt_config_pd = dataprod_config(l200).evt(filekey)

    log_nt = NamedTuple{(:Detector, :usability, :Status, Symbol("Number Events"), :Error)}
    log_fk_nt = NamedTuple{(:Filekey, :Status, Symbol("Processed Detectors"), Symbol("Failed Detectors"), :Error)}
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    function filekey_dsp_aux(fk::FileKey)
        dspfilename = l200.tier[:jlaux, fk]
        n_processed = 0
        failed_detectors = DetectorId[]
        write_files(dspfilename, use_cache=true, mode=CreateOrModify()) do outfilename
            if reprocess && isfile(outfilename)
                rm(outfilename, force=true)
            end
            lh5open(outfilename, "cw") do outdata
                for chinfo_det in chinfo_aux
                    ch, det = chinfo_det.channel, chinfo_det.detector
                    if haskey(outdata, "jlaux/$det")
                        @info "DSP for auxiliary detector $det ($ch) in $fk already exists, skip"
                        continue
                    end
                    @info "Processing DSP for auxiliary detector $det ($ch) in $fk"
                    try
                        dsp_config_pd_det = merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict()))
                        dsp_config_det = DSPConfig(dsp_config_pd_det)
                        dsp_function = Symbol(dsp_config_pd.additional_detectors[det])
                        raw_fields = Tuple(Symbol.(dsp_config_pd.raw_fields[dsp_function]))
                        raw_data = read_ldata(raw_fields, l200, DataTier(:raw), fk, det)
                        dsp_data = getfield(LegendDSP, dsp_function)(raw_data, dsp_config_det)
                        auxcal_pf = get_aux_cal_propfunc(l200, filekey, det)
                        cal_output = auxcal_pf.(dsp_data)
                        outdata[:jlaux, det] = merge(columns(dsp_data), columns(cal_output))
                        n_processed += 1
                    catch e
                        @error "Error while running DSP for auxiliary detector $det in $fk: $(truncate_error(e))"
                        push!(failed_detectors, det)
                    end
                end
            end
        end
        return (processed=n_processed > 0,
            log=log_fk_nt((fk, ProcessStatus(isempty(failed_detectors) ? 1 : 0), n_processed, string.(failed_detectors), "")))
    end

    start_time = now()
    result_filekeys = parallel(filekeys, filekey_dsp_aux, log_fk_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    result_dsp_aux = map(chinfo_aux) do chinfo_det
        det = chinfo_det.detector
        # Release the previous detector's run-level data before reading the next one on the main process.
        GC.gc()
        try
            energy_type, threshold = split(evt_config_pd.aux[det].cal.aux_trig, '>'; limit=2)
            energy_type, threshold = Symbol(strip(energy_type)), parse(Float64, strip(threshold))
            # Read only the plotted columns of the run; e_max and t_max exist only for some DSP functions.
            plot_tmax = issubset((:e_max, :t_max), propertynames(read_ldata(l200, DataTier(:jlaux), first(filekeys), det)))
            dsp_data = read_ldata(Tuple(unique([energy_type; plot_tmax ? [:e_max, :t_max] : Symbol[]])), l200, DataTier(:jlaux), filekeys, det)
            energy = ustrip.(getproperty(dsp_data, energy_type))
            n_evts = length(energy)
            filter!(x -> isfinite(x) && x > 0, energy)
            if !isempty(energy)
                log_min = floor(Int, log10(minimum(energy)))
                log_max = max(log_min + 1, floor(Int, log10(max(maximum(energy), threshold))) + 1)
                bins = 10.0 .^ (log_min:0.05:log_max)
                p = LegendMakie.lhist(fit(Histogram, energy, bins);
                    figsize=(700, 450), title=get_plottitle(filekey, det, "Auxiliary DSP cross-check"),
                    xlabel="$energy_type (ADC)", ylabel="Counts / bin", yscale=Makie.log10,
                    xticks=Makie.LogTicks(Makie.WilkinsonTicks(5; k_min=3)), juleana_logo=false)
                ax = Makie.current_axis()
                ax.xscale = Makie.log10
                Makie.vlines!(ax, [threshold]; color=LegendMakie.BEGeOrange, linestyle=:dash,
                    linewidth=2, label="$energy_type > $threshold")
                Makie.axislegend(ax; position=:rt)
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, :dsp_aux_energy)
            end
            # e_max versus t_max with logarithmic energy bins and count colors.
            if plot_tmax
                @info "Generate auxiliary DSP energy versus maximum-time plot for $det"
                t_max = ustrip.(u"µs", dsp_data.t_max)
                e_max = ustrip.(dsp_data.e_max)
                valid = isfinite.(t_max) .& isfinite.(e_max) .& (e_max .> 0)
                t_max, e_max = t_max[valid], e_max[valid]
                log_min = floor(log10(minimum(e_max)))
                log_max = max(log_min + 1, ceil(log10(maximum(e_max))))
                energy_bins = 10.0 .^ range(log_min, log_max; length=201)
                energy_bins[end] = nextfloat(last(energy_bins))
                time_bins = StatsBase.histrange(t_max, 200)
                p = LegendMakie.lhist(StatsBase.fit(StatsBase.Histogram, (t_max, e_max), (time_bins, energy_bins));
                    figsize = (800, 500),
                    title = get_plottitle(filekey, det, "e_max vs. t_max"),
                    xlabel = "t_max (µs)",
                    ylabel = "e_max (ADC)",
                    yscale = Makie.log10,
                    colorbarlabel = "Counts / bin",
                    juleana_logo = false,
                )
                savelfig(LegendMakie.lsavefig, p, l200, filekey, det, :dsp_aux_energy_tmax)
            end

            chinfo_det => (result=(n_evts=n_evts,), processed=true,
                log=log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(1), "$n_evts", "")))
        catch e
            @error "Error plotting auxiliary DSP for detector $det: $(truncate_error(e))"
            chinfo_det => (processed=false,
                log=log_nt((det, detector_status(chinfo_det.usability), ProcessStatus(0), "-", truncate_error(e))))
        end
    end

    @info "Finished auxiliary detector DSP"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_filekeys, result_dsp_aux)]))
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_dsp_aux))
    lreport!(report, "# Filekeys")
    lreport!(report, create_logtbl(result_filekeys))

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    flush(stdout)
end
