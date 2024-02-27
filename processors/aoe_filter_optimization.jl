function process_aoe_optimization(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=300, max_wvfs::Int=15000)

    @info "Optimize PSD filter for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = Table(channelinfo(l200, filekey; system=:geds, only_processable=true)) |> filterby(@pf $aoe_status .== :valid)
    @info "Loaded channel info with $(length(chinfo)) channels"

    dsp_config = DSPConfig(dataprod_config(l200).dsp(filekey).default)
    @debug "Loaded DSP config: $(dsp_config)"

    pars_tau = get_values(l200.par.rpars.pz[period, run])
    @debug "Loaded decay times"

    pars_fltoptimization = get_values(l200.par.rpars.fltopt[period, run])
    @debug "Loaded energy optimization parameters"

    optimization_config = dataprod_config(l200).dsp(filekey).optimization
    @debug "Loaded optimization config: $(optimization_config)"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.aoeopt), string(period)))
    pars_db = ifelse(l200.par.rpars.aoeopt[period, run] isa LegendDataManagement.NoSuchPropsDBEntry, PropDict(), l200.par.rpars.aoeopt[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" end

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Status, Symbol("Window length"), Symbol("Surrival Fraction"), Symbol("Number of DEP"), Symbol("Number of SEP"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))
    
    # move all variables to workers
    @everywhere begin
        l200 = $l200
        dsp_config = $dsp_config
        filekey = $filekey
        pars_tau = $pars_tau
        pars_fltoptimization = $pars_fltoptimization
        optimization_config = $optimization_config
        chinfo = $chinfo
        pars_db = $pars_db
        reprocess = $reprocess
        log_nt = $log_nt
        max_wvfs = $max_wvfs
    end


    @everywhere function ch_sg_optimization(chinfo_ch::NamedTuple)
        
        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(det) already processed, skip"
            log_ch = log_nt((ch, det, ProcessStatus(1), pars_db[det].sg.wl, pars_db[det].sg.min_sep_sf, pars_db[det].sg.n_dep, pars_db[det].sg.n_sep, "Already processed --> skipped."))
            return (processed = false, log = log_ch)
        end

        @info "Processing channel $ch ($det)"

        sg_config_ch = merge(optimization_config.default, ifelse(haskey(optimization_config, det), optimization_config[det], PropDict())).sg
        
        filename = get_peaksfilename(l200, filekey, ch)
        if !isfile(filename)
            @warn "File $filename does not exist, Skip channel $ch"
            throw(LoadError(string(basename(filename)), 154,"File $(basename(filename)) does not exist"))
        end
        
        wvfs_ch_dep = nothing
        wvfs_ch_sep = nothing
        try 
            data = lh5open(filename, "r")

            @debug "Loading Tl208 SEP and DEP data from $(filename)"
            wvfs_ch_dep_bi121fep = data[ch].Tl208DEP_Bi212FEP.waveform[:]
            e_ch_dep_bi121fep    = data[ch].Tl208DEP_Bi212FEP.daqenergy[:]
            wvfs_ch_dep          = wvfs_ch_dep_bi121fep[e_ch_dep_bi121fep .< quantile(e_ch_dep_bi121fep, sg_config_ch.dep_sep_quantile)]
            wvfs_ch_sep          = data[ch].Tl208SEP.waveform[:]

            close(data)
        catch e
            @error "DEP and SEP data from $(basename(filename)) cannot be loaded: $e"
            throw(LoadError(string(basename(filename)), 154,"DEP and SEP data from $(basename(filename)) cannot be loaded: $e"))
        end
        
        dsp_dep = nothing
        dsp_sep = nothing

        try
            # DSP
            @debug "Generating DSP AoE grid for SEP and DEP data"
            dsp_dep = dsp_sg_optimization(wvfs_ch_dep, dsp_config, pars_tau[det].tau, pars_fltoptimization[det])
            dsp_sep = dsp_sg_optimization(wvfs_ch_sep, dsp_config, pars_tau[det].tau, pars_fltoptimization[det])
        catch e
            @error "Failed DSP for DEP or SEP: $e"
            throw(ErrorException("Error in DSP for DEP or SEP: $e"))
        end

        # free memory
        GC.gc()

        dep_sep_after_qc = nothing

        try
            # generate simple QC cuts
            @debug "Use simple QC cuts for SEP and DEP"
            dep_sep_after_qc = qc_sg_optimization(dsp_dep, dsp_sep, sg_config_ch)
        catch e
            @error "Failed QC for DEP or SEP: $e"
            throw(ErrorException("QC for DEP or SEP: $e"))
        end
        
        # free memory
        GC.gc()

        result_sg_wl, report_sg_wl = nothing, nothing

        try
            # fit SG window length
            @debug "Sweep through window lengths for SEP and DEP and get SEP survival fraction after simple PSD cut on DEP"
            result_sg_wl, report_sg_wl = fit_sg_wl(dep_sep_after_qc, dsp_config.a_grid_wl_sg, sg_config_ch)    
        catch e
            @error "Failed SG window length optimization: $e"
            throw(ErrorException("SG window length optimization: $e"))
        end
        
        if length(report_sg_wl.sfs) > 0
            p = plot(report_sg_wl)
            title!(p, get_plottitle(filekey, det, "SG Filter Optimization"))
            savelfig(p, l200, filekey, ch, Symbol("sg_sweep"))
        else
            @warn "No SG sweep plot for channel $ch ($det)"
        end

        @info """Found optimal window length at $(result_sg_wl.wl) with survival fraction $(round(u"percent", result_sg_wl.sf, digits=2)) for channel $ch ($det)"""

        # write log
        log_ch = log_nt((ch, det, ProcessStatus(1), result_sg_wl.wl, result_sg_wl.sf, result_sg_wl.n_dep, result_sg_wl.n_sep, "-"))
        
        # free memory
        GC.gc()

        return (result = (sg = result_sg_wl, ), log = log_ch, processed = true)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_sg = parallel(chinfo, ch_sg_optimization, log_nt, wpool; timeout=timeout, retry=false)
    

    @info "Finished SG filter optimization"

    pars_db = create_pars(pars_db, result_sg)
    if !isempty(pars_db)
        writelprops(l200.par.rpars.aoeopt[period], run, pars_db)
        writevalidity(l200.par.rpars.aoeopt, filekey)
        @info "Saved pars to disk"
    end

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Time of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, sg_flt_optimization_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_sg))


    @info "Write log report"
    writelreport(get_logfilename(l200, filekey, :sg_filter_optimization), report)
    @info report
end

