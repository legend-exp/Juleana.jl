function process_check_filekeys_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; timeout::Int = 0)

    @info "Check raw filekeys for $period-$run in phy"
    filekey = start_filekey(l200, (period, run, :phy))
    if ismissing(filekey)
        @info "No phy data for $period-$run, skipping filekey checks."
        return
    end
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system = :geds, only_processable = true)
    detectors = chinfo.detector
    @info "Loaded channel info with $(length(detectors)) detectors"

    filekeys = filter(!in(bad_filekeys(l200; load_key = :all)), search_disk(FileKey, l200.tier[:raw, :phy, period, run]))

    # create log line Tuple
    log_fkcheck = NamedTuple{(:Filekey, :Status, Symbol("Number of Processed Detectors"), Symbol("Failed Detectors"), Symbol("Total Time"), Symbol("Total Allocated"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    function check_filekey(fk::FileKey)
        fk_timer = TimerOutput()
        filename = l200.tier[:raw, fk]
        @info "Checking file \"$filename\""
        failed_detectors = DetectorId[]
        errors = String[]
        @timeit fk_timer "$fk" begin
            for det in detectors
                @timeit fk_timer "$det" begin
                    try
                        read_ldata(:daqenergy, l200, DataTier(:raw), fk, det)
                    catch e
                        @error "Error while checking detector $det in \"$filename\": $(truncate_error(e))"
                        push!(failed_detectors, det)
                        push!(errors, "$det: $(truncate_error(e))")
                    end
                end
            end
        end

        total_time = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(fk_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(fk_timer))
        log_fk = log_fkcheck((fk, ProcessStatus(isempty(failed_detectors)), "$(length(detectors))", string.(failed_detectors), total_time, total_allocated, join(errors, "; ")))
        return (result = isempty(failed_detectors), timer = fk_timer, log = log_fk, processed = true)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_fkcheck = Dict(parallel(filekeys, check_filekey, log_fkcheck, wpool; timeout, retry = false, process_name = "$period-$run-$(nameof(var"#self#"))"))

    good_filekeys = [fk for (fk, result) in result_fkcheck if haskey(result, :result) && result.result]

    broken_filekeys = filter(!in(good_filekeys), collect(keys(result_fkcheck)))

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [master_status(result_fkcheck)]))
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, "# Metadata", create_metadatatbl(filekey))
    lreport!(report, "# Good Filekeys", join(("- `$fk`" for fk in sort(good_filekeys)), "\n"))
    lreport!(report, "# Broken Filekeys", join(("- `$fk`" for fk in sort(broken_filekeys)), "\n"))
    lreport!(report, "# Results", create_logtbl(result_fkcheck))
    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    # flush stdout
    flush(stdout)
end
