function process_aux_dsp_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)

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

    function det_aux_dsp(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector

        @info "Processing DSP for auxiliary detector $det ($ch)"
        dspfilename = l200.tier[:jlaux, filekey, det]

        try
            raw_data = read_ldata(l200, DataTier(:raw), filekeys, det)

            dsp_config_pd = dataprod_config(l200).dsp(filekey)
            dsp_config_pd_det = merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict()))
            dsp_config_det = DSPConfig(dsp_config_pd_det)
            @debug "Loaded DSP config: $(lstring(dsp_config_det))"

            @debug "Generate DSP for $det"
            dsp_data = getfield(LegendDSP, Symbol(dsp_config_pd.additional_detectors[det]))(raw_data, dsp_config_det)

            @debug "Calibrate DSP data"
            auxcal_pf = get_aux_cal_propfunc(l200, filekey, det)
            cal_output = auxcal_pf.(dsp_data)

            merged_table = merge(columns(dsp_data), columns(cal_output))

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
    result_aux_dsp = parallel(chinfo_aux, det_aux_dsp, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished auxiliary detector DSP"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_aux_dsp))

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    flush(stdout)
end