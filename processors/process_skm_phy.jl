# ============================================================================
# SKM Selection and Helper Functions (defined at module level for precompilation)
# ============================================================================

"""
    _skm_build_selection(evt_sel, energy_type, min_energy)

Build a selection function for SKM filtering based on config parameters.
Returns a function that takes a row and returns true if the event passes all cuts.
"""
function _skm_build_selection(evt_sel, energy_type::Symbol, min_energy)
    # Return a closure that captures the config values
    return function(row)
        # Auxiliary trigger cuts
        pulser_cut = evt_sel.exclude_pulser ? !row.aux.pulser.aux_trig : true
        ft_cut = evt_sel.exclude_forcedtrigger ? !row.aux.forcedtrigger.aux_trig : true
        muon01_cut = evt_sel.exclude_muon01 ? !row.aux.muonveto.aux_trig : true
        # Veto and QC cuts  
        muon_cut = evt_sel.require_valid_muon ? row.ged_pmt.is_valid_muon : true
        qc_cut = evt_sel.require_valid_qc ? row.geds.is_valid_qc : true
        trig_cut = evt_sel.require_valid_trig ? row.geds.is_valid_trig : true
        hit_cut = evt_sel.require_valid_hit ? row.geds.is_valid_hit : true
        # Multiplicity and energy cuts
        mult_cut = row.geds.multiplicity == evt_sel.multiplicity
        energy_cut = getproperty(row.geds, energy_type) > min_energy
        
        return pulser_cut && ft_cut && muon01_cut && muon_cut && qc_cut && trig_cut && hit_cut && mult_cut && energy_cut
    end
end

"""
    _skm_extract_keys(source, keys_config; group_name)

Extract specified keys from a data source and return as StructArray.
"""
function _skm_extract_keys(source, keys_config; group_name::Symbol=:unknown)
    (isnothing(keys_config) || isempty(keys_config)) && return nothing
    keys_sym = Symbol.(keys_config)
    
    # Validate that all keys exist in source
    available_keys = propertynames(source)
    missing_keys = filter(k -> k ∉ available_keys, keys_sym)
    if !isempty(missing_keys)
        @warn "Missing keys in $group_name: $missing_keys - skipping them"
        keys_sym = filter(k -> k ∈ available_keys, keys_sym)
        isempty(keys_sym) && return nothing
    end
    
    data = NamedTuple{Tuple(keys_sym)}(Tuple(getproperty(source, k) for k in keys_sym))
    return StructArrays.StructArray(data)
end

"""
    _skm_filtered_payload(table, output_keys_config)

Build filtered payload from table based on output_keys_config.
"""
function _skm_filtered_payload(table, output_keys_config)
    result_pairs = Pair{Symbol, Any}[]
    
    # Simple top-level groups
    for group in (:geds, :ged_pmt, :ged_spm, :spms, :ft_spm)
        if hasproperty(output_keys_config, group)
            extracted = _skm_extract_keys(getproperty(table, group), getproperty(output_keys_config, group); group_name=group)
            !isnothing(extracted) && push!(result_pairs, group => extracted)
        end
    end
    
    # Nested aux structure
    if hasproperty(output_keys_config, :aux)
        aux_pairs = Pair{Symbol, Any}[]
        for aux_name in propertynames(output_keys_config.aux)
            aux_keys = getproperty(output_keys_config.aux, aux_name)
            if !isempty(aux_keys)
                extracted = _skm_extract_keys(getproperty(table.aux, aux_name), aux_keys; group_name=Symbol("aux.", aux_name))
                !isnothing(extracted) && push!(aux_pairs, aux_name => extracted)
            end
        end
        !isempty(aux_pairs) && push!(result_pairs, :aux => StructArrays.StructArray(NamedTuple(aux_pairs)))
    end
    
    return TypedTables.Table(NamedTuple(result_pairs))
end

