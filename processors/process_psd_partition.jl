function process_psd_partition(processing_config::PropDict, l200::LegendData, part::DataPartition,; reprocess::Bool=false, timeout::Int=300)
    
    @info "PSD calibration for partition $part"

    partinfo = partitioninfo(l200)[part]
    period = filter(row -> row.period == minimum(partinfo.period), partinfo).period[1]
    partition_period = partinfo[[p == period for p in partinfo.period]]
    run = filter(row -> row.run == minimum(partition_period.run), partition_period).run[1]
    @info "Loaded partition info with $(length(partinfo)) runs"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = Table(channelinfo(l200, filekey; system=:geds, only_processable=true)) |> filterby(@pf $aoe_status .== :valid)
    @info "Loaded channel info with $(length(chinfo)) channels"

    psd_config = dataprod_config(l200).psd(filekey).partition
    @debug "Loaded psd config: $(psd_config)"
    
    @debug "Create pars db"
    pars_db = ifelse(l200.par.ppars.aoe[part] isa LegendDataManagement.NoSuchPropsDBEntry, PropDict(), l200.par.ppars.aoe[part])

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
        psd_config = $psd_config
        log_nt = $log_nt
    end
    
    @everywhere function ch_psd_cut(chinfo_ch::NamedTuple)
        
        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(det) already processed, skip"
            log_info = log_nt((ch, det, ProcessStatus(1), pars_db[det].cut.lowcut, pars_db[det].peaks[:Tl208SEP].sf, pars_db[det].peaks[:Tl208FEP].sf, "Already processed --> skipped."))
            return (processed = true, log = log_info)
        end


        # load config
        psd_config_ch = merge(psd_config.default, get(psd_config, det, PropDict()))


        psd_peaks = psd_config_ch.psd_peaks
        psd_peak_names = Symbol.(psd_config_ch.psd_peaks_names)
        psd_peak_dict = Dict(psd_peak_names .=> psd_peaks)

        e_type = Symbol(psd_config_ch.energy_type)

        sigma_high_sided = psd_config_ch.sigma_high_sided

        t = nothing
        try
            t = fast_flatten([lh5open(
                ds -> begin
                    @debug "Reading from \"$(ds.data_store.filename)\""
                    a = ds["$(ch)/dataQC/a"][:]
                    e = ds["$(ch)/dataQC/$(e_type)"][:] .* l200.par.rpars.ecal[period, run][det][e_type].m_calib .+ l200.par.rpars.ecal[period, run][det][e_type].n_calib
                    Table(aoe = correct_aoe!(ustrip.(a ./ e), e, l200.par.rpars.aoecal[period, run][det]), e = e)
                end,
                get_hitchfilename(l200, filekey.setup, period, run, filekey.category, ch)
            ) for (period, run) in partinfo])
        catch e
            @error "AoE and E data for $det from cannot be loaded"
            throw(LoadError("AoE - E data", 154, "AoE and E data for $det from partition $(part) cannot be loaded"))
        end

        e, aoe = t.e, t.aoe

        p = histogram2d(e, aoe, nbins=(0:0.5:3000, -25:0.05:10), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy", ylabel="A/E (σ)")
        plot!(margin=1mm, thickness_scaling=1.6, dpi=600, xlims=(0, 3000), ylims=(-25, 10), size=(1300, 700), xticks=(0:250:3000), yticks=(-26:2:10), fontfamily=:sansserif)
        title!(p, get_plottitle(filekey.setup, part, filekey.category, det, "normalized A/E"))
        savelfig(savefig, p, l200, part, filekey.setup, filekey.category, ch, Symbol("aoe_normalized_$e_type"))

        result_cut = nothing
        try
            @debug "Generate PSD cut"
            result_cut = get_psd_cut(aoe, e,; cut_search_interval=(-25.0, 0.0), window=[20.0u"keV", 20.0u"keV"], rtol=1e-5, bin_width_window=3.0u"keV", fixed_position=false, sigma_high_sided=sigma_high_sided)
        catch e
            @error "PSD cut for $det cannot be generated"
            throw(ErrorException("PSD cut for $det from partition $(part) cannot be generated"))
        end

        @debug "Found low A/E cut at $(round(result_cut.lowcut, digits=2)) and high A/E cut at $(round(result_cut.highcut, digits=2))"

        result_peaks, report_peaks = nothing, nothing
        try
            @debug "Generate PSD Surrival Fractions"
            result_peaks, report_peaks = get_peaks_surrival_fractions(aoe, e, psd_peaks, psd_peak_names, psd_config_ch.psd_peaks_windows_left, psd_config_ch.psd_peaks_windows_right, result_cut.lowcut,; bin_width_window=3.0u"keV", low_e_tail=false, sigma_high_sided=result_cut.highcut)
        catch e
            @error "PSD peaks SF for $det cannot be generated"
            throw(ErrorException("PSD peaks SF for $det from partition $(part) cannot be generated"))
        end

        qbb_result = nothing
        try
            qbb_result = get_continuum_surrival_fraction(aoe, e, psd_config_ch.qbb, psd_config_ch.qbb_window, result_cut.lowcut,; sigma_high_sided=result_cut.highcut)
        catch e
            @error "Qbb SF for $det cannot be generated"
            throw(ErrorException("Qbb SF for $det from partition $(part) cannot be generated"))
        end

        @debug "Found SEP Surrival Fraction at $(round(u"percent", result_peaks[:Tl208SEP].sf, digits=2))"
        @debug "Found FEP Surrival Fraction at $(round(u"percent", result_peaks[:Tl208FEP].sf, digits=2))"

        p = stephist(e, nbins=2039-35:0.5:2039+35, label="Before", xlabel="Energy", ylabel="Counts / 0.5 keV", yscale=:log10)
        stephist!(e[aoe .> result_cut.lowcut], nbins=2039-35:0.5:2039+35, label="After", xlabel="Energy", ylabel="Counts / 0.5 keV", yscale=:log10)
        plot!(margin=1mm, thickness_scaling=1.5, dpi=600, size=(1000, 700))
        title!("Qbb CC ($(qbb_result.window)) - SF: $(qbb_result.sf)", titlefontisze=8)
        plot!(plot_title=get_plottitle(filekey.setup, part, filekey.category, det, "A/E Performance"))
        savelfig(savefig, p, l200, part, filekey.setup, filekey.category, ch, Symbol("aoe_qbb_sf_$e_type"))


        peak_sf_plot = plot.([rep.after for rep in values(report_peaks)], titleloc=:left, titlefont=font(8), ticks=:native, legend=:bottomright; show_label=true, show_fit=false)
        for (p, rep_before) in zip(peak_sf_plot, [rep.before for rep in values(report_peaks)])
            plot!(p, rep_before,; show_label=true, show_fit=false)
            p.series_list[1][:label] = "After"
            p.series_list[2][:label] = "Before"
        end
        for (p, peak_name, res) in zip(peak_sf_plot, keys(result_peaks), values(result_peaks))
            xticks!(p, convert(Int, round(xlims(p)[1], digits=0)):10:convert(Int, round(xlims(p)[2], digits=0)))
            title!(p, "$peak_name ($(psd_peak_dict[peak_name])) - SF: $(res.sf)")
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
            fontfamily=:sansserif
        )
        plot!(margin=1mm, thickness_scaling=1.2, dpi=600, size=(1200, 900))
        plot!(plot_title=get_plottitle(filekey.setup, part, filekey.category, det, "A/E Performance"))
        savelfig(savefig, p, l200, part, filekey.setup, filekey.category, ch, Symbol("aoe_peaks_sf_$e_type"))

        p = stephist(e, nbins=0:0.5:3000, yscale=:log10, xlabel="Energy", label="Before PSD", ylabel="Counts / 0.2 keV")
        stephist!(e[result_cut.lowcut .< aoe .< result_cut.highcut], nbins=0:0.5:3000, yscale=:log10, label="After PSD")
        xticks!(0:250:3000)
        title!(get_plottitle(filekey.setup, part, filekey.category, det, "A/E Performance"))
        plot!(margin=1mm, thickness_scaling=1.2, dpi=600, size=(1000, 600), fontfamily=:sansserif)
        savelfig(savefig, p, l200, part, filekey.setup, filekey.category, ch, Symbol("aoe_energy_afterPSD_$e_type"))


        p = stephist(e, nbins=0:0.5:3000, yscale=:log10, xlabel="Energy", label="Before PSD", ylabel="Counts / 0.5 keV")
        stephist!(e[result_cut.lowcut .< aoe .< result_cut.highcut], nbins=0:0.5:3000, yscale=:log10, label="After PSD")
        stephist!(e, nbins=1550:0.5:1700, inset = (1, bbox(0.2, 0.72, 0.4, 0.2, :top)), subplot = 2)
        stephist!(e[result_cut.lowcut .< aoe .< result_cut.highcut], nbins=1550:0.5:1700, subplot = 2, legend=:none, ylabel="Counts / 0.5 keV", xlabel="")
        xticks!(0:250:3000, subplot = 1)
        xticks!(1500:20:1700, subplot = 2)
        title!(get_plottitle(filekey.setup, part, filekey.category, det, "A/E Performance"), subplot=1)
        plot!(margin=1mm, thickness_scaling=1.2, dpi=600, size=(1000, 600), fontfamily=:sansserif)
        plot!(ylabelfontsize=8, subplot=2)
        savelfig(savefig, p, l200, part, filekey.setup, filekey.category, ch, Symbol("aoe_energy_afterPSD_zoom_$e_type"))

        p = histogram2d(e, aoe, nbins=(0:0.5:3000, -25:0.02:10), xlims=(0, 3000), ylims=(-25, 10), size=(1000, 600), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy", ylabel="A/E (σ)")
        plot!(margin=1mm, thickness_scaling=1.6, dpi=600, size=(1300, 700), xticks=(0:250:3000), yticks=(-26:2:10), fontfamily=:sansserif)
        hline!([result_cut.lowcut, result_cut.highcut], color=:red, label="Cut", lw=2.5)
        hspan!([-50, result_cut.lowcut, result_cut.highcut, 50], color=:red, alpha=0.2, label="", lw=0)
        title!(p, get_plottitle(filekey.setup, part, filekey.category, det, "A/E Classifier"))
        savelfig(savefig, p, l200, part, filekey.setup, filekey.category, ch, Symbol("aoe_withcuts_$e_type"))

        # save results
        result = (
            cut = result_cut,
            peaks = result_peaks,
            qbb = qbb_result,
            e_type = e_type,
            sigma_high_sided = sigma_high_sided,
        )

        log_info = log_nt((ch, det, ProcessStatus(1), result_cut.lowcut, result.peaks[:Tl208SEP].sf, result.peaks[:Tl208FEP].sf, "-"))
        return (result = result, log = log_info, processed = true)
    end

    # get start time
    start_time = now()

    result_psd = parallel(chinfo, ch_psd_cut, log_nt, wpool; timeout=timeout)

    @info "Finished PSD cut generation"

    pars_db = create_pars(pars_db, result_psd)
    writelprops(l200.par.ppars.aoe, part, pars_db)
    writevalidity(l200.par.ppars.aoe, filekey, part)
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, psd_part_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey, part))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_psd))

    @info "Write log report"
    writelreport(get_logfilename(l200, filekey.setup, part, filekey.category, :psd), report)
    @info report
end

