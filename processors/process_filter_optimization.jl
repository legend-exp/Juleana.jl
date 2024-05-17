function process_filter_optimization(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Union{Int, Bool}=false, max_wvfs::Int=15000)
    
    @info "Optimize filter for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) channels"

    dsp_config = DSPConfig(dataprod_config(l200).dsp(filekey).default)
    @debug "Loaded DSP config: $(dsp_config)"

    pars_tau = get_values(l200.par.rpars.pz[period, run])
    @debug "Loaded decay times"

    optimization_config = dataprod_config(l200).dsp(filekey).optimization
    @debug "Loaded optimization config: $(optimization_config)"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.fltopt), string(period)))
    pars_db = PropDict(l200.par.rpars.fltopt[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" else @info "Only process channels not in pars_db" end

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Status, Symbol("Filter Type"), Symbol("Rise Time"), Symbol("Flat-Top Time"), Symbol("Min. FWHM"), :Error)}
    
    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # flush stdout
    flush(stdout)

    function ch_filter_optimization(chinfo_ch::NamedTuple)

        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        @debug "Processing channel $ch ($det)"

        optimization_config_ch = merge(optimization_config.default, ifelse(haskey(optimization_config, det), optimization_config[det], PropDict()))

        result_rt_dict = Dict{Symbol, NamedTuple}()
        result_ft_dict = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(det) already processed, check missing filters"
            for filter_type in keys(optimization_config_ch)
                if filter_type == :sg
                    continue
                end
                if haskey(pars_db[det], filter_type)
                    @debug "Filter $filter_type already processed, skip"
                    log_info = log_nt((ch, det, ProcessStatus(1), filter_type, pars_db[det][filter_type].rt, pars_db[det][filter_type].ft, pars_db[det][filter_type].min_fwhm, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[filter_type] = log_info
                    processed_dict[filter_type] = false
                end
            end
        end

        # check if all filters are already processed
        if length(keys(processed_dict)) == length(keys(optimization_config_ch)) - 1
            @debug "All filters already processed, skip channel"
            return (processed = processed_dict, log = log_info_dict)
        end

        filename = l200.tier[:jlpeaks, filekey, ch]
        if !isfile(filename)
            @warn "File $filename does not exist, Skip channel $ch"
            throw(LoadError(string(basename(filename)), 154,"File $(basename(filename)) does not exist"))
        end
        yield()

        # load data
        wvfs_ch_fep = nothing
        try
            data = lh5open(filename, "r")
            @debug "Loading Tl208 FEP data from $(filename)"
            wvfs_ch_fep = data[ch].jlpeaks.Tl208FEP.waveform_presummed[:]
            close(data)
            if length(wvfs_ch_fep) > max_wvfs
                @warn "Tl208 FEP events exceed $max_wvfs, keep only first $max_wvfs events"
                wvfs_ch_fep = wvfs_ch_fep[1:max_wvfs]
            end
        catch e
            @error "FEP data from $(basename(filename)) cannot be loaded: $e"
            throw(LoadError(string(basename(filename)), 154,"FEP data from $(basename(filename)) cannot be loaded: $e"))
        end
        yield()

        GC.gc()

        @showprogress desc="Computing $det ..." for filter_type in keys(optimization_config_ch)
            if filter_type == :sg
                continue
            end
            if haskey(processed_dict, filter_type)
                continue
            end
            
            try
                @debug "Optimize $filter_type filter"

                optimization_config_flt = optimization_config_ch[filter_type]
                # unpack config
                e_grid_rt            = getproperty(dsp_config, Symbol("e_grid_rt_$(filter_type)"))
                e_grid_ft            = getproperty(dsp_config, Symbol("e_grid_ft_$(filter_type)"))

                # optimize RT
                enc_grid = nothing
                try
                    @debug "Generate $filter_type ENC filter grid"
                    enc_grid = getfield(Main, Symbol("dsp_$(filter_type)_rt_optimization"))(wvfs_ch_fep, dsp_config, pars_tau[det].tau; ft=optimization_config_flt.ft_fixed)
                catch e
                    @error "Filter: $filter_type RT DSP for FEP: $e"
                    throw(ErrorException("Error in $filter_type RT DSP for FEP: $e"))
                end
                yield()
                GC.gc()
                result_rt, report_rt = nothing, nothing
                try
                    result_rt, report_rt = fit_enc_sigmas(enc_grid, e_grid_rt, optimization_config_flt.min_enc, optimization_config_flt.max_enc, optimization_config_flt.nbins_enc_sigmas, optimization_config_flt.rel_cut_fit_enc_sigmas)
                catch e
                    @error "Failed $filter_type rise time extraction: $e"
                    throw(ErrorException("Error in $filter_type rise time extraction: $e"))
                end
                @debug format("Found optimal $filter_type RT at $(result_rt.rt) with ENC {:.2f} ADC", result_rt.min_enc)
                yield()

                p = plot(report_rt)
                title!(p, get_plottitle(filekey, det, "Noise Sweep"; additiional_type=string(filter_type)))
                savelfig(savefig, p, l200, filekey, ch, Symbol("noise_sweep_$(filter_type)"))

                # optimize FT
                yield()
                GC.gc()
                e_grid = nothing
                try
                    @debug "Generate $filter_type FT energy grid"
                    e_grid = getfield(Main, Symbol("dsp_$(filter_type)_ft_optimization"))(wvfs_ch_fep, dsp_config, pars_tau[det].tau, mvalue(result_rt.rt))
                catch e
                    @error "Filter: $filter_type FT DSP for FEP: $e"
                    throw(ErrorException("Error in $filter_type FT DSP for FEP: $e"))
                end
                yield()
                GC.gc()
                result_ft, report_ft = nothing, nothing
                try
                    result_ft, report_ft = fit_fwhm_ft_fep(e_grid, e_grid_ft, result_rt.rt, optimization_config_flt.min_e_fep, optimization_config_flt.max_e_fep, optimization_config_flt.nbins_e_fep, optimization_config_flt.rel_cut_fit_e_fep)
                catch e
                    @error "Failed $filter_type flat-top time extraction: $e"
                    throw(ErrorException("Error in $filter_type flat-top time extraction: $e"))
                end
                @debug "Found optimal $filter_type FT at $(result_ft.ft) with FWHM $(round(u"keV", result_ft.min_fwhm, digits=2))"
                yield()
                p = plot(report_ft)
                title!(get_plottitle(filekey, det, "FEP FT Scan"; additiional_type=string(filter_type)))
                savelfig(savefig, p, l200, filekey, ch, Symbol("fwhm_ft_scan_$(filter_type)"))

                log_info = log_nt((ch, det, ProcessStatus(1), filter_type, result_rt.rt, result_ft.ft, result_ft.min_fwhm, "-"))

                # add results to dict
                result_rt_dict[filter_type] = result_rt
                result_ft_dict[filter_type] = result_ft
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = true

                # call garbage collector
                GC.gc()
                yield()
            catch e
                @error "Filter: $filter_type filter optimization: $e"
                log_info = log_nt((ch, det, ProcessStatus(0), filter_type, "-", "-", "-", "$e"))
                # add results to dict
                log_info_dict[filter_type] = log_info
                processed_dict[filter_type] = false
            end
        end
        # return results
        filter_types_processed = [k for (k, v) in processed_dict if v]
        result = NamedTuple{Tuple(filter_types_processed)}([(merge(result_ft_dict[ft], result_rt_dict[ft])) for ft in filter_types_processed]...)
        return (result = result, log = log_info_dict, processed = processed_dict)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_flt = parallel(chinfo, ch_filter_optimization, log_nt, wpool; timeout=timeout, retry=false)

    @info "Finished filter optimization"

    pars_db = create_pars(pars_db, result_flt)
    writelprops(l200.par.rpars.fltopt[period], run, pars_db)
    writevalidity(l200.par.rpars.fltopt, filekey)
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, flt_optimization_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_flt))

    @info "Write log report"
    writelreport(get_reportfilename(l200, filekey, :filter_optimization), report)
    @info report
    
    # flush stdout
    flush(stdout)
end

