function process_check_filekeys(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; category::Symbol, timeout::Int = 0)

    log_fkcheck = NamedTuple{(:Filekey, :Status, Symbol("Number of Processed Detectors"), Symbol("Failed Detectors"), Symbol("Total Time"), Symbol("Total Allocated"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    start_time = now()
    @info "Check raw filekeys for $period-$run in $category"
    filekey = start_filekey(l200, (period, run, category))
    if ismissing(filekey)
        @info "No $category data for $period-$run, skipping filekey checks."
        return
    end
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :geds, only_processable = true)
    detectors = chinfo.detector
    @info "Loaded channel info with $(length(detectors)) detectors"

    filekeys = filter(!in(bad_filekeys(l200; load_key = :all)), search_disk(FileKey, l200.tier[:raw, category, period, run]))

    function check_filekey(fk::FileKey)
        fk_timer = TimerOutput()
        filename = l200.tier[:raw, fk]
        @info "Checking file \"$filename\""
        is_ok::Bool = true
        failed_detectors = DetectorId[]
        @timeit fk_timer "$fk" begin
            try
                for det in detectors
                    @timeit fk_timer "$det" begin
                        try
                            read_ldata(:daqenergy, l200, DataTier(:raw), fk, det)
                        catch e
                            @error "Error while checking detector $det in \"$filename\": $(e)"
                            push!(failed_detectors, det)
                            is_ok = false
                        end
                    end
                end
            catch e
                @error "Error while checking file \"$filename\": $(e)"
                is_ok = false
            end
        end

        total_time = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(fk_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(fk_timer))
        log_fk = log_fkcheck((fk, ProcessStatus(is_ok), "$(length(detectors))", string.(failed_detectors), total_time, total_allocated, ""))
        return (result = is_ok, timer = fk_timer, log = log_fk, processed = true)
    end

    result_fkcheck = Dict(parallel(filekeys, check_filekey, log_fkcheck, wpool; timeout, retry = false, process_name = "$period-$run-$(nameof(var"#self#"))-$category"))

    good_filekeys = [fk for fk in keys(result_fkcheck) if result_fkcheck[fk].result]

    broken_filekeys = [fk for fk in keys(result_fkcheck) if !result_fkcheck[fk].result]

    report = lreport()
    lreport!(report, "# Filekey Check", "Date of processing: $(now())", "Total processing time: $(canonicalize(now() - start_time))")
    lreport!(report, "# Metadata", create_metadatatbl(filekey))
    lreport!(report, "# Good Filekeys", join(("- `$fk`" for fk in sort(good_filekeys)), "\n"))
    lreport!(report, "# Broken Filekeys", join(("- `$fk`" for fk in sort(broken_filekeys)), "\n"))
    lreport!(report, "# Results", StructArray([res.log for res in values(result_fkcheck)]))
    writelreport(get_rreportfilename(l200, filekey, :check_filekeys), report)

    flush(stdout)
end
