function process_aoe_calibration(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Union{Int, Bool}=false)

    @info "Calibrate AoE for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true) |> filterby(@pf $low_aoe_status .== :valid)
    @info "Loaded channel info with $(length(chinfo)) channels"

    aoe_config = dataprod_config(l200).psd(filekey).aoe
    @debug "Loaded aoe config: $(aoe_config)"

    pars_energy = get_values(l200.par.rpars.ecal[period, run])
    @debug "Loaded energy parameters"

    @debug "Create pars db"
    mkpath(data_path(l200.par.rpars.aoecal[period]))
    pars_db = PropDict(l200.par.rpars.aoecal[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" end

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Status, Symbol("Number of fitted Bands"), Symbol("μ Correction Mean normalized Residuals"), Symbol("σ Correction Mean normalized Residuals"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))
    
    # flush stdout
    flush(stdout)

    function ch_aoe_calibration(chinfo_ch::NamedTuple)

        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(det) already processed, skip"
            pars_det = pars_db[det]
            log_ch = log_nt(ch, det, ProcessStatus(1), length(pars_det.μ_compton.μ), mean(pars_det.µ_compton.gof.residuals_norm), mean(pars_det.σ_compton.gof.residuals_norm), "Already processed --> skipped.")
            return (processed = false, log = log_ch)
        end

        @info "Processing channel $ch ($det)"

        hitchfilename = l200.tier[:jlhitch, filekey, ch]
        # load data file
        if !isfile(hitchfilename)
            @error "Hit file $hitchfilename not found"
            throw(ErrorException("Hit file not found"))
        end

        aoe_config_ch = merge(aoe_config.default, get(aoe_config, det, PropDict()))

        compton_bands  = aoe_config_ch.compton_bands
        compton_window = aoe_config_ch.compton_window
        p_value_cut    = aoe_config_ch.p_value # what is this? p values threshold 
        e_type_aoe     = Symbol(aoe_config_ch.energy_type_aoe)
        e_type_e       = Symbol(aoe_config_ch.energy_type_e)

        if !haskey(pars_energy, det) || !haskey(pars_energy[det], e_type_e) || !haskey(pars_energy[det], e_type_aoe)
            @error "Energy calibration for $(det) not found"
            throw(ErrorException("Energy calibration for $(det) not found"))
        end

        e_cal, aoe, tab_data, ecal_func_str = nothing, nothing, nothing, nothing
        try
            tab_data = lh5open(hitchfilename)[ch, :jlhit, :dataQC][:]
            a = tab_data.a_sg # get a
            ecal_func_str = pars_energy[det][e_type_aoe].cal.func  # calibrate energy 
            e_cal = collect(ljl_propfunc(pars_energy[det][e_type_e].cal.func).(tab_data))
            aoe = ustrip.(a ./ ljl_propfunc(ecal_func_str).(tab_data)); # get aoe
        catch e
            @error "AoE and E data from $(basename(hitchfilename)) cannot be loaded: $(truncate_string(string(e)))"
            throw(LoadError(string(basename(hitchfilename)), 154, "AoE and E data from $(basename(hitchfilename)) cannot be loaded"))
        end

        p = histogram2d(e_cal, aoe, nbins=(0:0.5:3000, 0.2:5e-4:0.8), xlims=(0, 3000), ylims=(0.1, 0.9), size=(1200, 800), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy", ylabel="A/E (a.u.)", margin=5mm)
        plot!(p,guidefontsize=18,xguidefontsize = 18,yguidefontsize = 18,xtickfontsize = 12,ytickfontsize=12)
        xticks!(p, 0:250:3000)
        title!(p, get_plottitle(filekey, det, "AoE uncalibrated"))
        savelfig(savefig, p, l200, filekey, det, Symbol("aoe_uncalibrated_$e_type_e"))

        result_fit, report_fit, compton_band_peakhists = nothing, nothing, nothing
        try
            # get compton band peak histograms with generated peakstats
            compton_band_peakhists = generate_aoe_compton_bands(aoe, e_cal, compton_bands, compton_window)

            result_fit, report_fit = fit_aoe_compton(compton_band_peakhists.peakhists, compton_band_peakhists.peakstats, compton_bands,; uncertainty=true)
        catch e
            @error "AoE compton bands cannot be fitted: $(truncate_string(string(e)))"
            throw(ErrorException("AoE compton bands cannot be fitted"))
        end
        GC.gc()

        # generate plots of compton bands as gif
        # p = @animate for band in compton_bands fps=0.5
        #     report_band = report_fit[band]
        #     plot(report_band, title=format("{} A/E CC at $band keV ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)), legend=:topleft)
        #     xlims!(minimum(compton_band_peakhists.min_aoe), maximum(compton_band_peakhists.max_aoe))
        # end
        # gif(p, fps=0.5, joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-aoe_compton-bands_{}.gif", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch, string(e_type))))

        compton_bands = [band for band in keys(result_fit) if result_fit[band].gof.pvalue >= p_value_cut] # end here 
        μ = [result_fit[band].μ for band in compton_bands]
        σ = [result_fit[band].σ for band in compton_bands]

        # fit μ and σ with correction functions
        result, report = nothing, nothing
        try
            result, report = fit_aoe_corrections(compton_bands, μ, σ,; e_expression = ecal_func_str)
        catch e
            @error "AoE corrections cannot be fitted: $(truncate_string(string(e)))"
            throw(ErrorException("AoE corrections cannot be fitted"))
        end
        
        p = plot(report.report_µ)
        title!(p, get_plottitle(filekey, det, "A/E μ"), subplot=1)
        savelfig(savefig, p, l200, filekey, det, Symbol("compton_bands_mu_$e_type_e"))

        p = plot(report.report_σ)
        title!(p, get_plottitle(filekey, det, "A/E σ"), subplot=1)
        savelfig(savefig, p, l200, filekey, det, Symbol("compton_bands_sigma_$e_type_e"))

        # correct aoe
        aoe_corr = ljl_propfunc(result.func).(tab_data)
        p = histogram2d(ustrip.(u"keV", e_cal), aoe_corr, nbins=(0:0.5:3000, -20:0.1:10), xlims=(0, 3000), ylims=(-20, 10), size=(1300, 700), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel=L"Energy\ (keV)", ylabel=L"A/E\ (\sigma_{A/E})")
        plot!(margin=1mm, thickness_scaling=1.6, dpi=600)
        xticks!(0:250:3000)
        title!(p, get_plottitle(filekey, det, "normalized A/E"))
        savelfig(savefig, p, l200, filekey, det, Symbol("aoe_normalized_$e_type_e"))

        @info "AoE calibration for channel $ch ($det) finished"
        log_ch = log_nt(ch, det, ProcessStatus(1), length(compton_bands), mean(result.µ_compton.gof.residuals_norm), mean(result.σ_compton.gof.residuals_norm), "-")

        # free memory
        GC.gc()

        return (result = result, log = log_ch, processed = true)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_aoecal = parallel(chinfo, ch_aoe_calibration, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period-", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished AoE calibration"

    pars_db = create_pars(pars_db, result_aoecal)
    writelprops(l200.par.rpars.aoecal[period], run, pars_db)
    writevalidity(l200.par.rpars.aoecal, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, aoe_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_aoecal))

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, :aoe_cal), report)
    @info report

    # flush stdout
    flush(stdout)
end
