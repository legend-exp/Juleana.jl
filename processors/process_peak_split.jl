#!/usr/bin/env julia
function process_peak_split(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Union{Int, Bool}=false)
          
    @info "Process peak splitting for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) channels"

    dsp_config = DSPConfig(dataprod_config(l200).dsp(filekey).default)
    @debug "Loaded DSP config: $(dsp_config)"

    energy_config = dataprod_config(l200).energy(filekey)

    if reprocess @info "Reprocess all channels" end

    # create log line Tuple
    log_fkcheck = NamedTuple{(:Filekey, :Status, Symbol("Number of Processed Detectors"), Symbol("Failed Detectors"), Symbol("Total Time"), Symbol("Total Allocated"), :Error)}
    log_peaksplit = NamedTuple{(:Channel, :Detector, :Status, Symbol("Number of FEP Events"), Symbol("Number of SEP Events"), Symbol("Total Time"), Symbol("Total Allocated"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # get start time
    start_time = now()

    # energy windows of extracted peaks --> Should move to metadata config
    energy_windows = IdDict(
        :Tl208a => 558u"keV"..608u"keV",
        :Bi212a => 702u"keV"..752u"keV",
        :Tl208b => 836u"keV"..886u"keV",
        :Tl208DEP_Bi212FEP => 1568u"keV"..1646u"keV",
        :Tl208SEP => 2079u"keV"..2129u"keV",
        :Tl208FEP => 2590u"keV"..2640u"keV"
    )

    # get input and output directories
    input_datadir = l200.tier[:raw, :cal, period, run]
    output_datadir = mkpath(l200.tier[:jlpeaks, :cal, period, run])
    @assert isdir(input_datadir) && isdir(output_datadir)

    # get channels
    channels = chinfo.channel

    @info "Expecting $(length(channels)) channels each file in \"$input_datadir\"."

    function get_daqenergy_for_ch(filelist::AbstractVector{<:AbstractString}, ch::ChannelIdLike)
        fast_flatten([
            LHDataStore(
                ds -> begin
                    @info "Reading DAQ energy for channel $ch from \"$(ds.data_store.filename)\""
                    ds[ch].raw.daqenergy[:]
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

    if isfile(keylist_filename)
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
            failed_channels = ChannelId[]
            @timeit fk_timer "$fk" begin
                try
                    LHDataStore(filename) 
                catch err
                    @error "Error while checking file \"$(filename)\": $(err)"
                    is_ok = false
                else
                    LHDataStore(filename) do ds
                        for ch in channels
                            @timeit fk_timer "$ch" begin
                                try
                                    haskey(ds, "$ch") || throw(ErrorException("Channel $ch not found in \"$(filename)\""))
                                catch err
                                    @error "Error while checking channel $ch in \"$(filename)\": $(err)"
                                    push!(failed_channels, ch)
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
            log_fk = log_fkcheck((fk, ProcessStatus(1), "$(length(channels))", string.(failed_channels), total_time, total_allocated, ""))
            return (result = is_ok, timer = fk_timer, log = log_fk, processed = true)
        end

        result_fkcheck = Dict(parallel(filekeys, check_filekey, log_fkcheck, wpool,; timeout=timeout))

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
    function split_peak_ch(chinfo_ch::NamedTuple)

        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        @info "Processing channel $ch"

        energy_config_ch = merge(energy_config.default, get(energy_config, det, PropDict()))
        quantile_perc = if energy_config_ch.quantile_perc isa String parse(Float64, energy_config_ch.quantile_perc) else energy_config_ch.quantile_perc end

        filelist = [l200.tier[:raw, key] for key in filekeys]
        output_filename = l200.tier[:jlpeaks, first(filekeys), ch]

        if isfile(output_filename) && !reprocess
            @info "Output file \"$output_filename\" already exists, skipping"
            n_sep, n_fep = nothing, nothing
            try
                output = lh5open(output_filename, "r")
                n_sep = length(output[ch].jlpeaks.Tl208SEP.daqenergy)
                n_fep = length(output[ch].jlpeaks.Tl208FEP.daqenergy)
                close(output)
            catch e
                @error "Error reading SEP and FEP events from $(basename(output_filename)): $e"
                @warn "Filename $(basename(output_filename)) seems broken, remove it."
                rm(output_filename)
            end
            if isfile(output_filename) && !isnothing(n_sep) && !isnothing(n_fep)
                log_ch = log_peaksplit((ch, det, ProcessStatus(1), n_fep, n_sep, "0", "0", ""))
                return (processed = false, log = log_ch)
            end
        end

        split_timer = TimerOutput()

        @info "Generating output file \"$output_filename\""
        # @timeit split_timer "$ch" begin
            # # get raw daqenergy
            # @timeit split_timer "Get DAQ Energy" begin
            #     E_raw = get_daqenergy_for_ch(filelist, ch)
            #     f_calib, diagnostics = autocal_energy(E_raw,; quantile_perc=quantile_perc)
            # end
            # p = plot(diagnostics.cal_hist, st=:stepbins)
            # plot!(p, xlabel="Energy (keV)", ylabel="Counts", legend=:none, yscale=:log10)
            # title!(p, get_plottitle(first(filekeys), det, "Calibrated DAQ Online Energy"))
            # savelfig(savefig, p, l200, first(filekeys), ch, Symbol("daq_energy"))

            # @timeit split_timer "Filter Raw" begin
            #     slim_data = flatten_by_key([LHDataStore(filename) do ds
            #         @info "Filtering $(filename), channel $ch"
            #         filter_raw_data_by_energy(ds[ch].raw, f_calib, energy_windows)
            #     end for filename in filelist])
            # end
            # n_fep = length(slim_data[:Tl208FEP].daqenergy)
            # n_sep = length(slim_data[:Tl208SEP].daqenergy)

            # stephist(f_calib.(slim_data[:Tl208a].daqenergy), nbins = 100)
            # stephist(f_calib.(slim_data[:Tl208aDEP_Bi212b].daqenergy), nbins = 100)
            
            @info "Writing $output_filename"
            
            @timeit split_timer "Write Data" begin
                # h5open(output_filename, "w") do output
                #     for label in sort(collect(keys(slim_data)))
                #         LegendDataTypes.writedata(output, "$ch/jlpeaks/$label", slim_data[label])
                #     end
                # end

                # tmp for Heidelberg, instead of reprocessing the data just change format of old peak files
                # old_file = lh5open(l200.tier[:peaks, first(filekeys), ch], "r")[ch]
                labels = collect(keys(energy_windows))
                slim_data =  Dict{Symbol, TypedTables.Table}()
                for label in labels
                    slim_data[label] = lh5open(l200.tier[:peaks, first(filekeys), ch], "r")[ch][label][:]
                end
                n_fep = length(slim_data[:Tl208FEP])
                n_sep = length(slim_data[:Tl208SEP])

                create_files(output_filename, use_cache = true) do outfile
                    h5open(outfile, "w") do output
                        for label in sort(collect(keys(slim_data)))
                            LegendDataTypes.writedata(output, "$ch/jlpeaks/$label", slim_data[label])
                        end
                    end
                end
                # lh5open(output_filename, "cw") do output
                #     for label in sort(collect(keys(old_file)))
                #         output["$ch/jlpeaks/$label"] = slim_data[label]
                #     end
                # end
                # close(old_file)
            end
        # end

        # create total timer by summing over memory usage and time
        total_time      = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(split_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(split_timer))

        log_ch = log_peaksplit((ch, det, ProcessStatus(1), n_fep, n_sep, "$total_time", total_allocated, ""))

        return (result = (n_fep = n_fep, n_sep = n_sep), processed = true, log = log_ch)
    end

    # execute in parallel
    result_peaksplit = parallel(chinfo, split_peak_ch, log_peaksplit, wpool; timeout=timeout)

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
    writelreport(get_reportfilename(l200, filekey, :peak_splitting), report)
    @info report

    # flush stdout
    flush(stdout)
end # function