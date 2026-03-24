#!/usr/bin/env julia
function process_peak_split(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)

    @info "Process peak splitting for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) detectors"

    raw_config = dataprod_config(l200).raw(filekey)

    if reprocess @info "Reprocess all detectors" end

    # create log line Tuple
    log_fkcheck = NamedTuple{(:Filekey, :Status, Symbol("Number of Processed Detectors"), Symbol("Failed Detectors"), Symbol("Total Time"), Symbol("Total Allocated"), :Error)}
    log_peaksplit = NamedTuple{(:Detector, :Channel, :Status, Symbol("Number of FEP Events"), Symbol("Number of SEP Events"), Symbol("Total Time"), Symbol("Total Allocated"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # get start time
    start_time = now()

    # get input and output directories
    input_datadir = l200.tier[:raw, :cal, period, run]
    output_datadir = mkpath(l200.tier[:jlpeaks, :cal, period, run])
    @assert isdir(input_datadir) && isdir(output_datadir)

    # get detectors
    detectors = chinfo.detector

    @info "Expecting $(length(detectors)) detectors each file in \"$input_datadir\"."

    function get_daqenergy_for_det(filelist::AbstractVector{<:AbstractString}, det::DetectorId)
        fast_flatten([
            LHDataStore(
                ds -> begin
                    @debug "Reading DAQ energy for detector $det from \"$(ds.data_store.filename)\""
                    ds[det].raw.daqenergy[:]
                end,
                filename
            ) for filename in filelist
        ])
    end

    function channels_in_file(filename)
        LHDataStore(filename) do ds
            sort(chname2int.(filter(startswith("ch"), keys(ds))))
        end
    end

    # get keylists and check files
    keylist_filename = joinpath(output_datadir, "filekeys.txt")
    broken_keylist_filename = joinpath(output_datadir, "broken_filekeys.txt")

    if isfile(keylist_filename) && !reprocess
        filekeys = read_filekeys(keylist_filename)
        files_checked = true
    else
        filekeys = search_disk(FileKey, l200.tier[:raw, :cal, period, run])
        files_checked = false
    end
    isempty(filekeys) && error("No files found in \"$input_datadir\"")

    # check for broken filekeys
    result_fkcheck = nothing
    @info "Check files for broken filekeys."
    if !files_checked
        @info "Checking files in \"$input_datadir\"."
        function check_filekey(fk::FileKey)
            fk_timer = TimerOutput()
            filename = l200.tier[:raw, fk]
            @info "Checking file \"$filename\""
            is_ok::Bool = true
            failed_detectors = DetectorId[]
            @timeit fk_timer "$fk" begin
                try
                    LHDataStore(filename) 
                catch e
                    @error "Error while checking file \"$(filename)\": $(e)"
                    is_ok = false
                else
                    LHDataStore(filename) do ds
                        for det in detectors
                            @timeit fk_timer "$det" begin
                                try
                                    haskey(ds, "$det") || throw(ErrorException("Detector $det not found in \"$(filename)\""))
                                catch e
                                    @error "Error while checking detector $det in \"$(filename)\": $(e)"
                                    push!(failed_detectors, det)
                                    is_ok = false
                                end
                            end
                        end
                    end
                end
            end

            # create total timer by summing over memory usage and time
            total_time      = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(fk_timer)))
            total_allocated = Base.format_bytes(TimerOutputs.totallocated(fk_timer))

            # create log
            log_fk = log_fkcheck((fk, ProcessStatus(1), "$(length(detectors))", string.(failed_detectors), total_time, total_allocated, ""))
            return (result = is_ok, timer = fk_timer, log = log_fk, processed = true)
        end

        result_fkcheck = Dict(parallel(filekeys, check_filekey, log_fkcheck, wpool,; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))"))

        if !all(v -> hasproperty(v, :result), values(result_fkcheck))
            error("Some filekeys failed during checking due to unknown reason.")
        end

        good_filekeys = [fk for fk in keys(result_fkcheck) if result_fkcheck[fk].result]
        write_filekeys(keylist_filename, good_filekeys)

        broken_filekeys = [fk for fk in keys(result_fkcheck) if !(result_fkcheck[fk].result)]
        if !isempty(broken_filekeys)
            @error "Detected broken files for filekeys" broken_filekeys
            write_filekeys(broken_keylist_filename, broken_filekeys)
        end

        filekeys = good_filekeys
    else
        @info "Files already checked, use filelist from \"$keylist_filename\" instead."
    end


    # split peaks from raw waveforms
    function split_peak_det(chinfo_det::NamedTuple)

        ch  = chinfo_det.channel
        det = chinfo_det.detector

        @info "Processing detector $det ($ch)"

        raw_config_det = merge(raw_config.default, get(raw_config, det, PropDict()))

        energy_windows = IdDict(keys(raw_config_det.peaks) .=> [first(v)..last(v) for v in values(raw_config_det.peaks)])

        filelist = [l200.tier[:raw, key] for key in filekeys]
        output_filename = l200.tier[:jlpeaks, first(filekeys), det]

        if isfile(output_filename) && !reprocess
            @info "Output file \"$output_filename\" already exists, skipping"
            n_sep, n_fep = nothing, nothing
            try
                output = lh5open(output_filename, "r")
                n_sep = length(output[det].jlpeaks.Tl208SEP.daqenergy)
                n_fep = length(output[det].jlpeaks.Tl208FEP.daqenergy)
                close(output)
            catch e
                @error "Error reading SEP and FEP events from $(basename(output_filename)): $(truncate_error(e))"
                @warn "Filename $(basename(output_filename)) seems broken, remove it."
                rm(output_filename)
            end
            if isfile(output_filename) && !isnothing(n_sep) && !isnothing(n_fep)
                log_det = log_peaksplit((det, ch, ProcessStatus(1), n_fep, n_sep, "0", "0", ""))
                return (processed = false, log = log_det)
            end
        end

        split_timer = TimerOutput()

        @info "Generating output file \"$output_filename\""
        @timeit split_timer "$det" begin
            # get raw daqenergy
            @timeit split_timer "Get DAQ Energy" begin
                e_raw = get_daqenergy_for_det(filelist, det)
                @info "Auto calibrating $det ($ch)"
                result_autocal, report_autocal = autocal_energy(e_raw, raw_config_det.th228_cal_lines; mode=:ratio, min_e=raw_config_det.min_e, max_e=raw_config_det.max_e, max_e_binning_quantile=raw_config_det.max_e_binning_quantile, σ=raw_config_det.σ, threshold=raw_config_det.threshold, min_n_peaks=raw_config_det.min_n_peaks, max_n_peaks=raw_config_det.max_n_peaks, α=raw_config_det.α, rtol=raw_config_det.rtol)
                f_calib = result_autocal.f_calib
                p = LegendMakie.lplot(report_autocal, raw_config_det.th228_cal_lines, figsize = (650,400), title = get_plottitle(first(filekeys), det, "Calibrated DAQ Online Energy"))
                savelfig(LegendMakie.lsavefig, p, l200, first(filekeys), det, Symbol("daq_energy"))
            end
            GC.gc()
            @info "Filtering detector $det ($ch)"
            @timeit split_timer "Filter Raw" begin
                slim_data = flatten_by_key([lh5open(filename) do ds
                    @debug "Filtering $(filename) for detector $det ($ch)"
                    filter_raw_data_by_energy(ds[det].raw[:], f_calib, energy_windows; chunk_size=100)
                    # filter_raw_data_by_energy(Table(decode_data(ds[det].raw[:])), f_calib, energy_windows)
                end for filename in filelist])
            end
            n_fep = length(slim_data[:Tl208FEP].daqenergy)
            n_sep = length(slim_data[:Tl208SEP].daqenergy)

            # stephist(f_calib.(slim_data[:Tl208a].daqenergy), nbins = 100)
            # stephist(f_calib.(slim_data[:Tl208aDEP_Bi212b].daqenergy), nbins = 100)
            
            @info "Writing $output_filename"
            
            @timeit split_timer "Write Data" begin
                write_files(output_filename, use_cache = false, mode = CreateOrReplace()) do outfile
                    lh5open(outfile, "w") do output
                        for label in sort(collect(keys(slim_data)))
                            output[det, :jlpeaks, label] = slim_data[label]
                            # output[det, :jlpeaks, label] = decode_data(slim_data[label])
                        end
                    end
                end
            end
        end

        # create total timer by summing over memory usage and time
        total_time      = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(split_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(split_timer))

        log_det = log_peaksplit((det, ch, ProcessStatus(1), n_fep, n_sep, "$total_time", total_allocated, ""))

        @info "Finished processing detector $det ($ch) in $total_time"

        return (result = (n_fep = n_fep, n_sep = n_sep), processed = true, log = log_det)
    end

    # execute in parallel
    result_peaksplit = parallel(chinfo, split_peak_det, log_peaksplit, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished peak splitting"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, peak_splitting_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(first(filekeys)))
    lreport!(report, "# Results")
    if !isnothing(result_fkcheck)
        lreport!(report, "## Results Filekey Check")
        lreport!(report, create_logtbl(result_fkcheck))
        lreport!(report, "## Results Peak Splitting")
    end
    lreport!(report, create_logtbl(result_peaksplit))

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    # flush stdout
    flush(stdout)
end # function