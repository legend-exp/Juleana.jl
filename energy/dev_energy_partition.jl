using LegendDataManagement, PropertyFunctions, TypedTables, PropDicts
using Unitful, Formatting, LaTeXStrings, Measures
using Plots, StatsBase
using LegendHDF5IO, LegendDSP, LegendSpecFits
using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked

ENV["JULIA_DEBUG"] = Main # enable debug

gr(size=(1500, 800))
# plotlyjs(size=(800, 500))
# plotlyjs(size=(600, 500))
@info "Loading Legend MetaData"
l200 = LegendData(:l200)

partition_n = 1

# function process_psd_partition(l200::LegendData, partition_n::Int,; reprocess::Bool=false, timeout::Int=300)
    @info "Energy calibration for partition $partition_n"

    partition = data_partitions(l200)[partition_n]
    period = filter(row -> row.period == minimum(partition.period), partition).period[1]
    partition_period = partition[[p == period for p in partition.period]]
    run = filter(row -> row.run == minimum(partition_period.run), partition_period).run[1]

    filekey = first(sort(search_disk(FileKey, l200.tier[:dsp, :cal, period, run]), by = x-> x.time))
    @info "Found filekey $filekey"

    chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable && $usability != :off)

    sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)

    hit_folder = l200.tier[:hit_ch, :cal, period, run]

    @debug "Create figures folder"
    figures_folder = joinpath(l200.tier[:plt, :cal], format("partition{:02d}/psd", partition_n))
    if isdir(figures_folder)
        @debug("Figure folder $figures_folder already exists")
    else
        mkpath(figures_folder)
    end

    for str in unique(chinfo.string)
        figures_folder_string = joinpath(figures_folder, format("string{:02d}", str))
        if isdir(figures_folder_string)
            @debug("String Figure folder $figures_folder_string already exists")
        else
            mkpath(figures_folder_string)
        end
    end

    @debug "Create logs folder"
    log_folder = joinpath(l200.tier[:log, :cal], format("partition{:02d}/psd", partition_n))
    if isdir(log_folder)
        @debug("Log folder $figures_folder already exists")
    else
        mkpath(log_folder)
    end

    @debug "Create pars db"
    pars_db = PropDict()
    # read params if exist
    if !(isfile(joinpath(l200.tier[:par, :cal], format("p_energy/partition{:02d}.json", partition_n))))
        # path folder for current period seems not to exist, will create it first to avoid errors
        mkpath(joinpath(l200.tier[:par, :cal], format("p_energy")))
    else
        @info "Pars file already exists."
        pars_db = l200.par[:cal, :p_energy](filekey)
    end

    if reprocess
        @info "Reprocess all channels"
        for det in keys(pars_db)
            pars_db[det].aoecut = nothing
        end
        PropDicts.trim_null!(pars_db)
    else
        @info "Only reprocess channels that are not in pars_db"
    end

    # move all variables to workers
    @everywhere begin
        l200 = $l200
        sel = $sel
        filekey = $filekey
        partition_n = $partition_n
        partition = $partition
        chinfo = $chinfo
        figures_folder = $figures_folder
        hit_folder = $hit_folder
        pars_db = $pars_db
        reprocess = $reprocess
    end
    
    # @everywhere function ch_psd_cut(i::Int64)
        i = 1
        ch_short = chinfo.channel[i]
        ch = format("ch{}", ch_short)
        string_number = chinfo.string[i]
        det = chinfo.detector[i]

        figures_folder_string = joinpath(figures_folder, format("string{:02d}", string_number))


        @debug "Processing channel $ch ($det)"

        result_dict    = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, String}()

        if haskey(l200.metadata.dataprod.config.energy(sel), det) && haskey(l200.metadata.dataprod.config.energy(sel)[det], :p)
            energy_config = merge(l200.metadata.dataprod.config.energy(sel).p_default, l200.metadata.dataprod.config.energy(sel)[det].p)
            @debug "Use config for detector $det"
        else
            energy_config = l200.metadata.dataprod.config.energy(sel).p_default
            @debug "Use default config"
        end

        energy_types = Symbol.(energy_config.energy_types)

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(chinfo.detector[i]) already processed, check missing energy types"
            for e_type in energy_types
                if haskey(pars_db[det], e_type) && haskey(pars_db[det][e_type], :energy)
                    log_info = "| $ch | $det | Success | $e_type | $(round(pars_db[det][e_type].energy.fwhm_qbb, digits=2))±$(round(pars_db[det][e_type].energy.fwhm_qbb_err, digits=2)) | $(round(pars_db[det][e_type].energy[:Tl208FEP].fwhm, digits=2))±$(round(pars_db[det][e_type].energy[:Tl208FEP].err.fwhm, digits=2)) | $(round(pars_db[det][e_type].energy.m_calib, digits=2)) | Already processed --> skipped. |"
                    result_dict[e_type] = NamedTuple()
                    log_info_dict[e_type] = log_info
                end
                if haskey(pars_db[det], Symbol("$(e_type)_ctc")) && haskey(pars_db[det][Symbol("$(e_type)_ctc")], :energy)
                    log_info = "| $ch | $det | Success | $(e_type)_ctc | $(round(pars_db[det][Symbol("$(e_type)_ctc")].energy.fwhm_qbb, digits=2))±$(round(pars_db[det][Symbol("$(e_type)_ctc")].energy.fwhm_qbb_err, digits=2)) | $(round(pars_db[det][Symbol("$(e_type)_ctc")].energy[:Tl208FEP].fwhm, digits=2))±$(round(pars_db[det][Symbol("$(e_type)_ctc")].energy[:Tl208FEP].err.fwhm, digits=2)) | $(round(pars_db[det][Symbol("$(e_type)_ctc")].energy.m_calib, digits=2)) | Already processed --> skipped. |"
                    result_dict[Symbol("$(e_type)_ctc")] = NamedTuple()
                    log_info_dict[Symbol("$(e_type)_ctc")] = log_info
                end
            end
        end

        th228_lines = Vector{Float64}(energy_config.th228_lines)
        th228_names = Symbol.(energy_config.th228_names)
        th228_names_dict  = Dict{Symbol, Float64}(Symbol.(energy_config.th228_names) .=> th228_lines)
        window_sizes = Vector{Tuple{Float64, Float64}}([(l,r) for (l,r) in zip(Vector{Float64}(energy_config.left_window_sizes), Vector{Float64}(energy_config.right_window_sizes))])
        n_bins = energy_config.n_bins
        quantile_perc = nothing
        if !(energy_config.quantile_perc isa Number)
            quantile_perc = parse(Float64, energy_config.quantile_perc)
        else
            quantile_perc = energy_config.quantile_perc
        end


        for e_type_name in energy_types
        # e_type_name = :e_trap
            for e_type in [e_type_name, Symbol("$(e_type_name)_ctc")]
                if haskey(result_dict, e_type)
                    continue
                end
                # e_type = :e_trap_ctc
                try
                    @debug "Calibrate $e_type"

                    energy = nothing
                    try
                        energy = fast_flatten([ LHDataStore(
                            ds -> begin
                                @debug "Reading from \"$(ds.data_store.filename)\""
                                e_uncal = ds["$(ch)/dataQC/$(e_type_name)"][:]
                                if endswith(string(e_type), "_ctc")
                                    fct = l200.par[:cal, :energy, period, run][det][e_type_name].ctc.fct
                                    e_uncal = e_uncal .+ fct .* ds["$(ch)/dataQC/qdrift"][:]
                                end
                                calibrate_energy!(e_uncal, l200.par[:cal, :energy, period, run][det][e_type].energy)
                            end,
                            joinpath(l200.tier[:hit_ch, :cal, period, run], format("{}-{}-{}-{}-{}-tier_hit.lh5", string(filekey.setup), string(period), string(run), string(filekey.category), ch))
                        ) for (period, run) in partition ])
                    catch e
                        @error "E data for $det from cannot be loaded"
                        throw(LoadError("E data", 154, "E data for $det from partition $(partition_n) cannot be loaded"))
                    end
                    GC.gc()

                    result_simple, report_simple = nothing, nothing
                    try
                        @debug "Get $e_type simple calibration"
                        result_simple, report_simple = simple_calibration(energy, th228_lines, window_sizes,; n_bins=n_bins, quantile_perc=quantile_perc)
                    catch e
                        @error "Error in $e_type simple calibration for channel $ch: $e"
                        throw(ErrorException("Error in $e_type simple calibration"))
                    end
                    GC.gc()

                    # get simple calibration constant
                    m_cal_simple = result_simple.c
                    # save plots for simple calibration for control
                    plot(report_simple, margin=5mm, yformatter=:plain, thickness_scaling=1.5, cal=true, title=format("{} Simple Calibration ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
                    savefig(joinpath(figures_folder_string, format("{}-partition{:02d}-{}-{}-simple_calibration_{}.png", string(filekey.setup), partition_n, string(filekey.category), ch, string(e_type))))

                    yield()

                    result_fit, report_fit = nothing, nothing
                    try
                        @debug "Fit all $e_type peaks"
                        result_fit, report_fit = fit_peaks(result_simple.peakhists, result_simple.peakstats, th228_names)
                    catch e
                        @error "Error in $e_type peak fitting for channel $ch: $e"
                        throw(ErrorException("Error in $e_type peak fitting"))
                    end
                    GC.gc()

                    peak_fit_plot = plot.(values(report_fit), titleloc=:center, titlefont=font(family="monospace",halign=:center, pointsize=20), ticks=:native, right_margin=10mm, top_margin=5mm, legend=false; show_label=true)
                    for (peak_name, p) in zip(keys(report_fit), peak_fit_plot)
                        xticks!(p, convert(Int, round(xlims(p)[1], digits=0)):8:convert(Int, round(xlims(p)[2], digits=0)))
                        title!(p, "$peak_name ($(th228_names_dict[peak_name])keV)")
                        if i != 1
                            plot!(showlegend=false)
                        end
                    end
                    plot(
                        peak_fit_plot...,
                        framestyle=:box,
                        legend=:outerright,
                        # layout=(3, 3),
                        thickness_scaling=1.5,
                        grid=true, gridalpha=0.2, gridcolor=:black, gridlinewidth=0.5,
                        xguidefont=font(family="monospace",halign=:center, pointsize=18),
                        yguidefont=font(family="monospace",halign=:center, pointsize=18),
                        xtickfontsize=10,
                        ytickfontsize=10,
                        size=(3000, 1500),
                        margins=10mm
                    )
                    savefig(joinpath(figures_folder_string, format("{}-partition{:02d}-{}-{}-peak_fits_{}.png", string(filekey.setup), partition_n, string(filekey.category), ch, string(e_type))))

                    yield()

                    @debug "Get $e_type calibration values"
                    μ = [result_fit[p].μ for p in th228_names]
                    μ_err = [result_fit[p].err.μ for p in th228_names]

                    m_calib, n_calib = nothing, nothing
                    try
                        m_calib, n_calib = fit_calibration(μ, th228_lines)
                        @debug format("Found $e_type calibration curve: E[keV] = {:.2f} + {:.2f}*E[ADC]", n_calib, m_calib)
                    catch e
                        @error "Error in $e_type calibration curve fitting for channel $ch: $e"
                        throw(ErrorException("Error in $e_type calibration curve fitting"))
                    end

                    scatter(μ, th228_lines, yerror=μ_err, ms=5, color=:black, framestyle=:box, markershape= :x, layout = @layout[grid(2, 1, heights=[0.8, 0.2])], link=:x, label="Peak Positions", xlabel="Fit Energy (keV)", xlabelfontsize=10, ylabel="True Energy (keV)", ylabelfontsize=10, legend=:topleft, legendfontsize=8, legendfont=font(8), legendtitlefontsize=8, legendtitlefont=font(8), xlims = (0, 3000), xticks = (200:200:3000), margin=5mm, thickness_scaling=1.5, xformatter=:plain)
                    plot!(ylims = (0, 3000), yticks = (200:200:3000), subplot=1, xlabel="", xticks = :none, bottom_margin=-4mm)
                    plot!(0:1:20000, x -> m_calib* x + n_calib, label="Best Fit: $(round(n_calib, digits=2)) + x*$(round(m_calib, digits=2)))", line_width=2, color=:red, subplot=1, xformatter=_->"")
                    plot!(μ, ((m_calib .* μ .+ n_calib) .- th228_lines) ./ th228_lines .* 100 , label="Residuals", ylabel="Residuals (%)", line_width=2, color=:black, st=:scatter, ylims = (-0.11, 0.1), markershape=:x, subplot=2, legend=:topleft, top_margin=0mm, framestyle=:box)
                    plot!(legend = :topleft, title=format("{} Calibration Curve ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)), subplot=1)
                    savefig(joinpath(figures_folder_string, format("{}-partition{:02d}-{}-{}-calibration_curve_{}.png", string(filekey.setup), partition_n, string(filekey.category), ch, string(e_type))))

                    yield()

                    fwhm     = ([result_fit[p].fwhm for p in th228_names])
                    fwhm_err = ([result_fit[p].err.fwhm for p in th228_names])

                    result_fwhm, report_fwhm = nothing, nothing
                    try
                        result_fwhm, report_fwhm = fit_fwhm(th228_lines, fwhm)
                        @debug "Found $e_type FWHM: $(round(result_fwhm.qbb, digits=2)) +- $(round(result_fwhm.err.qbb, digits=2))keV"
                    catch e
                        @error "Error in $e_type FWHM fitting for channel $ch: $e"
                        throw(ErrorException("Error in $e_type FWHM fitting"))
                    end

                    scatter(th228_lines, fwhm, yerror=fwhm_err, ms=5, color=:black, framestyle=:box, markershape= :x, layout = @layout[grid(2, 1, heights=[0.8, 0.2])], link=:x, label="Peak FWHMs", xlabel="Energy (keV)", xlabelfontsize=10, ylabel="FWHM (keV)", ylabelfontsize=10, legend=:topleft, legendfontsize=8, legendfont=font(8), legendtitlefontsize=8, legendtitlefont=font(8), xlims = (0, 3000), xticks = (convert(Int, 0):300:convert(Int, round(3000, digits=0))), margin=5mm, thickness_scaling=1.5)
                    plot!(0:0.1:3000, x -> report_fwhm.f_fit(x), label="Best Fit: Sqrt($(round(report_fwhm.v[1], digits=2)) + x*$(round(report_fwhm.v[2]*100, digits=2))e-3)", line_width=2, color=:red, subplot=1, xlabel="", xticks=:none, bottom_margin=-4mm, ylims=(0.8, 6.0))
                    hline!([result_fwhm.qbb], label="Qbb/keV: $(round(result_fwhm.qbb, digits=2))+-$(round(result_fwhm.err.qbb, digits=2))", color=:green)
                    hspan!([result_fwhm.qbb - result_fwhm.err.qbb, result_fwhm.qbb + result_fwhm.err.qbb], color=:green, alpha=0.2, label="")
                    plot!(th228_lines, ((report_fwhm.f_fit.(th228_lines) .- fwhm) ./ fwhm) .* 100 , label="Residuals", ylabel="Residuals (%)", line_width=2, color=:black, st=:scatter, ylims = (-10, 12), markershape=:x, legend=:topleft, subplot=2, framestyle=:box, top_margin=0mm)
                    plot!(legend = :topleft, title=format("{} FWHM ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)), subplot=1)
                    savefig(joinpath(figures_folder_string, format("{}-partition{:02d}-{}-{}-fwhm_{}.png", string(filekey.setup), partition_n, string(filekey.category), ch, string(e_type))))
                    
                    yield()

                    log_info = "| $ch | $det | Success | $e_type | $(round(result_fwhm.qbb, digits=2))±$(round(result_fwhm.err.qbb, digits=2)) | $(round(result_fit[:Tl208FEP].fwhm, digits=2))±$(round(result_fit[:Tl208FEP].err.fwhm, digits=2)) | $(round(m_calib, digits=2)) | - |"

                    result_energy = (
                        m_calib = m_calib,
                        n_calib = n_calib,
                        m_cal_simple = m_cal_simple,
                        fwhm = result_fwhm,
                        fit  = result_fit,
                    )

                    # add results to dict
                    result_dict[e_type]   = result_energy
                    log_info_dict[e_type] = log_info

                    GC.gc()
                catch e
                    @error "Error in $e_type CT correction: $e"
                    log_info = "| ch$(chinfo.channel[i]) | $(chinfo.detector[i]) | Failed | $e_type | - | - | - | $(e) |"
                    # add results to dict
                    result_dict[e_type] = NamedTuple()
                    log_info_dict[e_type] = log_info
                end
            end
        end


        return (result = result_dict, log = log_info_dict)



        # histogram2d(e, aoe, nbins=(0:0.5:3000, -15:0.02:10), xlims=(0, 3000), ylims=(-15, 10), size=(1000, 600), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy (keV)", ylabel="A/E ( σ)")
        # plot!(margin=1mm, thickness_scaling=1.6, dpi=600, size=(1000, 600), xticks=(0:250:3000), yticks=(-16:2:10), fontfamily=:sansserif)
        # plot!(title=format("{} A/E Classifier ({}-Partition{:02d}-{})", string(det), string(filekey.setup), partition_n, string(filekey.category)))

        result_cut = nothing
        try
            @debug "Generate PSD cut"
            result_cut = get_psd_cut(aoe, e,; cut_search_interval=(-25.0, 0.0), window=[20.0, 20.0], rtol=1e-5, bin_width_window=5.0, fixed_position=false)            
        catch e
            @error "PSD cut for $det cannot be generated"
            throw(ErrorException("PSD cut for $det from partition $(partition_n) cannot be generated"))
        end

        result_peaks, report_peaks = nothing, nothing
        try
            @debug "Generate PSD Surrival Fractions"
            result_peaks, report_peaks = get_peaks_surrival_fractions(aoe, e, psd_peaks, psd_peak_names, psd_peaks_window_sizes, result_cut.cut,; bin_width_window=3.0, low_e_tail=false, sigma_high_sided=sigma_high_sided)
        catch e
            @error "PSD peaks SF for $det cannot be generated"
            throw(ErrorException("PSD peaks SF for $det from partition $(partition_n) cannot be generated"))
        end

        qbb_result = nothing
        try
            qbb_result = get_continuum_surrival_fraction(aoe, e, qbb, qbb_window, result_cut.cut,; sigma_high_sided=sigma_high_sided)
        catch e
            @error "Qbb SF for $det cannot be generated"
            throw(ErrorException("Qbb SF for $det from partition $(partition_n) cannot be generated"))
        end

        stephist(e, nbins=2039-35:0.5:2039+35, label="Before", xlabel="Energy (keV)", ylabel="Counts / 0.5 keV", yscale=:log10)
        stephist!(e[aoe .> result_cut.cut], nbins=2039-35:0.5:2039+35, label="After", xlabel="Energy (keV)", ylabel="Counts / 0.5 keV", yscale=:log10)
        plot!(margin=1mm, thickness_scaling=1.5, dpi=600, size=(1000, 700))
        title!(format("Qbb CC ({} ± {}keV) - SF: {:.2f} ± {:.2f}%", qbb, qbb_window, qbb_result.sf*100, qbb_result.err.sf*100), titlefontisze=8)
        plot!(plot_title=format("{} ({}-Partition{:02d}-{})", string(det), string(filekey.setup), partition_n, string(filekey.category)), subplot=1)
        savefig(joinpath(figures_folder, format("{}-partition{:02d}-{}-{}_QbbSF_afterPSD_{}.png", string(filekey.setup), partition_n, string(filekey.category), ch, string(e_type))))
        

        peak_sf_plot = plot.([rep.after for rep in values(report_peaks)], titleloc=:left, titlefont=font(8), ticks=:native, legend=:bottomright; show_label=true, show_fit=false)
        for (p, rep_before) in zip(peak_sf_plot, [rep.before for rep in values(report_peaks)])
            plot!(p, rep_before,; show_label=true, show_fit=false)
            p.series_list[1][:label] = "After"
            p.series_list[2][:label] = "Before"
        end
        for (p, peak_name, res) in zip(peak_sf_plot, keys(result_peaks), values(result_peaks))
            xticks!(p, convert(Int, round(xlims(p)[1], digits=0)):10:convert(Int, round(xlims(p)[2], digits=0)))
            title!(p, format("{} ({} keV) - SF: {:.2f} ± {:.2f}%", string(peak_name), psd_peak_dict[peak_name], res.sf*100, res.err.sf*100))
        end
        plot(
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
        plot!(plot_title=format("{} Peak SF ({}-Partition{:02d}-{})", string(det), string(filekey.setup), partition_n, string(filekey.category)), subplot=1)
        savefig(joinpath(figures_folder, format("{}-partition{:02d}-{}-{}_peaksSF_afterPSD_{}.png", string(filekey.setup), partition_n, string(filekey.category), ch, string(e_type))))

        stephist(e, nbins=0:0.5:3000, yscale=:log10, xlabel="Energy (keV)", label="Trap Energy", ylabel="Counts / 0.2 keV")
        stephist!(e[result_cut.cut .< aoe .< sigma_high_sided], nbins=0:0.5:3000, yscale=:log10, xlabel="Energy (keV)", label="Trap Energy after PSD", ylabel="Counts / 0.2 keV")
        plot!(title=format("{} Energy ({}-Partition{:02d}-{})", string(det), string(filekey.setup), partition_n, string(filekey.category)), subplot=1)
        plot!(margin=1mm, thickness_scaling=1.2, dpi=600, size=(1000, 600), fontfamily=:sansserif)
        savefig(joinpath(figures_folder, format("{}-partition{:02d}-{}-{}_energy_afterPSD_{}.png", string(filekey.setup), partition_n, string(filekey.category), ch, string(e_type))))


        stephist(e, nbins=0:0.5:3000, yscale=:log10, xlabel="Energy (keV)", label="Trap Energy", ylabel="Counts / 0.5 keV")
        stephist!(e[result_cut.cut .< aoe .< sigma_high_sided], nbins=0:0.5:3000, yscale=:log10, label="Trap Energy after PSD")
        stephist!(e, nbins=1550:0.5:1700, inset = (1, bbox(0.2, 0.72, 0.4, 0.2, :top)), subplot = 2,)
        stephist!(e[result_cut.cut .< aoe .< sigma_high_sided], nbins=1550:0.5:1700, subplot = 2, legend=:none, ylabel="Counts / 0.5 keV")
        xticks!(0:250:3000, subplot = 1)
        xticks!(1500:20:1700, subplot = 2)
        plot!(title=format("{} Energy ({}-Partition{:02d}-{})", string(det), string(filekey.setup), partition_n, string(filekey.category)), subplot=1)
        plot!(margin=1mm, thickness_scaling=1.2, dpi=600, size=(1000, 600), fontfamily=:sansserif)
        savefig(joinpath(figures_folder, format("{}-partition{:02d}-{}-{}_energy_afterPSD_withZoom_{}.png", string(filekey.setup), partition_n, string(filekey.category), ch, string(e_type))))

        histogram2d(e, aoe, nbins=(0:0.5:3000, -15:0.02:10), xlims=(0, 3000), ylims=(-7, 7), size=(1000, 600), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy (keV)", ylabel="A/E ( σ)")
        plot!(margin=1mm, thickness_scaling=1.6, dpi=600, size=(1000, 600), xticks=(0:250:3000), yticks=(-16:1:10), fontfamily=:sansserif)
        plot!(title=format("{} A/E Classifier ({}-Partition{:02d}-{})", string(det), string(filekey.setup), partition_n, string(filekey.category)))
        hline!([result_cut.cut, 5.0], color=:red, label="Cut", lw=2.5)
        savefig(joinpath(figures_folder, format("{}-partition{:02d}-{}-{}_aoe_withCuts_{}.png", string(filekey.setup), partition_n, string(filekey.category), ch, string(e_type))))

        # save results
        result = (
            cut = result_cut,
            peaks = result_peaks,
            qbb = qbb_result,
            e_type = e_type,
            sigma_high_sided = sigma_high_sided,
        )

        log_info = "| $ch | $det | Success | $(round(result_cut.cut, digits=2))±$(round(result_cut.err.cut, digits=2)) | $(round(result_peaks[:Tl208SEP].sf*100, digits=2))±$(round(result_peaks[:Tl208SEP].err.sf*100, digits=2))% | $(round(result_peaks[:Tl208FEP].sf*100, digits=2))±$(round(result_peaks[:Tl208FEP].err.sf*100, digits=2))% | - |"
        return (result = result, log = log_info)

    end


    Base.exit_on_sigint(false)
    result_psd =  @showprogress pmap(eachindex(chinfo.channel); batch_size = 1, retry_check=retry_check, retry_delays=ExponentialBackOff(n=3)) do idx
        try
            t_end = time() + timeout
            task = Threads.@spawn ch_psd_cut(idx)
            while !istaskdone(task) && time() <= t_end
                sleep(0.1)
            end
            if !istaskdone(task)
                @debug "Timeout for $(chinfo.detector[idx])"
                try
                    Base.throwto(task, InterruptException())
                catch e
                    throw(ErrorException("Timeout for $(chinfo.detector[idx])"))
                end
                throw(ErrorException("Timeout for $(chinfo.detector[idx])"))
            end
            chinfo.detector[idx] => fetch(task)
        catch e
            if e isa TaskFailedException
                e = e.task.exception
            end
            @debug "Write Error log for $(chinfo.detector[idx]): $e"
            log_info = "| ch$(chinfo.channel[idx]) | $(chinfo.detector[idx]) | Failed | - | - | - | $(e) |"
            chinfo.detector[idx] => (result = NamedTuple(), log = log_info)
        end
    end

    @info "Finished PSD calibration"
    @info "Remove all workers"
    rmprocs(workers()...)

    main_log = """
    # Main log 
    Time of processing: $(now())
    ## PSD CUT
    This is the log for the PSD CUT generation for the AoE PSD analysis. The processing involves 
    generating a cut that let's 90% of the events in the Tl-208 DEP pass. The cut is generated by
    sweeping through different values of the cut and finding the root with 90% of the original peak counts.

    # MetaData
    | Setup | Partition | Category |
    |-------|-----------|----------|
    | $(filekey.setup) | $(partition_n) | $(filekey.category) |

    # Results
    | Channel | Detector | Status | Cut value | SEP SF | FEP SF | Error |
    |---------|----------|--------|-----------|--------|--------|-------|
    """
    # extract results into pars_db and append to main log
    for (det, res) in result_psd
        # save pars to db
        if !isempty(res.result)
            pars_det                    = pars_db[det].aoecut
            pars_det.lo                 = res.result.cut.cut
            pars_det.err.lo             = res.result.cut.err.cut
            pars_det.hi                 = res.result.sigma_high_sided
            pars_det.err.hig            = 0.0
            pars_det.e_type             = string(res.result.e_type)
            pars_det.n0                 = res.result.cut.n0
            pars_det.err.n0             = res.result.cut.err.n0
            pars_det.nsf                = res.result.cut.nsf
            pars_det.err.nsf            = res.result.cut.err.nsf
            # save surrival fractions
            pars_det                    = pars_db[det].aoesf
            for (peak_name, peak_res) in res.result.peaks
                pars_det[peak_name]     = peak_res
            end
            pars_det.qbb                = res.result.qbb
        end
        # add log to main log
        main_log = """
        $main_log$(res.log)
        """
        # main_log *= res.log
    end

    # save pars to disk
    @info "Save pars to disk"
    # write pars
    writeprops(joinpath(l200.tier[:par, :cal], "p_psd", format("partition{:02d}.json", partition_n)), pars_db, multiline=true)

    # write validity
    pars_validTimeStamp = string(filekey.time)
    add_validity = true
    for ln in eachline(open(joinpath(l200.tier[:par, :cal], "p_psd", "validity.jsonl"), "r"))
        if (contains(ln, "$pars_validTimeStamp"))
            add_validity = false
        end
    end
    if add_validity
        open(joinpath(l200.tier[:par, :cal], "p_psd", "validity.jsonl"), "a") do io
            pars_filename = format("partition{:02d}.json", partition_n)
            println(io, "{\"valid_from\":\"$pars_validTimeStamp\", \"category\":\"all\", \"apply\":[\"$pars_filename\"]}")
        end
    end

    @info "Write main log to disk"
    @info main_log

    log_filename = joinpath(log_folder, format("{}-partition{:02d}-{}-psd_cut.md", string(filekey.setup), partition_n, string(filekey.category)))
    open(log_filename, "w+") do file
        write(file, replace(main_log, "Success" => raw"$${\color{green}Success}$$", "Failed" => raw"$${\color{red}Failed}$$"))
    end

# end