"""
    _skm_compute_survival_fractions(data)

Compute PSD, LAr, and combined survival fractions from filtered data.
"""
function _skm_compute_survival_fractions(data)
    if isempty(data)
        return (psd = 0.0u"percent", lar = 0.0u"percent", larpsd = 0.0u"percent")
    end
    psd = mean(data.geds.is_valid_psd) * 100u"percent"
    lar = mean(data.ged_spm.is_valid_lar) * 100u"percent"
    larpsd = mean(data.geds.is_valid_psd .&& data.ged_spm.is_valid_lar) * 100u"percent"
    return (psd = psd, lar = lar, larpsd = larpsd)
end

"""
    _skm_get_output_keys_summary(output_keys_config, store_filtered)

Generate markdown summary of output keys for the report.
"""
function _skm_get_output_keys_summary(output_keys_config, store_filtered::Bool)
    if !store_filtered
        return "All keys from jlevt (store_filtered=false)"
    end
    
    # Helper to escape underscores for markdown
    escape_md(s) = replace(string(s), "_" => "\\_")
    
    lines = String[]
    for group in (:geds, :ged_pmt, :ged_spm, :spms, :ft_spm)
        if hasproperty(output_keys_config, group)
            keys = getproperty(output_keys_config, group)
            if !isempty(keys)
                escaped_keys = join(escape_md.(keys), ", ")
                push!(lines, "- **$(escape_md(group))**: $escaped_keys")
            end
        end
    end
    if hasproperty(output_keys_config, :aux)
        for aux_name in propertynames(output_keys_config.aux)
            aux_keys = getproperty(output_keys_config.aux, aux_name)
            if !isempty(aux_keys)
                escaped_keys = join(escape_md.(aux_keys), ", ")
                push!(lines, "- **aux.$(escape_md(aux_name))**: $escaped_keys")
            end
        end
    end
    return join(lines, "\n")
end

# ============================================================================
# Main Processing Function
# ============================================================================

