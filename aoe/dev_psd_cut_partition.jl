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

@info "PSD calibration for partition $partition_n"

partition = data_partitions(l200)[1]
period = filter(row -> row.period == minimum(partition.period), partition).period[1]
partition_period = partition[[p == period for p in partition.period]]
run = filter(row -> row.run == minimum(partition_period.run), partition_period).run[1]

filekey = first(sort(search_disk(FileKey, l200.tier[:dsp, :cal, period, run]), by = x-> x.time))
@info "Found filekey $filekey"

chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable && $usability == :on)

sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)

hit_folder = l200.tier[:hit_ch, :cal, period, run]

@debug "Create figures folder"
figures_folder = joinpath(l200.tier[:plt, :cal], format("partition{:02d}/psd", partition_n))
if isdir(figures_folder)
    @debug("Figure folder $figures_folder already exists")
else
    mkpath(figures_folder)
end


i = 29
i = findfirst(chinfo.detector .== :B00035C)
# for i in eachindex(chinfo.channel)
    ch_short = chinfo.channel[i]
    ch = format("ch{}", ch_short)
    string_number = chinfo.string[i]
    det = chinfo.detector[i]

    # load config
    if haskey(l200.metadata.dataprod.config.psd(sel), det)
        psd_config = merge(l200.metadata.dataprod.config.psd(sel).default, l200.metadata.dataprod.config.psd(sel)[det])
        @debug "Use config for detector $det"
    else
        psd_config = l200.metadata.dataprod.config.psd(sel).default
        @debug "Use default config"
    end
    psd_peaks = Float64.(psd_config.psd_peaks)
    psd_peaks_window_sizes = Vector{Tuple{Float64, Float64}}([(l,r) for (l,r) in zip(Vector{Float64}(psd_config.psd_peaks_windows_left), Vector{Float64}(psd_config.psd_peaks_windows_right))])
    psd_peak_names = Symbol.(psd_config.psd_peaks_names)
    psd_peak_dict = Dict(zip(psd_peak_names, psd_peaks))
    qbb =  psd_config.qbb
    qbb_window = psd_config.qbb_window
    sigma_high_sided = 5.0
    e_type = Symbol(psd_config.energy_type)

    aoe = fast_flatten([LHDataStore(
        ds -> begin
            @debug "Reading from \"$(ds.data_store.filename)\""
            a = ds["$(ch)/dataQC/a"][:]
            e = calibrate_energy!(ds["$(ch)/dataQC/$(e_type)"][:], l200.par[:cal, :energy, period, run][det][e_type].energy)
            correct_aoe!(a ./ e, e, l200.par[:cal, :psd, period, run][det].calibration)
        end,
        joinpath(l200.tier[:hit_ch, :cal, period, run], format("{}-{}-{}-{}-{}-tier_hit.lh5", string(filekey.setup), string(period), string(run), string(filekey.category), ch))
    ) for (period, run) in partition ])

    e = fast_flatten([ LHDataStore(
        ds -> begin
            @debug "Reading from \"$(ds.data_store.filename)\""
            calibrate_energy!(ds["$(ch)/dataQC/$(e_type)"][:], l200.par[:cal, :energy, period, run][det][e_type].energy)
        end,
        joinpath(l200.tier[:hit_ch, :cal, period, run], format("{}-{}-{}-{}-{}-tier_hit.lh5", string(filekey.setup), string(period), string(run), string(filekey.category), ch))
    ) for (period, run) in partition ])

    # histogram2d(e, aoe, nbins=(0:0.5:3000, -15:0.02:10), xlims=(0, 3000), ylims=(-15, 10), size=(1000, 600), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy (keV)", ylabel="A/E ( σ)")
    # plot!(margin=1mm, thickness_scaling=1.6, dpi=600, size=(1000, 600), xticks=(0:250:3000), yticks=(-16:2:10), fontfamily=:sansserif)
    # plot!(title=format("{} A/E Classifier ({}-Partition{:02d}-{})", string(det), string(filekey.setup), partition_n, string(filekey.category)))


    result_cut = get_psd_cut(aoe, e,; cut_search_interval=(-10.0, 0.0), window=[20.0, 20.0], rtol=1e-5, bin_width_window=5.0, fixed_position=false)




    result_peaks, report_peaks = get_peaks_surrival_fractions(aoe, e, psd_peaks, psd_peak_names, psd_peaks_window_sizes, result_cut.cut,; bin_width_window=3.0, low_e_tail=false, sigma_high_sided=10.0)

    qbb_result = get_continuum_surrival_fraction(aoe, e, qbb, qbb_window, result_cut.cut,; sigma_high_sided=sigma_high_sided)

    stephist(e, nbins=2039-35:0.5:2039+35, label="Before", xlabel="Energy (keV)", ylabel="Counts / 0.5 keV", yscale=:log10)
    stephist!(e[aoe .> result_cut.cut], nbins=2039-35:0.5:2039+35, label="After", xlabel="Energy (keV)", ylabel="Counts / 0.5 keV", yscale=:log10)
    plot!(margin=1mm, thickness_scaling=1.5, dpi=600, size=(1000, 700))
    title!(format("Qbb CC ({} ± {}keV) - SF: {:.2f} ± {:.2f}%", qbb, qbb_window, qbb_result.sf*100, qbb_result.err.sf*100), titlefontisze=8)
    plot!(plot_title=format("{} ({}-Partition{:02d}-{})", string(det), string(filekey.setup), partition_n, string(filekey.category)), subplot=1)


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


    stephist(e, nbins=0:0.5:3000, yscale=:log10, xlabel="Energy (keV)", label="Trap Energy", ylabel="Counts / 0.2 keV")
    stephist!(e[aoe .> result_cut.cut], nbins=0:0.5:3000, yscale=:log10, xlabel="Energy (keV)", label="Trap Energy after PSD", ylabel="Counts / 0.2 keV")
    plot!(title=format("{} Energy ({}-Partition{:02d}-{})", string(det), string(filekey.setup), partition_n, string(filekey.category)), subplot=1)
    plot!(margin=1mm, thickness_scaling=1.2, dpi=600, size=(1000, 600), fontfamily=:sansserif)



    stephist(e, nbins=0:0.5:3000, yscale=:log10, xlabel="Energy (keV)", label="Trap Energy", ylabel="Counts / 0.5 keV")
    stephist!(e[aoe .> result_cut.cut], nbins=0:0.5:3000, yscale=:log10, label="Trap Energy after PSD")
    stephist!(e, nbins=1550:0.5:1700, inset = (1, bbox(0.2, 0.72, 0.4, 0.2, :top)), subplot = 2,)
    stephist!(e[aoe .> result_cut.cut], nbins=1550:0.5:1700, subplot = 2, legend=:none, ylabel="Counts / 0.5 keV")
    xticks!(0:250:3000, subplot = 1)
    xticks!(1500:20:1700, subplot = 2)
    plot!(title=format("{} Energy ({}-Partition{:02d}-{})", string(det), string(filekey.setup), partition_n, string(filekey.category)), subplot=1)
    plot!(margin=1mm, thickness_scaling=1.2, dpi=600, size=(1000, 600), fontfamily=:sansserif)


    histogram2d(e, aoe, nbins=(0:0.5:3000, -15:0.02:10), xlims=(0, 3000), ylims=(-7, 7), size=(1000, 600), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy (keV)", ylabel="A/E ( σ)")
    plot!(margin=1mm, thickness_scaling=1.6, dpi=600, size=(1000, 600), xticks=(0:250:3000), yticks=(-16:1:10), fontfamily=:sansserif)
    plot!(title=format("{} A/E Classifier ({}-Partition{:02d}-{})", string(det), string(filekey.setup), partition_n, string(filekey.category)))
    hline!([result_cut.cut, 5.0], color=:red, label="Cut", lw=2.5)
