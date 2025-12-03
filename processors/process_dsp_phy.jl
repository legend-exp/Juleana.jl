function process_dsp_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool = false, timeout::Int=0, max_wvfs::Int=10000, use_partition_filter::Bool=false, use_dsp_config_defaults::Bool=false)
    
    @info "Process DSP for period $period and run $run"

    filekeys = search_disk(FileKey, l200.tier[:raw, :phy, period, run])
    
    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found start filekey $filekey"

    chinfo      = channelinfo(l200, filekey; system=:geds, only_processable=true)
    chinfo_sipm = channelinfo(l200, filekey; system=:spms, only_processable=true)
    chinfo_pmts = channelinfo(l200, filekey; system=:pmts, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) channels"

    dsp_config_pd = dataprod_config(l200).dsp(filekey)
    @debug "Loaded DSP config: $(dsp_config_pd)"
    dsp_meta_sipm = dataprod_config(l200).sipm(filekey)
    @debug "Loaded SiPM DSP config: $(dsp_meta_sipm)"
    dsp_meta_pmt = dataprod_config(l200).pmt(filekey)
    @debug "Loaded PMT DSP config: $(dsp_meta_pmt)"

    # ========== Load default parameters from DSP config if requested ==========
    dsp_default_tau = nothing
    dsp_default_fltopt = nothing
    dsp_default_aoeopt = nothing
    dsp_default_sipm_wl = nothing
    
    if use_dsp_config_defaults
        @info "Using DSP config defaults for missing parameters"

        # Helper to parse quantity values from config
        unit_map = Dict(
            "µs" => u"µs", "us" => u"µs", "μs" => u"µs", "ns" => u"ns",
        )

        parse_quantity(entry, default_unit=nothing) = begin
            if entry isa Unitful.Quantity
                return entry
            elseif entry isa PropDict
                val = get(entry, :val, nothing)
                unit_str = get(entry, :unit, nothing)
                unit = unit_str === nothing ? default_unit : get(unit_map, String(unit_str), default_unit)
                return val === nothing ? nothing : (unit === nothing ? val : val * unit)
            elseif entry === nothing
                return nothing
            else
                return default_unit === nothing ? entry : entry * default_unit
            end
        end

        # Load default tau from DSP config (fallback to 460 µs)
        # Note: tau is under dsp_config.pz.default.tau, not dsp_config.default.pz.tau
        tau_entry = nothing
        if haskey(dsp_config_pd, :pz) && haskey(dsp_config_pd.pz, :default)
            tau_entry = get(dsp_config_pd.pz.default, :tau, nothing)
        end
        tau_quantity = parse_quantity(tau_entry, u"µs")
        if tau_quantity === nothing
            @warn "No tau default found in DSP config, falling back to 460.0 µs"
            tau_quantity = 460.0 * u"µs"
        end
        dsp_default_tau = PropDict(:τ => tau_quantity)

        # Load filter defaults from DSP config
        dsp_default_fltopt = PropDict()
        dsp_default_aoeopt = PropDict()
        
        if haskey(dsp_config_pd.default, :flt_defaults)
            flt_defaults = dsp_config_pd.default.flt_defaults
            
            # Get required energy filter types from config, fallback to standard filters
            required_energy_filters = haskey(dsp_config_pd.default, :required_fltopt) ? 
                Symbol.(dsp_config_pd.default.required_fltopt) : [:trap, :zac, :cusp]

            for filter_type in required_energy_filters
                if haskey(flt_defaults, filter_type)
                    filter_pars = flt_defaults[filter_type]
                    rt_quantity = parse_quantity(get(filter_pars, :rt, nothing), u"µs")
                    ft_quantity = parse_quantity(get(filter_pars, :ft, nothing), u"µs")
                    if rt_quantity !== nothing && ft_quantity !== nothing
                        dsp_default_fltopt[filter_type] = PropDict(:rt => rt_quantity, :ft => ft_quantity)
                    end
                end
            end

            if haskey(flt_defaults, :sg)
                wl_quantity = parse_quantity(flt_defaults.sg, u"ns")
                if wl_quantity !== nothing
                    dsp_default_aoeopt[:sg] = PropDict(:wl => wl_quantity)
                end
            end
        else
            @warn "No flt_defaults found in DSP config"
        end

        # Load SiPM defaults
        dsp_default_sipm_wl = nothing
        if haskey(dsp_config_pd.default, :sipm_defaults) && haskey(dsp_config_pd.default.sipm_defaults, :sg)
            wl_quantity = parse_quantity(get(get(dsp_config_pd.default.sipm_defaults, :sg, PropDict()), :wl, nothing), u"ns")
            if wl_quantity !== nothing
                dsp_default_sipm_wl = wl_quantity
            end
        end
        if dsp_default_sipm_wl === nothing
            @warn "No SiPM sg wl default found in DSP config, falling back to 148.0 ns"
            dsp_default_sipm_wl = 148.0 * u"ns"
        end

        # Log all default values
        @info "=== DSP Config Default Values ==="
        @info "  Tau (decay time): $(dsp_default_tau.τ)"
        for (flt, pars) in dsp_default_fltopt
            @info "  Energy filter $flt: rt=$(pars.rt), ft=$(pars.ft)"
        end
        if haskey(dsp_default_aoeopt, :sg)
            @info "  A/E filter sg: wl=$(dsp_default_aoeopt.sg.wl)"
        end
        @info "  SiPM sg: wl=$(dsp_default_sipm_wl)"
    end

    # Load QC classifier; fall back to dummy labels when the ML file is missing
    f_evaluate_qc = nothing
    try
        f_evaluate_qc = h5open(get_mltrainfilename(l200, filekey)) do train_data
            get_qc_ml_func(Array(train_data["ml_train/dsp/dwt_norm"]), Array(train_data["ml_train/dsp/dc_label"]), l200.par.rpars.ml(filekey))
        end
        @info "Loaded trained SVM model"
    catch e
        @warn "ML model not available for period $period – using dummy QC classifier (all events → qc_label = 0). Error: $(truncate_error(e))"
        f_evaluate_qc = function(processed_signals)
            n_wvfs = size(processed_signals, 2)
            predictions = Vector{Int}(undef, n_wvfs)
            fill!(predictions, 0)
            scores = zeros(Float64, n_wvfs)
            return (predictions, scores)
        end
    end

    pars_type = ifelse(use_partition_filter, :ppars, :rpars)
    @info "Use $(ifelse(use_partition_filter, "partition", "run"))-based pars from $pars_type for DSP optimization parameters"
    
    pars_tau = get_values(l200.par[pars_type, :pz](filekey))
    @debug "Loaded decay times"

    pars_fltoptimization = get_values(merge(l200.par[pars_type, :fltopt](filekey), l200.par[pars_type, :aoeopt](filekey)))
    @debug "Loaded optimization parameters"

    @debug "Check if all HPGe detectors have optimization parameters"
    for chinfo_ch in chinfo
        ch = chinfo_ch.channel
        det = chinfo_ch.detector
        # prevent DSP from failing if run doesnt appear in any partition by using pars from partition of closest run
        if use_partition_filter && !haskey(pars_tau, det) && !haskey(pars_fltoptimization, det) && chinfo_ch.processable != :on && isempty(partitioninfo(l200, ch, period, run))
            @warn "Detector $det ($ch) doesn't have pars and optimization parameters since $period/$run is not in any `DataPartition` for channel"
            parts = partitioninfo(l200, ch, period)
            closest_runs_distance = Real[]
            for p in parts
                pinfo = filter(row -> row.period == period, partitioninfo(l200, ch, p))
                closest_run = pinfo.run[argmin([abs(r.no - run.no) for r in pinfo.run])]
                push!(closest_runs_distance, abs(closest_run.no - run.no))
            end
            part = parts[argmin(closest_runs_distance)]
            try
                merge!(pars_tau, get_values(l200.par.ppars.pz[det, part]))
            catch e
                @warn "No decay time for detector $det ($ch), skip"
                continue
            end
            try
                merge!(pars_fltoptimization, get_values(l200.par.ppars.fltopt[det, part]))
            catch e
                @warn "No flt optimization parameters for detector $det ($ch), skip"
                continue
            end
            try
                merge!(pars_fltoptimization, get_values(l200.par.ppars.aoeopt[det, part]))
            catch e
                @warn "No aoe flt optimization parameters for detector $det ($ch), skip"
                continue
            end
        end
    end

    mkpath(data_path(l200.par[pars_type, :sipmopt]))
    pars_sipm = get_values(l200.par[pars_type, :sipmopt](filekey))
    @debug "Loaded sipm parameters"
    
    if reprocess @info "Reprocess all filekeys and channels"
    else @info "Only reprocess filekeys and channels that are not processed yet" end

    # create log line Tuple - extended to track default parameter usage
    log_nt = NamedTuple{(:Filekey, :Status, Symbol("Number of Processed Detectors"), Symbol("Failed Detectors"), Symbol("Default Tau"), Symbol("Default FltOpt"), Symbol("Default AoeOpt"), Symbol("Default SiPM"), Symbol("Total Time"), Symbol("Total Allocated"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    function resolve_raw_key(ds, ch, det)
        det_key = string(det)
        ch_key = string(ch)
        if haskey(ds, det_key)
            return det_key
        elseif haskey(ds, ch_key)
            return ch_key
        else
            return nothing
        end
    end

    function filekey_dsp(fk::FileKey)
        dsp_timer = TimerOutput()
        # raw and dsp filename
        rawfilename = l200.tier[:raw, fk]
        @info "Processing file: $(basename(rawfilename))"
        dspfilename = l200.tier[:jldsp, fk]
        @info "Using output file: $(basename(dspfilename))"
        # number of processed detectors
        n_detectors = 0
        # channel ids of failed detectors
        failed_detectors = DetectorId[]
        # detectors using default parameters
        default_tau_detectors = DetectorId[]
        default_fltopt_detectors = DetectorId[]
        default_aoeopt_detectors = DetectorId[]
        default_sipm_detectors = DetectorId[]
        # start processing
        read_files(rawfilename, use_cache = false) do filename
            write_files(dspfilename, use_cache = true, mode = CreateOrModify()) do outfilename
                @timeit dsp_timer "Startup" begin
                    raw_data = lh5open(filename, "r")
                    if reprocess && isfile(outfilename)
                        @info "Reprocess $(basename(outfilename)), remove old DSP."
                        rm(outfilename, force=true)
                    end
                end

                # open output file
                outdata = lh5open(outfilename, "cw")
                # keep track of already processed detectors
                processed_channels = Set(string.(keys(outdata)))

                @info "Start DSP"
                @timeit dsp_timer "DSP" begin
                    if haskey(dsp_config_pd, :additional_channel)
                        # process additional channels
                        for det in DetectorId.(keys(dsp_config_pd.additional_channel))
                            ch = channelinfo(l200, filekey, det).channel
                            det_label = string(det)

                            dsp_config_pd_ch = merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict()))
                            dsp_config_ch = DSPConfig(dsp_config_pd_ch)
                            @debug "Loaded DSP config: $(dsp_config_ch)"

                            # check if channel can be processed
                            raw_key = resolve_raw_key(raw_data, ch, det)
                            if raw_key === nothing
                                @warn "Detector $det ($ch) not found in raw file, skip"
                                push!(failed_detectors, det)
                                continue
                            end

                            if det_label in processed_channels && !reprocess
                                @info "Detector $det ($ch) already processed, skip"
                                n_detectors += 1
                                continue
                            end

                            @debug "Processing detector $det ($ch)"
                            @timeit dsp_timer "DSP $det" begin
                                # process data
                                outdata_ch = nothing
                                try
                                    outdata_ch = getfield(LegendDSP, Symbol(dsp_config_pd.additional_channel[Symbol(det)]))(raw_data[raw_key].raw[:], dsp_config_ch)
                                catch e
                                    if e isa TaskFailedException
                                        e = e.task.exception
                                    end
                                    @error "Error processing detector $det ($ch) in $(fk): $(truncate_error(e))"
                                    push!(failed_detectors, det)
                                    continue
                                end
                                # save data to hdf5
                                outdata[det_label, :jldsp] = outdata_ch
                                push!(processed_channels, det_label)
                                # free memory
                                GC.gc()
                                # count number of detectors processed and Successful
                                n_detectors += 1
                            end
                        end
                    end

                    # loop over channels
                    if all(chinfo_ch -> resolve_raw_key(raw_data, chinfo_ch.channel, chinfo_ch.detector) === nothing, chinfo_pmts)
                        @warn "No PMT data found in $(fk), skip PMT processing"
                        n_detectors += length(chinfo_pmts)
                    else
                        @showprogress desc="Filekey PMTS: $fk" output=stdout for chinfo_ch in chinfo_pmts

                            ch = chinfo_ch.channel
                            det = chinfo_ch.detector
                            det_label = string(det)
            
                            # check if channel can be processed
                            raw_key = resolve_raw_key(raw_data, ch, det)
                            if raw_key === nothing
                                @warn "Detector $det ($ch) not found in raw file, skip"
                                push!(failed_detectors, det)
                                continue
                            end

                            if det_label in processed_channels && !reprocess
                                @info "Detector $det ($ch) already processed, skip"
                                n_detectors += 1
                                continue
                            end
            
                            @debug "Processing detector $det ($ch)"
                            @timeit dsp_timer "DSP $det" begin
                                # get metadata
                                dsp_meta_ch = merge(dsp_meta_pmt.default, get(dsp_meta_pmt, det, PropDict()))
                                # process channel
                                outdata_ch = nothing
                                try
                                    outdata_ch = dsp_pmts(raw_data[raw_key].raw[:], dsp_meta_ch)
                                catch e
                                    if e isa TaskFailedException
                                        e = e.task.exception
                                    end
                                    @error "Error processing detector $det ($ch) in $(fk): $(truncate_error(e))"
                                    push!(failed_detectors, det)
                                    continue
                                end
                                # save data to hdf5
                                outdata[det_label, :jldsp] = outdata_ch
                                push!(processed_channels, det_label)
                                # free memory
                                GC.gc()
                                # count number of detectors processed and Successful
                                n_detectors += 1
                                # flush streams
                                flush(stdout)
                                flush(stderr)
                            end
                        end
                    end

                    # loop over channels
                    @showprogress desc="Filekey SiPM: $fk" output=stdout for chinfo_ch in chinfo_sipm

                        ch = chinfo_ch.channel
                        det = chinfo_ch.detector
                        det_label = string(det)
        
                        # check for existing optimization parameters
                        detector_sipmopt_exists = haskey(pars_sipm, det)
                        detector_sipmopt = detector_sipmopt_exists ? deepcopy(pars_sipm[det]) : PropDict()
                        using_default_sipm = false

                        # ensure Savitzky-Golay window length is available
                        has_sg_wl = detector_sipmopt_exists && haskey(detector_sipmopt, :sg) && haskey(detector_sipmopt.sg, :wl) && detector_sipmopt.sg[:wl] !== nothing

                        if !has_sg_wl
                            if use_dsp_config_defaults && dsp_default_sipm_wl !== nothing
                                sg_dict = haskey(detector_sipmopt, :sg) ? PropDict(detector_sipmopt[:sg]) : PropDict()
                                default_wl_val = dsp_default_sipm_wl isa Unitful.Quantity ? ustrip(u"ns", dsp_default_sipm_wl) : dsp_default_sipm_wl
                                sg_dict[:wl] = PropDict(:val => default_wl_val, :unit => "ns")
                                detector_sipmopt[:sg] = sg_dict
                                using_default_sipm = true
                                push!(default_sipm_detectors, det)
                                @info "Using default SiPM sg wl for detector $det"
                            else
                                @warn "No SiPM optimization parameters for detector $det ($ch), skip"
                                push!(failed_detectors, det)
                                continue
                            end
                        end

                        raw_key = resolve_raw_key(raw_data, ch, det)
                        if raw_key === nothing
                            @warn "Detector $det ($ch) not found in raw file, skip"
                            push!(failed_detectors, det)
                            continue
                        end
                        if det_label in processed_channels && !reprocess
                            @info "Detector $det ($ch) already processed, skip"
                            n_detectors += 1
                            continue
                        end
        
                        @debug "Processing detector $det ($ch)"
                        @timeit dsp_timer "DSP $det" begin
                            # get metadata
                            dsp_meta_ch = merge(dsp_meta_sipm.default, get(dsp_meta_sipm, det, PropDict()))
                            # process channel
                            outdata_ch = nothing
                            try
                                outdata_ch = dsp_sipm_compressed(raw_data[raw_key].raw[:], dsp_meta_ch, detector_sipmopt)
                            catch e
                                if e isa TaskFailedException
                                    e = e.task.exception
                                end
                                @error "Error processing detector $det ($ch) in $(fk): $(truncate_error(e))"
                                push!(failed_detectors, det)
                                continue
                            end
                            # save data to hdf5
                            outdata[det_label, :jldsp] = outdata_ch
                            push!(processed_channels, det_label)
                            # free memory
                            GC.gc()
                            # count number of detectors processed and Successful
                            n_detectors += 1
                            # flush streams
                            flush(stdout)
                            flush(stderr)
                        end
                    end

                    # loop over channels
                    @showprogress desc="Filekey HPGe: $fk" output=stdout for chinfo_ch in chinfo

                        ch = chinfo_ch.channel
                        det = chinfo_ch.detector
                        det_label = string(det)

                        dsp_config_pd_ch = merge(dsp_config_pd.default, get(dsp_config_pd, det, PropDict()))
                        dsp_config_ch = DSPConfig(dsp_config_pd_ch)
                        @debug "Loaded DSP config: $(dsp_config_ch)"

                        # check if channel can be processed
                        raw_key = resolve_raw_key(raw_data, ch, det)
                        if raw_key === nothing
                            @warn "Detector $det ($ch) not found in raw file, skip"
                            push!(failed_detectors, det)
                            continue
                        end

                        if det_label in processed_channels && !reprocess
                            @info "Detector $det ($ch) already processed, skip"
                            n_detectors += 1
                            continue
                        end

                        # ========== Check/Build decay time ==========
                        detector_tau = nothing
                        using_default_tau = false
                        if haskey(pars_tau, det)
                            detector_tau = pars_tau[det]
                        elseif use_dsp_config_defaults && dsp_default_tau !== nothing
                            detector_tau = dsp_default_tau
                            using_default_tau = true
                            push!(default_tau_detectors, det)
                            @info "Using default tau for detector $det"
                        else
                            @warn "No decay time for detector $det ($ch), skip"
                            push!(failed_detectors, det)
                            continue
                        end

                        # ========== Check/Build filter optimization parameters ==========
                        detector_fltopt = PropDict()
                        using_default_fltopt = false
                        using_default_aoeopt = false
                        
                        # Get required energy filter types from config
                        required_energy_filters = haskey(dsp_config_pd_ch, :required_fltopt) ? 
                            Symbol.(dsp_config_pd_ch.required_fltopt) : [:trap, :zac, :cusp]

                        # Copy existing energy filter parameters
                        if haskey(pars_fltoptimization, det)
                            for key in keys(pars_fltoptimization[det])
                                if any(startswith(string(key), string(filter)) for filter in required_energy_filters)
                                    detector_fltopt[key] = pars_fltoptimization[det][key]
                                end
                            end
                        end

                        # Fill missing energy filter parameters with defaults
                        if use_dsp_config_defaults && dsp_default_fltopt !== nothing
                            for filter_type in Symbol.(dsp_config_pd_ch.required_fltopt)
                                if !haskey(detector_fltopt, filter_type) && haskey(dsp_default_fltopt, filter_type)
                                    detector_fltopt[filter_type] = dsp_default_fltopt[filter_type]
                                    using_default_fltopt = true
                                end
                            end
                            if using_default_fltopt
                                push!(default_fltopt_detectors, det)
                                @info "Using default energy filter parameters for detector $det"
                            end
                        end

                        # Check if all required energy filter parameters are present
                        if !all(haskey.(Ref(detector_fltopt), Symbol.(dsp_config_pd_ch.required_fltopt)))
                            @warn "Missing energy filter optimization parameters for detector $det ($ch), skip"
                            push!(failed_detectors, det)
                            continue
                        end

                        # Copy existing A/E filter parameters (sg)
                        if haskey(pars_fltoptimization, det)
                            for key in keys(pars_fltoptimization[det])
                                if startswith(string(key), "sg")
                                    detector_fltopt[key] = pars_fltoptimization[det][key]
                                end
                            end
                        end

                        # Fill missing A/E filter parameters with defaults (only for usable channels)
                        if chinfo_ch.usability == :on && chinfo_ch.low_aoe_status in [:valid, :present]
                            aoe_keys_missing = !any(startswith(string(key), "sg") for key in keys(detector_fltopt))
                            if aoe_keys_missing && use_dsp_config_defaults && dsp_default_aoeopt !== nothing
                                merge!(detector_fltopt, dsp_default_aoeopt)
                                using_default_aoeopt = true
                                push!(default_aoeopt_detectors, det)
                                @info "Using default A/E filter parameters for detector $det"
                            elseif aoe_keys_missing && !use_dsp_config_defaults
                                @warn "Missing A/E optimization parameters for detector $det ($ch), skip"
                                push!(failed_detectors, det)
                                continue
                            end
                        end

                        @debug "Processing detector $det ($ch)"
                        @timeit dsp_timer "DSP $det" begin
                            # process data
                            outdata_ch = nothing
                            try
                                outdata_ch = dsp_icpc_compressed(raw_data[raw_key].raw[:], dsp_config_ch, detector_tau.τ, detector_fltopt; f_evaluate_qc=f_evaluate_qc)
                            catch e
                                if e isa TaskFailedException
                                    e = e.task.exception
                                end
                                @error "Error processing detector $det ($ch) in $(fk): $(truncate_error(e))"
                                push!(failed_detectors, det)
                                continue
                            end
                            # save data to hdf5
                            outdata[det_label, :jldsp] = outdata_ch
                            push!(processed_channels, det_label)
                            # free memory
                            GC.gc()
                            # count number of detectors processed and Successful
                            n_detectors += 1
                            # flush streams
                            flush(stdout)
                            flush(stderr)
                        end
                    end
                    # close outdata file
                    close(outdata)
                end
                @info "Finished processing file: $(basename(filename))"
                
                # Log summary of default parameter usage
                if use_dsp_config_defaults && (!isempty(default_tau_detectors) || !isempty(default_fltopt_detectors) || !isempty(default_aoeopt_detectors) || !isempty(default_sipm_detectors))
                    @info "=== Default Parameter Usage Summary ==="
                    if !isempty(default_tau_detectors)
                        @info "  Tau (decay time): $(unique(default_tau_detectors))"
                    end
                    if !isempty(default_fltopt_detectors)
                        @info "  Energy Filters (trap/zac/cusp): $(unique(default_fltopt_detectors))"
                    end
                    if !isempty(default_aoeopt_detectors)
                        @info "  A/E Filter (sg): $(unique(default_aoeopt_detectors))"
                    end
                    if !isempty(default_sipm_detectors)
                        @info "  SiPM (sg wl): $(unique(default_sipm_detectors))"
                    end
                end
                
                close(raw_data)
            end
        end
        if n_detectors == 0
            @warn "No detectors processed in $(basename(filename))"
        end

        # create total timer by summing over memory usage and time
        total_time      = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(dsp_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(dsp_timer))
        
        # create log with default parameter tracking
        log_fk = log_nt((
            fk, 
            ProcessStatus(ifelse(isempty(failed_detectors), 1, 0)), 
            "$(n_detectors)/$(length(chinfo)+length(get(dsp_config_pd, :additional_channel, []))+length(chinfo_sipm)+length(chinfo_pmts))", 
            string.(failed_detectors),
            isempty(default_tau_detectors) ? "-" : join(string.(unique(default_tau_detectors)), ", "),
            isempty(default_fltopt_detectors) ? "-" : join(string.(unique(default_fltopt_detectors)), ", "),
            isempty(default_aoeopt_detectors) ? "-" : join(string.(unique(default_aoeopt_detectors)), ", "),
            isempty(default_sipm_detectors) ? "-" : join(string.(unique(default_sipm_detectors)), ", "),
            total_time, 
            total_allocated, 
            ""
        ))

        return (timer = dsp_timer, log = log_fk, processed = true)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_dsp = parallel(filekeys, filekey_dsp, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")
    
    @info "Finished DSP for period $period and run $run"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, dsp_cal_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_dsp))
    lreport!(report, "# Total Timing")
    lreport!(report, "```")
    lreport!(report, "$(get_totalTimer(result_dsp))")
    lreport!(report, "```")

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    # flush stdout
    flush(stdout)
end
