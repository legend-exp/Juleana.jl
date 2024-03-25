function process_psd_calibration(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=300)

    @info "Calibrate AoE for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = Table(channelinfo(l200, filekey; system=:geds, only_processable=true)) |> filterby(@pf $aoe_status .== :valid)
    @info "Loaded channel info with $(length(chinfo)) channels"

    psd_config = dataprod_config(l200).psd(filekey)
    @debug "Loaded psd config: $(psd_config)"

    pars_ctc = get_values(l200.par.rpars.ctc[period, run])
    @debug "Loaded CTC parameters"

    pars_energy = get_values(l200.par.rpars.ecal[period, run])
    @debug "Loaded energy parameters"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.aoecal), string(period)))
    pars_db = ifelse(l200.par.rpars.aoecal[period, run] isa LegendDataManagement.NoSuchPropsDBEntry, PropDict(), l200.par.rpars.aoecal[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" end

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Status, Symbol("Number of fitted Bands"), Symbol("μ Correction Slope"), Symbol("μ Correction Intercept"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # move all variables to workers
    @everywhere begin
        l200 = $l200
        filekey = $filekey
        chinfo = $chinfo
        pars_db = $pars_db
        pars_energy = $pars_energy
        pars_ctc = $pars_ctc
        psd_config = $psd_config
        reprocess = $reprocess
        log_nt = $log_nt
    end

    @everywhere function ch_psd_calibration(chinfo_ch::NamedTuple)
        chinfo_ch = chinfo[1]
        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(det) already processed, skip"
            pars_det = pars_db[det]
            log_ch = log_nt(ch, det, "Success", pars_det.n_compton, pars_det.μ_scs[2], pars_det.μ_scs[1], "-")
            return (processed = false, log = log_ch)
        end

        @info "Processing channel $ch ($det)"

        hitchfilename = get_hitchfilename(l200, filekey, ch)
        # load data file
        if !isfile(hitchfilename)
            @error "Hit file $hitchfilename not found"
            throw(ErrorException("Hit file not found"))
        end

        psd_config_ch = merge(psd_config.default, get(psd_config, det, PropDict()))

        compton_bands  = psd_config_ch.compton_bands
        compton_window = psd_config_ch.compton_window
        p_value_cut    = psd_config_ch.p_value # what is this? p values threshold 
        e_type         = Symbol(psd_config_ch.energy_type)

        if !haskey(pars_energy, det) || !haskey(pars_energy[det], e_type)
            @error "Energy calibration for $(det) not found"
            throw(ErrorException("Energy calibration for $(det) not found"))
        end

        e_cal, aoe = nothing, nothing
         try
            data_hit = LHDataStore(hitchfilename, "r");
            tab_data = data_hit["$(ch)/dataQC/"]
            a = tab_data.a[:]; # get a
            ecal_func_str = pars_energy[det][e_type].cal.func  # calibrate energy 
            e_cal = collect(ljl_propfunc(ecal_func_str).(tab_data))
            aoe = ustrip.(a ./ e_cal); # get aoe  
         catch e
             @error "AoE and E data from $(basename(hitchfilename)) cannot be loaded: $e"
             throw(LoadError(string(basename(hitchfilename)), 154, "AoE and E data from $(basename(hitchfilename)) cannot be loaded"))
         end

        p = histogram2d(e_cal, aoe, nbins=(0:0.5:3000, 0.2:5e-4:0.8), xlims=(0, 3000), ylims=(0.1, 0.9), size=(1200, 800), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy", ylabel="A/E (a.u.)", margin=5mm)
        plot!(p,guidefontsize=18,xguidefontsize = 18,yguidefontsize = 18,xtickfontsize = 12,ytickfontsize=12)
        xticks!(p, 0:500:3000)
        title!(p, get_plottitle(filekey, det, "AoE uncalibrated"))
        savelfig(p, l200, filekey, ch, Symbol("aoe_uncalibrated_$e_type"))

        result_fit, report_fit, compton_band_peakhists = nothing, nothing, nothing
        try
            # get compton band peak histograms with generated peakstats
            compton_band_peakhists = generate_aoe_compton_bands(aoe, e_cal, compton_bands, compton_window)

            result_fit, report_fit = fit_aoe_compton(compton_band_peakhists.peakhists, compton_band_peakhists.peakstats, compton_bands,; uncertainty=true)
        catch e
            @error "AoE compton bands cannot be fitted: $e"
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
            @error "AoE corrections cannot be fitted: $e"
            throw(ErrorException("AoE corrections cannot be fitted"))
        end
        
        plot(report.report_µ)
        title!(get_plottitle(filekey, det, "A/E μ"), subplot=1)
        savelfig(p, l200, filekey, ch, Symbol("compton_bands_mu_$e_type"))

        plot(report.report_σ)
        title!(get_plottitle(filekey, det, "A/E σ"), subplot=1)
        savelfig(p, l200, filekey, ch, Symbol("compton_bands_sigma_$e_type"))

        # correct aoe
        aoe_corr = ljl_propfunc(result.func).(tab_data)
        p = histogram2d(ustrip.(u"keV", e_cal), aoe_corr, nbins=(0:0.5:3000, -20:0.1:10), xlims=(0, 3000), ylims=(-20, 10), size=(1300, 700), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel=L"Energy\ (keV)", ylabel=L"A/E\ (\sigma_{A/E})")
        plot!(margin=1mm, thickness_scaling=1.6, dpi=600)
        xticks!(0:250:3000)
        title!(p, get_plottitle(filekey, det, "normalized A/E"))
        savelfig(p, l200, filekey, ch, Symbol("aoe_normalized_$e_type"))

        @info "AoE calibration for channel $ch ($det) finished"
        log_ch = log_nt(ch, det, "Success", length(compton_bands), aoe_corrections.μ_scs[2], aoe_corrections.μ_scs[1], "-")

        # free memory
        GC.gc()
        close(data_hit)  
        return (result = (n_compton = length(compton_bands), μ_scs = aoe_corrections.μ_scs, σ_scs = aoe_corrections.σ_scs, μ = aoe_corrections.μ, σ = aoe_corrections.σ, e = aoe_corrections.e), log = log_ch, processed = true)
    end
 
    # get start time
    start_time = now()

    # execute in parallel
    result_aoecal = parallel(chinfo, ch_psd_calibration, log_nt, wpool; timeout=timeout, retry=false)

    @info "Finished PSD calibration"

    pars_db = create_pars(pars_db, result_aoecal)
    writelprops(l200.par.rpars.aoecal[period], run, pars_db)
    writevalidity(l200.par.rpars.aoecal, filekey)
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, psd_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_aoecal))

    @info "Write log report"
    writelreport(get_logfilename(l200, filekey, :aoe_cal), report)
    @info report
end
