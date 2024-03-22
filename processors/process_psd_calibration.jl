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
        p_value        = psd_config_ch.p_value
        e_type         = Symbol(psd_config_ch.energy_type)

        if !haskey(pars_energy, det) || !haskey(pars_energy[det], e_type)
            @error "Energy calibration for $(det) not found"
            throw(ErrorException("Energy calibration for $(det) not found"))
        end

        e, aoe = nothing, nothing
        try
            data_hit = LHDataStore(hitchfilename, "r");
            # get a
            a = data_hit["$(ch)/dataQC/a"][:];
            # get energy for best resolution
            e = data_hit["$(ch)/dataQC/$(e_type)"][:];
            e  = e .* pars_energy[det][e_type].m_calib .+ pars_energy[det][e_type].n_calib;
            # get aoe
            aoe = ustrip.(a ./ e);
            close(data_hit)
        catch e
            @error "AoE and E data from $(basename(hitchfilename)) cannot be loaded: $e"
            throw(LoadError(string(basename(hitchfilename)), 154, "AoE and E data from $(basename(hitchfilename)) cannot be loaded"))
        end

        p = histogram2d(e, aoe, nbins=(0:0.5:3000, 0.2:5e-4:0.8), xlims=(0, 3000), ylims=(0.1, 0.9), size=(1200, 800), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy", ylabel="A/E (a.u.)", margin=5mm)
        xticks!(p, 0:250:3000)
        title!(p, get_plottitle(filekey, det, "AoE Uncalibrated"))
        savelfig(savefig, p, l200, filekey, ch, Symbol("aoe_uncalibrated_$e_type"))

        result_fit, report_fit, compton_band_peakhists = nothing, nothing, nothing
        try
            # get compton band peak histograms with generated peakstats
            compton_band_peakhists = generate_aoe_compton_bands(aoe, e, compton_bands, compton_window)

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

        compton_bands = [band for band in keys(result_fit) if result_fit[band].p_value >= p_value]
        μ = [result_fit[band].μ for band in compton_bands]
        σ = [result_fit[band].σ for band in compton_bands]

        # fit μ and σ with correction functions
        aoe_corrections = nothing
        try
            aoe_corrections = fit_aoe_corrections(compton_bands, μ, σ)
        catch e
            @error "AoE corrections cannot be fitted: $e"
            throw(ErrorException("AoE corrections cannot be fitted"))
        end
        
        # plot μ and σ with correction functions
        p = scatter(aoe_corrections.e, aoe_corrections.μ, ms=5, color=:black, layout = @layout[grid(2, 1, heights=[0.8, 0.2])], label=L"\mu_{SCS}", margin=5mm, framestyle=:box)
        plot!(xlabel=L"Energy\ (keV)", ylabel=L"\mu_{A/E} (a.u.)", xticks = ustrip.(minimum(compton_bands):200u"keV": maximum(compton_bands)), xlims=ustrip.((minimum(compton_bands)-50u"keV", maximum(compton_bands)+50u"keV")), legend = :topright)
        plot!(ylims=(0.95*mvalue(median(aoe_corrections.μ)), 1.05*mvalue(median(aoe_corrections.μ))), subplot=1, xlabel="", xticks = :none, bottom_margin=-14mm)
        plot!((0.0:1500:3000), aoe_corrections.f_μ_scs((0.0:1500:3000)u"keV"), plot_ribbon=true, linealpha=0.4, label="Best Fit: $(round(aoe_corrections.μ_scs[1], digits=2)) + x*$(round(aoe_corrections.μ_scs[1]*1000, digits=2))e-3", line_width=3.5, color=:red, subplot=1, xformatter=_->"")
        plot!(ustrip.(aoe_corrections.e), (aoe_corrections.f_μ_scs.(aoe_corrections.e) .- aoe_corrections.μ) ./ aoe_corrections.μ .* 100 , label="", ylabel="Residuals (%)", line_width=2, color=:black, st=:scatter, ylims = (-5.0, 5.0), markershape=:x, subplot=2, framestyle=:box)
        title!(get_plottitle(filekey, det, "A/E μ"), subplot=1)
        savelfig(savefig, p, l200, filekey, ch, Symbol("compton_bands_mu_$e_type"))

        x_fit_σ = minimum(compton_bands)-50u"keV":0.1u"keV": maximum(compton_bands)+50u"keV"
        p = scatter(aoe_corrections.e, aoe_corrections.σ, ms=5, color=:black, layout = @layout[grid(2, 1, heights=[0.8, 0.2])], label=L"\sigma_{SCS}", margin=5mm, framestyle=:box)
        plot!(xlabel=L"Energy\ (keV)", ylabel=L"\sigma_{A/E} (a.u.)", xticks = ustrip.(minimum(compton_bands):200u"keV":maximum(compton_bands)), xlims=ustrip.((minimum(compton_bands)-50u"keV", maximum(compton_bands)+50u"keV")), legend = :topright)
        plot!(ylims=(0.1*mvalue(aoe_corrections.f_σ_scs(maximum(compton_bands))), 2*mvalue(aoe_corrections.f_σ_scs(minimum(compton_bands)))), subplot=1, xlabel="", xticks = :none, bottom_margin=-14mm)
        plot!(ustrip.(x_fit_σ), aoe_corrections.f_σ_scs.(x_fit_σ), plot_ribbon=true, linealpha=0.4, label=format("Best Fit: sqrt({:.2E}+({:.2E}/x^2)", ustrip.(mvalue.(aoe_corrections.σ_scs))...), line_width=3.5, color=:red, subplot=1, xformatter=_->"")
        plot!(ustrip.(aoe_corrections.e), (aoe_corrections.f_σ_scs.(aoe_corrections.e) .- aoe_corrections.σ) ./ aoe_corrections.σ .* 100 , label="", ylabel="Residuals (%)", line_width=2, color=:black, st=:scatter, ylims = (-50.0, 50.0), markershape=:x, subplot=2, framestyle=:box)
        title!(get_plottitle(filekey, det, "A/E σ"), subplot=1)
        savelfig(savefig, p, l200, filekey, ch, Symbol("compton_bands_sigma_$e_type"))
        # correct aoe
        correct_aoe!(aoe, e, aoe_corrections)


        p = histogram2d(ustrip.(u"keV", e), aoe, nbins=(0:0.5:3000, -20:0.1:10), xlims=(0, 3000), ylims=(-20, 10), size=(1300, 700), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel=L"Energy\ (keV)", ylabel=L"A/E\ (\sigma_{A/E})")
        plot!(margin=1mm, thickness_scaling=1.6, dpi=600)
        xticks!(0:250:3000)
        title!(p, get_plottitle(filekey, det, "normalized A/E"))
        savelfig(savefig, p, l200, filekey, ch, Symbol("aoe_normalized_$e_type"))

        @info "AoE calibration for channel $ch ($det) finished"

        log_ch = log_nt(ch, det, "Success", length(compton_bands), aoe_corrections.μ_scs[2], aoe_corrections.μ_scs[1], "-")

        # free memory
        GC.gc()

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