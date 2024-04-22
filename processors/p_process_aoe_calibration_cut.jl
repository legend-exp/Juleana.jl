function p_process_aoe_calibration_cut(processing_config::PropDict, l200::LegendData, part::DataPartition,; reprocess::Bool=false, timeout::Union{Int, Bool}=false)
    
    @info "AoE calibration for partition $part"

    partinfo, run, period = get_partition_firstRunPeriod(l200, part)
    @info "Loaded partition info with $(length(partinfo)) runs"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = Table(channelinfo(l200, filekey; system=:geds, only_processable=true)) |> filterby(@pf $low_aoe_status .== :valid)
    @info "Loaded channel info with $(length(chinfo)) channels"

    aoe_config = dataprod_config(l200).psd(filekey).aoe.partition
    @debug "Loaded aoe config: $(aoe_config)"
    
    @debug "Create pars db"
    pars_db = ifelse(l200.par.ppars.aoe(filekey) isa LegendDataManagement.NoSuchPropsDBEntry, PropDict(), l200.par.ppars.aoe(filekey))

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" end

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Status, Symbol("Cut Value"), Symbol("SEP SF"), Symbol("FEP SF"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # move all variables to workers
    @everywhere begin
        l200 = $l200
        filekey = $filekey
        part = $part
        partinfo = $partinfo
        chinfo = $chinfo
        pars_db = $pars_db
        reprocess = $reprocess
        aoe_config = $aoe_config
        log_nt = $log_nt
    end
    
    @everywhere function ch_aoe_cut(chinfo_ch::NamedTuple)
        
        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(det) already processed, skip"
            log_info = log_nt((ch, det, ProcessStatus(1), pars_db[det].cut.lowcut, pars_db[det].peaks[:Tl208SEP].sf, pars_db[det].peaks[:Tl208FEP].sf, "Already processed --> skipped."))
            return (processed = true, log = log_info)
        end


        # load config
        aoe_config_ch = merge(aoe_config.default, get(aoe_config, det, PropDict()))

        compton_bands  = aoe_config_ch.compton_bands
        compton_window = aoe_config_ch.compton_window
        p_value_cut    = aoe_config_ch.p_value # what is this? p values threshold 
        e_type_aoe     = Symbol(aoe_config_ch.energy_type_aoe)
        e_type_e       = Symbol(aoe_config_ch.energy_type_e)
        e_type_aoe_cal = Symbol(aoe_config_ch.energy_type_aoe * "_cal")

        aoe_peaks = aoe_config_ch.aoe_peaks
        aoe_peak_names = Symbol.(aoe_config_ch.aoe_peaks_names)
        aoe_peak_dict = Dict(aoe_peak_names .=> aoe_peaks)

        sigma_high_sided = ifelse(chinfo_ch.high_aoe_status == :valid, aoe_config_ch.sigma_high_sided, NaN)

        t = nothing
        try
            t = fast_flatten([lh5open(
                ds -> begin
                    @debug "Reading from \"$(ds.data_store.filename)\""
                    dsp_out = ds[ch].dataQC[:]
                    Table(merge((aoe = ustrip.(dsp_out.a ./ ljl_propfunc(l200.par.rpars.ecal[period, run][det][e_type_aoe].cal.func).(dsp_out)), 
                        e = ljl_propfunc(l200.par.rpars.ecal[period, run][det][e_type_e].cal.func).(dsp_out),
                        a = dsp_out.a, drift_time = dsp_out.drift_time), 
                        (; e_type_aoe_cal => ljl_propfunc(l200.par.rpars.ecal[period, run][det][e_type_aoe].cal.func).(dsp_out))
                    ))
                end,
                l200.tier[:jlhitch, filekey, ch]
            ) for (period, run) in partinfo])
        catch e
            @error "AoE and E data for $det from cannot be loaded"
            throw(LoadError("AoE - E data", 154, "AoE and E data for $det from partition $(part) cannot be loaded"))
        end

        # load energy and aoe from dsp table
        e_cal, aoe = collect(t.e), collect(t.aoe)
        
        # plot raw aoe
        p = histogram2d(e_cal, aoe, nbins=(0:0.5:3000, 0.2:5e-4:0.8), xlims=(0, 3000), ylims=(0.1, 0.9), size=(1200, 800), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy", ylabel="A/E (a.u.)", margin=5mm)
        plot!(p,guidefontsize=18,xguidefontsize = 18,yguidefontsize = 18,xtickfontsize = 12,ytickfontsize=12)
        xticks!(p, 0:250:3000)
        title!(p, get_plottitle(filekey, det, "AoE uncalibrated"))
        savelfig(savefig, p, l200, part, filekey.setup, filekey.category, ch, Symbol("aoe_uncalibrated_$e_type_e"))

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
        result_corrections, report_corrections = nothing, nothing
        try
            result_corrections, report_corrections = fit_aoe_corrections(compton_bands, μ, σ,; e_expression = e_type_aoe_cal)
        catch e
            @error "AoE corrections cannot be fitted: $e"
            throw(ErrorException("AoE corrections cannot be fitted"))
        end
        
        p = plot(report_corrections.report_µ)
        title!(p, get_plottitle(filekey, det, "A/E μ"), subplot=1)
        savelfig(savefig, p, l200, part, filekey.setup, filekey.category, ch, Symbol("compton_bands_mu_$e_type_e"))

        p = plot(report_corrections.report_σ)
        title!(p, get_plottitle(filekey, det, "A/E σ"), subplot=1)
        savelfig(savefig, p, l200, part, filekey.setup, filekey.category, ch, Symbol("compton_bands_sigma_$e_type_e"))

        # correct AoE
        aoe = ljl_propfunc(result_corrections.func).(t)

        p = histogram2d(e_cal, aoe, nbins=(0:0.5:3000, -20:0.1:10), xlims=(0, 3000), ylims=(-20, 10), size=(1300, 700), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel=L"Energy\ (keV)", ylabel=L"A/E\ (\sigma_{A/E})")
        plot!(margin=1mm, thickness_scaling=1.6, dpi=600)
        xticks!(0:250:3000)
        title!(p, get_plottitle(filekey.setup, part, filekey.category, det, "normalized A/E"))
        savelfig(savefig, p, l200, part, filekey.setup, filekey.category, ch, Symbol("aoe_normalized_$e_type_e"))

        result_cut = nothing
        try
            @debug "Generate AoE cut"
            result_cut = get_aoe_cut(aoe, e_cal,; cut_search_interval=(-25.0, 0.0), window=[20.0u"keV", 20.0u"keV"], rtol=1e-5, bin_width_window=3.0u"keV", fixed_position=false, sigma_high_sided=sigma_high_sided)
        catch e
            @error "AoE cut for $det cannot be generated"
            throw(ErrorException("AoE cut for $det from partition $(part) cannot be generated"))
        end

        @debug "Found low A/E cut at $(round(result_cut.lowcut, digits=2)) and high A/E cut at $(round(result_cut.highcut, digits=2))"

        result_peaks, report_peaks = nothing, nothing
        try
            @debug "Generate AoE Surrival Fractions"
            result_peaks, report_peaks = get_peaks_surrival_fractions(aoe, e_cal, aoe_peaks, aoe_peak_names, aoe_config_ch.aoe_peaks_windows_left, aoe_config_ch.aoe_peaks_windows_right, result_cut.lowcut,; bin_width_window=3.0u"keV", low_e_tail=false, sigma_high_sided=result_cut.highcut)
        catch e
            @error "AoE peaks SF for $det cannot be generated"
            throw(ErrorException("AoE peaks SF for $det from partition $(part) cannot be generated"))
        end

        qbb_result = nothing
        try
            qbb_result = get_continuum_surrival_fraction(aoe, e_cal, aoe_config_ch.qbb, aoe_config_ch.qbb_window, result_cut.lowcut,; sigma_high_sided=result_cut.highcut)
        catch e
            @error "Qbb SF for $det cannot be generated"
            throw(ErrorException("Qbb SF for $det from partition $(part) cannot be generated"))
        end

        @debug "Found SEP Surrival Fraction at $(round(u"percent", result_peaks[:Tl208SEP].sf, digits=2))"
        @debug "Found FEP Surrival Fraction at $(round(u"percent", result_peaks[:Tl208FEP].sf, digits=2))"

        p = stephist(e_cal, nbins=2039-35:0.5:2039+35, label="Before", xlabel="Energy", ylabel="Counts / 0.5 keV", yscale=:log10)
        stephist!(e_cal[aoe .> result_cut.lowcut], nbins=2039-35:0.5:2039+35, label="After", xlabel="Energy", ylabel="Counts / 0.5 keV", yscale=:log10)
        plot!(margin=1mm, thickness_scaling=1.5, dpi=600, size=(1000, 700))
        title!("Qbb CC ($(qbb_result.window)) - SF: $(qbb_result.sf)", titlefontisze=8)
        plot!(plot_title=get_plottitle(filekey.setup, part, filekey.category, det, "A/E Performance"))
        savelfig(savefig, p, l200, part, filekey.setup, filekey.category, ch, Symbol("aoe_qbb_sf_$e_type_e"))


        peak_sf_plot = plot.([rep.after for rep in values(report_peaks)], titleloc=:left, titlefont=font(8), ticks=:native, legend=:bottomright; show_label=true, show_fit=false)
        for (p, rep_before) in zip(peak_sf_plot, [rep.before for rep in values(report_peaks)])
            plot!(p, rep_before,; show_label=true, show_fit=false)
            p.series_list[1][:label] = "After"
            p.series_list[2][:label] = "Before"
        end
        for (p, peak_name, res) in zip(peak_sf_plot, keys(result_peaks), values(result_peaks))
            xticks!(p, convert(Int, round(xlims(p)[1], digits=0)):10:convert(Int, round(xlims(p)[2], digits=0)))
            title!(p, "$peak_name ($(aoe_peak_dict[peak_name])) - SF: $(res.sf)")
        end
        p = plot(
            peak_sf_plot...,
            layout = @layout[grid(2, 2)], 
            size=(2000, 1200), legend=:bottomright,
            framestyle=:box,
            grid=true, minor=true, gridalpha=0.2, gridcolor=:black, gridlinewidth=0.5,
            xlabel="Energy (keV)", ylabel="Counts",
            dpi = 300, thickness_scaling = 2,
            yformatter=:plain, titlefont=12,
        )
        plot!(margin=1mm, thickness_scaling=1.2, dpi=600, size=(1200, 900))
        plot!(plot_title=get_plottitle(filekey.setup, part, filekey.category, det, "A/E Performance"))
        savelfig(savefig, p, l200, part, filekey.setup, filekey.category, ch, Symbol("aoe_peaks_sf_$e_type_e"))

        p = stephist(e_cal, nbins=0:0.5:3000, yscale=:log10, xlabel="Energy", label="Before AoE", ylabel="Counts / 0.2 keV")
        stephist!(e_cal[result_cut.lowcut .< aoe .< result_cut.highcut], nbins=0:0.5:3000, yscale=:log10, label="After AoE")
        xticks!(0:250:3000)
        title!(get_plottitle(filekey.setup, part, filekey.category, det, "A/E Performance"))
        plot!(margin=1mm, thickness_scaling=1.2, dpi=600, size=(1000, 600), fontfamily=:sansserif)
        savelfig(savefig, p, l200, part, filekey.setup, filekey.category, ch, Symbol("aoe_energy_afterAoE_$e_type_e"))


        p = stephist(e_cal, nbins=0:0.5:3000, yscale=:log10, xlabel="Energy", label="Before AoE", ylabel="Counts / 0.5 keV")
        stephist!(e_cal[result_cut.lowcut .< aoe .< result_cut.highcut], nbins=0:0.5:3000, yscale=:log10, label="After AoE")
        stephist!(e_cal, nbins=1550:0.5:1700, inset = (1, bbox(0.2, 0.72, 0.4, 0.2, :top)), subplot = 2)
        stephist!(e_cal[result_cut.lowcut .< aoe .< result_cut.highcut], nbins=1550:0.5:1700, subplot = 2, legend=:none, ylabel="Counts / 0.5 keV", xlabel="")
        xticks!(0:250:3000, subplot = 1)
        xticks!(1500:20:1700, subplot = 2)
        title!(get_plottitle(filekey.setup, part, filekey.category, det, "A/E Performance"), subplot=1)
        plot!(margin=1mm, thickness_scaling=1.2, dpi=600, size=(1000, 600), fontfamily=:sansserif)
        plot!(ylabelfontsize=8, subplot=2)
        savelfig(savefig, p, l200, part, filekey.setup, filekey.category, ch, Symbol("aoe_energy_afterAoE_zoom_$e_type_e"))

        p = histogram2d(e_cal, aoe, nbins=(0:0.5:3000, -25:0.02:10), xlims=(0, 3000), ylims=(-25, 10), size=(1000, 600), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy", ylabel="A/E (σ)")
        plot!(margin=1mm, thickness_scaling=1.6, dpi=600, size=(1300, 700), xticks=(0:250:3000), yticks=(-26:2:10), fontfamily=:sansserif)
        hline!([result_cut.lowcut, result_cut.highcut], color=:red, label="Cut", lw=2.5)
        hspan!([-50, result_cut.lowcut, result_cut.highcut, 50], color=:red, alpha=0.2, label="", lw=0)
        title!(p, get_plottitle(filekey.setup, part, filekey.category, det, "A/E Classifier"))
        savelfig(savefig, p, l200, part, filekey.setup, filekey.category, ch, Symbol("aoe_withcuts_$e_type_e"))

        # save results
        result = (
            cut = result_cut,
            peaks = result_peaks,
            qbb = qbb_result,
            e_type = e_type_e,
            sigma_high_sided = sigma_high_sided,
        )

        log_info = log_nt((ch, det, ProcessStatus(1), result_cut.lowcut, result.peaks[:Tl208SEP].sf, result.peaks[:Tl208FEP].sf, "-"))
        return (result = result, log = log_info, processed = true)
    end

    # get start time
    start_time = now()

    result_aoe = parallel(chinfo, ch_aoe_cut, log_nt, wpool; timeout=timeout)

    @info "Finished AoE cut generation"

    pars_db = create_pars(pars_db, result_aoe)
    writelprops(l200.par.ppars.aoe, part, pars_db)
    writevalidity(l200.par.ppars.aoe, filekey, part)
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, aoe_part_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey, part))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_aoe))

    @info "Write log report"
    writelreport(get_reportfilename(l200, filekey.setup, part, filekey.category, :aoe), report)
    @info report
end

