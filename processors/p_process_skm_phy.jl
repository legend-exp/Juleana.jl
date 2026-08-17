function p_process_skm_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod,; reprocess::Bool=false, timeout::Int=0, only_first_period::Bool=true)
    
    @info "Event skimmed tier for runs containing period $period"

    rinfo = runinfo(l200, period) |> filterby(@pf $phy.is_analysis_run)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).phy.startkey
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    exposure = get_exposure(l200, chinfo.detector, period; is_analysis_run=true, check_pf=@pf $processable && $usability == :on && $psd_usability == :on && $det_type != :coax)
    @info "Total exposure: $(round(unit(exposure), exposure, digits=2))"

    if reprocess @info "Reprocess all runs" else @info "Only process runs not found" end

    # create log line Tuple
    log_nt = NamedTuple{(:Filekey, :Status, Symbol("SF of Events after PSD"), Symbol("SF of Events after LAr"), Symbol("SF of Events after LAr & PSD"), Symbol("Total Time"), Symbol("Total Allocated"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)    
    
    function skm_fk(fk::FileKey)
        r = fk.run
        p = fk.period

        filekeys = filter(!in(bad_filekeys(l200; load_key=:all)), search_disk(FileKey, l200.tier[:jlevt, :phy, p, r]))
        @info "Found $(length(filekeys)) filekeys for run $r in period $p"

        @info "Processing run $r in period $p"
        dsp_timer = TimerOutput()
        skmfilename = l200.tier[:jlskm, fk]
        @info "Using output file: $(basename(skmfilename))"
        
        # start processing
        n_psd, n_lar, n_larpsd = 0, 0, 0
        write_files(skmfilename, use_cache = true, mode = CreateOrModify()) do outfilename
            if reprocess && isfile(outfilename)
                @info "Reprocess $(basename(skmfilename)), remove old Evt."
                rm(outfilename, force=true)
                rm(skmfilename, force=true)
            elseif isfile(outfilename)
                @info "File $(basename(skmfilename)) already exists, skip"
                n_psd, n_lar, n_larpsd = lh5open(outfilename, "r") do ds
                    skm_data = ds[:skm][:]
                    n_psd = mean(skm_data.geds.is_valid_psd) * 100u"percent"
                    n_lar = mean(skm_data.ged_spm.is_valid_lar) * 100u"percent"
                    n_larpsd = mean(skm_data.geds.is_valid_psd .&& skm_data.ged_spm.is_valid_lar) * 100u"percent"
                    n_psd, n_lar, n_larpsd
                end
                return (timer = dsp_timer, log = log_nt((fk, ProcessStatus(1), n_larpsd, n_lar, n_psd, "", "", "")), processed = false)
            end

            # open output file
            @timeit dsp_timer "Evt" begin
                # generate evt level table
                out_t = nothing
                try
                    skm_sel_pf = @pf !$aux.pulser.aux_trig && !$aux.forcedtrigger.aux_trig && $ged_pmt.is_valid_muon && $geds.is_valid_qc && $geds.is_valid_trig && $geds.is_valid_hit && $geds.multiplicity == 1 && $geds.max_e_cusp_ctc_cal > 500.0u"keV"
                    # filter file by file while reading - a whole run's jlevt (up to ~35 GB) never sits in memory
                    out_t = read_ldata(l200, DataTier(:jlevt), filekeys; filterby = skm_sel_pf)[:]
                catch e
                    @error "Error processing $fk: $(truncate_error(e))"
                    throw(ErrorException("Error processing $fk: $(truncate_error(e))"))
                end
                # get number of forced, physical and pulser triggers
                n_psd = mean(out_t.geds.is_valid_psd) * 100u"percent"
                @debug "SF after PSD: $(round(u"percent", n_psd, digits=2))"
                n_lar = mean(out_t.ged_spm.is_valid_lar) * 100u"percent"
                @debug "SF after LAr: $(round(u"percent", n_lar, digits=2))"
                n_larpsd = mean(out_t.geds.is_valid_psd .&& out_t.ged_spm.is_valid_lar) * 100u"percent"
                @debug "SF after LAr & PSD: $(round(u"percent", n_larpsd, digits=2))"
                lh5open(outfilename, "cw") do ds
                    ds[:jlskm] = LegendEventAnalysis._fix_vov(out_t)
                end
            end
            
            @info "Finished processing $(basename(skmfilename))"
        end

        # create total timer by summing over memory usage and time
        total_time      = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(dsp_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(dsp_timer))
        
        # create log
        log_fk = log_nt((fk, ProcessStatus(1), n_larpsd, n_lar, n_psd, total_time, total_allocated, ""))

        return (timer = dsp_timer, log = log_fk, processed = true)
    end

    # get start time
    start_time = now()

    result_skm = parallel(rinfo.phy.startkey, skm_fk, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished skimmed file processing"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, skm_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_skm))

    @info "Write log report"
    writelreport(get_preportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    # flush stdout
    flush(stdout)

    return true
end