function process_skm_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool=false, timeout::Int=0, store_filtered::Bool=true)
    
    @info "Process skimmed tier for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :phy))
    @info "Found filekey $filekey"

    # Early exit check - before loading config if file exists and not reprocessing
    skmfilename = l200.tier[:jlskm, filekey]
    @info "Output file: $(basename(skmfilename))"

    # Load SKM config
    skm_config = dataprod_config(l200).skm(filekey)
    @info "Loaded SKM config"

    # Build event selection from config
    evt_sel = skm_config.event_selection.default
    min_energy_cfg = evt_sel.min_energy
    min_energy = (hasproperty(min_energy_cfg, :val) && hasproperty(min_energy_cfg, :unit)) ?
        min_energy_cfg.val * uparse(min_energy_cfg.unit) : min_energy_cfg
    energy_type = Symbol(evt_sel.energy_type)
    @info "Event selection: multiplicity=$(evt_sel.multiplicity), min_energy=$(min_energy), energy_type=$(energy_type)"

    # Get output keys config
    output_keys_config = skm_config.output_keys.default
    @info "Output mode: $(store_filtered ? "filtered keys" : "all keys")"

    if reprocess 
        @info "Reprocess run" 
    else 
        @info "Only process if not found" 
    end

    # Log line for per-filekey processing
    log_nt_fk = NamedTuple{(:Filekey, :Status, Symbol("Events Before"), Symbol("Events After"), Symbol("Total Time"), Symbol("Total Allocated"), :Error)}
    
    # Log line for final summary
    log_nt = NamedTuple{(:Filekey, :Status, Symbol("SF PSD"), Symbol("SF LAr"), Symbol("SF LAr & PSD"), Symbol("Total Time"), Symbol("Total Allocated"), :Error)}

    # flush stdout
    flush(stdout)

    # Get all jlevt filekeys for this run
    tier_path = l200.tier[:jlevt, :phy, period, run]
    all_filekeys = search_disk(FileKey, tier_path)
    filekeys = filter(!in(bad_filekeys(l200)), all_filekeys)
    n_filtered = length(all_filekeys) - length(filekeys)
    @info "Found $(length(all_filekeys)) jlevt filekeys" * (n_filtered > 0 ? ", filtered out $n_filtered bad filekeys" : "")

    # Pre-compute file paths for all filekeys (avoids serializing l200 to workers)
    filekey_paths = Dict{FileKey, String}(fk => l200.tier[:jlevt, fk] for fk in filekeys)

    # Extract simple, serialization-safe values from evt_sel config
    # These will be captured by the worker function without serialization issues
    sel_exclude_pulser = Bool(evt_sel.exclude_pulser)
    sel_exclude_forcedtrigger = Bool(evt_sel.exclude_forcedtrigger)
    sel_exclude_muon01 = Bool(evt_sel.exclude_muon01)
    sel_require_valid_muon = Bool(evt_sel.require_valid_muon)
    sel_require_valid_qc = Bool(evt_sel.require_valid_qc)
    sel_require_valid_trig = Bool(evt_sel.require_valid_trig)
    sel_require_valid_hit = Bool(evt_sel.require_valid_hit)
    sel_multiplicity = Int(evt_sel.multiplicity)
    sel_min_energy_val = Float64(ustrip(u"keV", min_energy))  # Convert to raw Float64 in keV
    sel_energy_type = energy_type  # Symbol is serialization-safe

    # Check if already processed
    if !reprocess && isfile(skmfilename)
        @info "File $(basename(skmfilename)) already exists, skip"
        sf = lh5open(skmfilename, "r") do ds
            skm_node = haskey(ds, :jlskm) ? :jlskm : :skm
            _skm_compute_survival_fractions(ds[skm_node][:])
        end
        
        report = lreport()
        lreport!(report, "# Main Log")
        lreport!(report, "Date of processing: $(now())")
        lreport!(report, "File already existed - skipped processing")
        lreport!(report, "")
        lreport!(report, "# Survival Fractions")
        lreport!(report, "- SF PSD: $(sf.psd)")
        lreport!(report, "- SF LAr: $(sf.lar)")
        lreport!(report, "- SF LAr & PSD: $(sf.larpsd)")
        
        @info "Write log report"
        writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
        
        flush(stdout)
        return true
    end

    if reprocess && isfile(skmfilename)
        @info "Reprocess: removing old file $(basename(skmfilename))"
        rm(skmfilename, force=true)
    end

    # get worker pool (after early exit checks)
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # get start time
    start_time = now()

    # Worker function - captures only simple, serialization-safe types
    # Uses pre-computed paths and extracted config values to avoid serializing l200/PropDict
    function load_and_filter_fk(fk::FileKey)
        fk_timer = TimerOutput()
        evtfilename = filekey_paths[fk]  # Use pre-computed path instead of l200.tier
        
        n_before, n_after = 0, 0
        filtered_data = nothing
        # Initialize filter stats counters
        filter_counts = Dict{String, Int}()
        
        @timeit fk_timer "Load+Filter" begin
            try
                if !isfile(evtfilename)
                    @warn "File not found: $(basename(evtfilename))"
                    log_fk = log_nt_fk((fk, ProcessStatus(0), 0, 0, "", "", "File not found"))
                    return (data = nothing, log = log_fk, processed = false, filter_counts = Dict{String, Int}())
                end
                
                # Load jlevt data
                evt_data = lh5open(evtfilename, "r") do ds
                    ds[:jlevt][:]
                end
                n_before = length(evt_data)
                
                # Compute individual filter statistics on unfiltered data
                # Uses captured simple Bool/Int values instead of PropDict
                # Auxiliary trigger cuts
                if sel_exclude_pulser
                    filter_counts["exclude\\_pulser"] = count(row -> !row.aux.pulser.aux_trig, evt_data)
                end
                if sel_exclude_forcedtrigger
                    filter_counts["exclude\\_forcedtrigger"] = count(row -> !row.aux.forcedtrigger.aux_trig, evt_data)
                end
                if sel_exclude_muon01
                    filter_counts["exclude\\_muon01"] = count(row -> !row.aux.muonveto.aux_trig, evt_data)
                end
                # Veto and QC cuts
                if sel_require_valid_muon
                    filter_counts["require\\_valid\\_muon"] = count(row -> row.ged_pmt.is_valid_muon, evt_data)
                end
                if sel_require_valid_qc
                    filter_counts["require\\_valid\\_qc"] = count(row -> row.geds.is_valid_qc, evt_data)
                end
                if sel_require_valid_trig
                    filter_counts["require\\_valid\\_trig"] = count(row -> row.geds.is_valid_trig, evt_data)
                end
                if sel_require_valid_hit
                    filter_counts["require\\_valid\\_hit"] = count(row -> row.geds.is_valid_hit, evt_data)
                end
                # Multiplicity and energy cuts (using raw Float64 value in keV)
                filter_counts["multiplicity=$(sel_multiplicity)"] = count(row -> row.geds.multiplicity == sel_multiplicity, evt_data)
                filter_counts["$(sel_energy_type)>$(sel_min_energy_val)keV"] = count(row -> ustrip(u"keV", getproperty(row.geds, sel_energy_type)) > sel_min_energy_val, evt_data)
                
                # Filter events using inline selection (avoids capturing complex closure)
                filtered_data = filter(evt_data) do row
                    # Auxiliary trigger cuts
                    pulser_cut = sel_exclude_pulser ? !row.aux.pulser.aux_trig : true
                    ft_cut = sel_exclude_forcedtrigger ? !row.aux.forcedtrigger.aux_trig : true
                    muon01_cut = sel_exclude_muon01 ? !row.aux.muonveto.aux_trig : true
                    # Veto and QC cuts  
                    muon_cut = sel_require_valid_muon ? row.ged_pmt.is_valid_muon : true
                    qc_cut = sel_require_valid_qc ? row.geds.is_valid_qc : true
                    trig_cut = sel_require_valid_trig ? row.geds.is_valid_trig : true
                    hit_cut = sel_require_valid_hit ? row.geds.is_valid_hit : true
                    # Multiplicity and energy cuts (compare raw keV values)
                    mult_cut = row.geds.multiplicity == sel_multiplicity
                    energy_cut = ustrip(u"keV", getproperty(row.geds, sel_energy_type)) > sel_min_energy_val
                    
                    return pulser_cut && ft_cut && muon01_cut && muon_cut && qc_cut && trig_cut && hit_cut && mult_cut && energy_cut
                end
                n_after = length(filtered_data)
                
                @debug "FileKey $fk: $n_before -> $n_after events"
                
            catch e
                @error "Error loading $fk: $(truncate_error(e))"
                log_fk = log_nt_fk((fk, ProcessStatus(0), n_before, 0, "", "", truncate_error(e)))
                return (data = nothing, log = log_fk, processed = false, filter_counts = Dict{String, Int}())
            end
        end
        
        total_time = canonicalize(Dates.Nanosecond(TimerOutputs.tottime(fk_timer)))
        total_allocated = Base.format_bytes(TimerOutputs.totallocated(fk_timer))
        
        log_fk = log_nt_fk((fk, ProcessStatus(1), n_before, n_after, total_time, total_allocated, ""))
        return (data = filtered_data, log = log_fk, processed = true, filter_counts = filter_counts)
    end

    # Process all filekeys in parallel
    @info "Loading and filtering $(length(filekeys)) jlevt files in parallel..."
    results_parallel = parallel(filekeys, load_and_filter_fk, log_nt_fk, wpool; 
                                timeout=timeout, retry=false, 
                                process_name="$period-$run-$(nameof(var"#self#"))")

    # Collect filtered data from all workers
    @info "Combining filtered data from all workers..."
    filtered_tables = Table[]
    for (fk, res) in results_parallel
        if res.processed && !isnothing(res.data) && !isempty(res.data)
            push!(filtered_tables, res.data)
        end
    end
    
    # Combine all filtered data efficiently
    @info "Concatenating $(length(filtered_tables)) filtered tables..."
    combined_data = if isempty(filtered_tables)
        Table()
    elseif length(filtered_tables) == 1
        first(filtered_tables)
    else
        reduce(vcat, filtered_tables)
    end
    @info "Combined $(length(combined_data)) filtered events from $(length(filtered_tables)) files"

    # Compute totals from parallel results (no need to reload data)
    # Note: Failed/timeout tasks may have "-" strings instead of integers, so we filter for numeric values
    n_total_before = sum(res.log[Symbol("Events Before")] for (_, res) in results_parallel if res.log[Symbol("Events Before")] isa Number)
    n_total_after = sum(res.log[Symbol("Events After")] for (_, res) in results_parallel if res.log[Symbol("Events After")] isa Number)
    
    # Aggregate filter statistics from all workers (exact counts, not scaled)
    @info "Aggregating filter statistics from all workers..."
    aggregated_filter_counts = Dict{String, Int}()
    for (_, res) in results_parallel
        if res.processed && hasproperty(res, :filter_counts)
            for (filter_name, count) in res.filter_counts
                aggregated_filter_counts[filter_name] = get(aggregated_filter_counts, filter_name, 0) + count
            end
        end
    end
    
    # Convert aggregated counts to filter_stats with survival fractions
    filter_stats = Dict{String, NamedTuple}()
    if n_total_before > 0
        for (filter_name, passing) in aggregated_filter_counts
            filter_stats[filter_name] = (
                passing=passing, 
                total=n_total_before, 
                sf=round(passing/n_total_before*100, digits=2)
            )
        end
        # Add exact combined filter stats
        filter_stats["ALL FILTERS COMBINED"] = (
            passing=n_total_after, 
            total=n_total_before, 
            sf=round(n_total_after/n_total_before*100, digits=2)
        )
    end

    # Compute survival fractions on combined filtered data
    sf = _skm_compute_survival_fractions(combined_data)

    # Write combined SKM file
    @info "Writing $(basename(skmfilename))..."
    write_files(skmfilename, use_cache=true, mode=CreateOrReplace()) do outfilename
        lh5open(outfilename, "w") do ds
            skm_out = store_filtered ? _skm_filtered_payload(combined_data, output_keys_config) : combined_data
            ds[:jlskm] = LegendEventAnalysis._fix_vov(skm_out)
        end
    end
    @info "Finished writing $(basename(skmfilename))"

    total_processing_time = canonicalize(now() - start_time)

    # Generate report
    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $total_processing_time")
    lreport!(report, "")
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "")
    lreport!(report, "# Summary")
    lreport!(report, "- **FileKeys processed**: $(length(filekeys))")
    lreport!(report, "- **Total events before filtering**: $n_total_before")
    lreport!(report, "- **Total events after filtering**: $n_total_after")
    lreport!(report, "- **Overall SF**: $(round(n_total_after/n_total_before*100, digits=2))%")
    lreport!(report, "")
    lreport!(report, "# Survival Fractions (filtered data)")
    lreport!(report, "- **SF PSD**: $(round(ustrip(sf.psd), digits=2))%")
    lreport!(report, "- **SF LAr**: $(round(ustrip(sf.lar), digits=2))%")
    lreport!(report, "- **SF LAr & PSD**: $(round(ustrip(sf.larpsd), digits=2))%")
    lreport!(report, "")
    lreport!(report, "# Per-FileKey Results")
    lreport!(report, create_logtbl(results_parallel))
    
    # Add filter statistics section
    lreport!(report, "")
    lreport!(report, "# Event Selection Filters")
    lreport!(report, "Applied filters and their individual survival fractions:")
    lreport!(report, "")
    if !isempty(filter_stats)
        lreport!(report, "| Filter | Passing Events | Total Events | SF (%) |")
        lreport!(report, "|--------|----------------|--------------|--------|")
        for (filter_name, stats) in sort(collect(filter_stats), by=x->x[1])
            # Filter names are already markdown-escaped
            lreport!(report, "| $(filter_name) | $(stats.passing) | $(stats.total) | $(stats.sf)% |")
        end
    else
        lreport!(report, "No filter statistics available.")
    end
    
    # Add output keys section
    lreport!(report, "")
    lreport!(report, "# Output Keys in jlskm")
    lreport!(report, _skm_get_output_keys_summary(output_keys_config, store_filtered))

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    flush(stdout)
    return true
end
