include("../utils/packages.jl")
include("../utils/loader.jl")
include("../utils/saver.jl")

config_folder = "/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts/configs/"

stringsToLoad = [1,2,7,8]
period, run, preName, cal = 1, 25, "l60", true
dsp_folder, hit_folder, cut_folder, figure_folder, string_numbers, data_strings, qc_cuts = prepareHit(config_folder, period=period, run=run, preName=preName, cal=cal, stringsToLoad=stringsToLoad)

cuts_figure_folder = joinpath(figure_folder, "cuts")
checkFolder(cuts_figure_folder, true)

# Create cuts TypedTables
qc_cuts = TypedTables.Table(channel=Int[], blmeancut = Bool[], blsigmacut = Bool[], blslopecut = Bool[], 
        timestamp = Float64[]u"s", eventID_fadc = Int[]
        )

# Baseline cuts
for string_number in string_numbers

    printfmtln("Processing string number: {}", string_number)
    println()
    println()
    println("Check figure folder")
    checkFolder(joinpath(cuts_figure_folder, format("string{}", string_number)), true)
    println()
    println()

    dsp_data, channel_list, label_listExt, label_list = data_strings[string_number]

    font_size = 14

    blmean_plots = repeat([plot(1)], length(channel_list))
    blstd_plots = repeat([plot(1)], length(channel_list))
    blslope_plots = [plot(u"ns^-1", Unitful.NoUnits, size=(1000, 800), xlabel="Baseline Slope", ylabel="Counts", framestyle=:box, margin=10mm, xtickfontsize=font_size, ytickfontsize=font_size, xguidefontsize=font_size, yguidefontsize=font_size, legendfontsize=font_size) for i in 1:length(channel_list)]

    for (i, ch) in enumerate(channel_list)
        blmean_ch  = dsp_data[ch].blmean
        blstd_ch   = dsp_data[ch].blsigma
        blslope_ch = dsp_data[ch].blslope
        printfmtln("Channel: {}", ch)
        printfmtln("Number of events: {}", length(blmean_ch))
        printfmtln("Median of baseline mean: {}",  median(blmean_ch))
        printfmtln("Median of baseline std: {}",   median(blstd_ch))
        printfmtln("Median of baseline slope: {}", median(blslope_ch))

        append!(qc_cuts.channel, dsp_data[ch].channel)
        append!(qc_cuts.timestamp, dsp_data[ch].timestamp)
        append!(qc_cuts.eventID_fadc, dsp_data[ch].eventID_fadc)

    
        # Mean
        xlim_factor, mean_cut_factor = 2, 0.2
        blmean_plots[i]  = stephist(blmean_ch, label="Bl Mean", title=format("Channel g{:>03d}", ch), xlim=(median(blmean_ch)-xlim_factor*std(blmean_ch), median(blmean_ch)+xlim_factor*std(blmean_ch)), normalize=:pdf)
        hists = fit(Histogram, blmean_ch, nbins=convert(Int, round(length(blmean_ch)/100)))
        cts_argmax = mapslices(argmax, hists.weights, dims=1)[1]
        cts_max = hists.weights[cts_argmax]

        cut_low_arg  = filter((x) -> hists.weights[x] < mean_cut_factor * cts_max, reverse(1:cts_argmax))[1]
        cut_high_arg = filter((x) -> hists.weights[x] < mean_cut_factor * cts_max, cts_argmax:length(hists.weights))[1]
        cut_low, cut_high = Array(hists.edges[1])[cut_low_arg], Array(hists.edges[1])[cut_high_arg]

        printfmtln("BL Mean Cut window: [{}, {}]", cut_low, cut_high)
        vline!([cut_low, cut_high], color=:red, lw=3, label="")
        vspan!([cut_low, cut_high], fillrange=cut_high, label="Cut window", color=:red, lw=1.5, alpha=0.2)

        append!(qc_cuts.blmeancut, (blmean_ch .> cut_low) .& (blmean_ch .< cut_high))

        # Std
        xlim_factor, std_cut_factor = 1, 0.2
        blstd_plots[i]   = stephist(blstd_ch, label="Bl Std", title=format("Channel g{:>03d}", ch), xlim=(0, median(blstd_ch)+xlim_factor*std(blstd_ch)), normalize=:pdf, nbins=convert(Int, round(length(blstd_ch)/30)))
        hists = fit(Histogram, blstd_ch, nbins=convert(Int, round(length(blstd_ch)/30)))
        cts_argmax = mapslices(argmax, hists.weights, dims=1)[1]
        cts_max = hists.weights[cts_argmax]

        cut_low_arg = filter((x) -> hists.weights[x] < std_cut_factor * cts_max, reverse(1:cts_argmax))[1]
        cut_high_arg = filter((x) -> hists.weights[x] < std_cut_factor * cts_max, cts_argmax:length(hists.weights))[1]
        cut_low, cut_high = Array(hists.edges[1])[cut_low_arg], Array(hists.edges[1])[cut_high_arg]
        printfmtln("BL Std Cut window: [{}, {}]", cut_low, cut_high)
        vline!([cut_low, cut_high], color=:red, lw=3, label="")
        vspan!([cut_low, cut_high], fillrange=cut_high, label="Cut window", color=:red, lw=1.5, alpha=0.2)

        append!(qc_cuts.blsigmacut, (blstd_ch .> cut_low) .& (blstd_ch .< cut_high))



        # Slope
        xlim_factor, slope_cut_factor = 1, 0.2
        stephist!(blslope_plots[i], blslope_ch, label="Bl Slope", title=format("Channel g{:>03d}", ch), xlim=(median(blslope_ch)-xlim_factor*std(blslope_ch), median(blslope_ch)+xlim_factor*std(blslope_ch)), normalize=:pdf, nbins=convert(Int, round(length(blslope_ch)/30)))
        blslope_unit = unit(blslope_ch[1])
        hists = fit(Histogram, blslope_ch/blslope_unit, nbins=convert(Int, round(length(blslope_ch)/30)))
        cts_argmax = mapslices(argmax, hists.weights, dims=1)[1]
        cts_max = hists.weights[cts_argmax]

        cut_low_arg = filter((x) -> hists.weights[x] < slope_cut_factor * cts_max, reverse(1:cts_argmax))[1]
        cut_high_arg = filter((x) -> hists.weights[x] < slope_cut_factor * cts_max, cts_argmax:length(hists.weights))[1]
        cut_low, cut_high = Array(hists.edges[1])[cut_low_arg]*blslope_unit, Array(hists.edges[1])[cut_high_arg]*blslope_unit
        printfmtln("BL Slope Cut window: [{}, {}]", cut_low, cut_high)
        vline!(blslope_plots[i], [cut_low, cut_high], color=:red, lw=3, label="")
        vspan!(blslope_plots[i], [cut_low, cut_high], fillrange=cut_high, label="Cut window", color=:red, lw=1.5, alpha=0.2)

        append!(qc_cuts.blslopecut, (blslope_ch .> cut_low) .& (blslope_ch .< cut_high))


        # break
        println()
    end



    bl_mean_pdf = joinpath(cuts_figure_folder, format("string{}", string_number), format("string{}_blmean.pdf", string_number))
    bl_mean_pdf_tmp = joinpath(cuts_figure_folder, format("string{}", string_number), format("string{}_blmean_tmp.pdf", string_number))

    for p in blmean_plots
        p_save = plot(p, size=(1000, 800), xlabel="Baseline Mean [ADC]", ylabel="Counts", framestyle=:box, margin=10mm, xtickfontsize=font_size, ytickfontsize=font_size, xguidefontsize=font_size, yguidefontsize=font_size, legendfontsize=font_size)
        savefig(p_save, bl_mean_pdf_tmp)
        append_pdf!(string(bl_mean_pdf), string(bl_mean_pdf_tmp), cleanup=true)
    end

    bl_std_pdf = joinpath(cuts_figure_folder, format("string{}", string_number), format("string{}_blstd.pdf", string_number))
    bl_std_pdf_tmp = joinpath(cuts_figure_folder, format("string{}", string_number), format("string{}_blstd_tmp.pdf", string_number))

    for p in blstd_plots
        p_save = plot(p, size=(1000, 800), xlabel="Baseline Std [ADC]", ylabel="Counts", framestyle=:box, margin=10mm, xtickfontsize=font_size, ytickfontsize=font_size, xguidefontsize=font_size, yguidefontsize=font_size, legendfontsize=font_size)
        savefig(p_save, bl_std_pdf_tmp)
        append_pdf!(string(bl_std_pdf), string(bl_std_pdf_tmp), cleanup=true)
    end

    bl_slope_pdf = joinpath(cuts_figure_folder, format("string{}", string_number), format("string{}_blslope.pdf", string_number))
    bl_slope_pdf_tmp = joinpath(cuts_figure_folder, format("string{}", string_number), format("string{}_blslope_tmp.pdf", string_number))
    
    for p in blslope_plots
        # plot!(p, )
        savefig(p, bl_slope_pdf_tmp)
        append_pdf!(string(bl_slope_pdf), string(bl_slope_pdf_tmp), cleanup=true)
    end
    break

end
# current()


# Time Plots 

# string_number = 1
for string_number in string_numbers

    printfmtln("Processing string number: {}", string_number)
    println()
    println()
    println("Check figure folder")
    checkFolder(joinpath(cuts_figure_folder, format("string{}", string_number)), true)
    println()
    println()

    dsp_data, channel_list, label_listExt, label_list = data_strings[string_number]


    rt1090_plots = repeat([plot(1)], length(channel_list))
    rt1099_plots = repeat([plot(1)], length(channel_list))
    rt9099_plots = repeat([plot(1)], length(channel_list))
    drifttime_plots = repeat([plot(1)], length(channel_list))
    t0_plots = repeat([plot(1)], length(channel_list))


    for (i, ch) in enumerate(channel_list)
        rt1090_ch      = dsp_data[ch].rt1090
        rt1099_ch      = dsp_data[ch].rt1099
        rt9099_ch      = dsp_data[ch].rt9099
        drifttime_ch   = dsp_data[ch].drift_time
        t0_ch          = dsp_data[ch].t0

        printfmtln("Channel: {}", ch)
        printfmtln("Number of events: {}", length(rt1090_ch))
        printfmtln("Median of rt1090: {}", median(rt1090_ch))
        printfmtln("Median of rt1099: {}", median(rt1099_ch))
        printfmtln("Median of rt9099: {}", median(rt9099_ch))
        printfmtln("Median of drifttime: {}", median(drifttime_ch))
        printfmtln("Median of t0: {}", median(t0_ch))

        # xlim_factor, mean_cut_factor = 2, 0.2
        xlim_factor = 1
        rt1090_plots[i]  = stephist(rt1090_ch, label="RT 10-90", title=format("Channel g{:>03d}", ch), xlim=(zero(rt1090_ch[1]), median(rt1090_ch)+xlim_factor*median(rt1090_ch)), normalize=:pdf, nbins=convert(Int, round(length(rt1090_ch)/30)))
        # rt1090_plots[i]  = stephist(rt1090_ch, label="RT 10-90", title=format("Channel g{:>03d}", ch), xlim=(zero(rt1090_ch[1]), median(rt1090_ch)+xlim_factor*median(rt1090_ch)), nbins=:sturges)

        rt9099_plots[i] = stephist(rt9099_ch, label="RT 90-99", title=format("Channel g{:>03d}", ch), xlim=(zero(rt9099_ch[1]), median(rt9099_ch)+xlim_factor*median(rt9099_ch)), normalize=:pdf, nbins=convert(Int, round(length(rt9099_ch)/30)))

        rt1099_plots[i] = stephist(rt1099_ch, label="RT 10-99", title=format("Channel g{:>03d}", ch), xlim=(zero(rt1099_ch[1]), median(rt1099_ch)+xlim_factor*median(rt1099_ch)), normalize=:pdf, nbins=convert(Int, round(length(rt1099_ch)/30)))

        drifttime_plots[i] = stephist(drifttime_ch, label="Drift Time", title=format("Channel g{:>03d}", ch), xlim=(zero(drifttime_ch[1]), median(drifttime_ch)+xlim_factor*median(drifttime_ch)), normalize=:pdf, nbins=convert(Int, round(length(drifttime_ch)/30)))

        t0_plots[i] = stephist(t0_ch, label="t0", title=format("Channel g{:>03d}", ch), xlim=(45u"µs", 50u"µs"), normalize=:pdf, nbins=convert(Int, round(length(t0_ch)/500)))

        # break
        println()
    end

    font_size = 14

    rt_1090_pdf     = joinpath(cuts_figure_folder, format("string{}", string_number), format("string{}_rt1090.pdf", string_number))
    rt_1099_pdf     = joinpath(cuts_figure_folder, format("string{}", string_number), format("string{}_rt1099.pdf", string_number))
    rt_9099_pdf     = joinpath(cuts_figure_folder, format("string{}", string_number), format("string{}_rt9099.pdf", string_number))
    drifttime_pdf   = joinpath(cuts_figure_folder, format("string{}", string_number), format("string{}_drifttime.pdf", string_number))
    t0_pdf          = joinpath(cuts_figure_folder, format("string{}", string_number), format("string{}_t0.pdf", string_number))

    tmp_pdf        = joinpath(cuts_figure_folder, format("string{}", string_number), format("string{}_tmp.pdf", string_number))

    for p in rt1090_plots
        plot(p, size=(1000, 800), ylabel="Counts", framestyle=:box, margin=10mm, xtickfontsize=font_size, ytickfontsize=font_size, xguidefontsize=font_size, yguidefontsize=font_size, legendfontsize=font_size)
        savefig(tmp_pdf)
        append_pdf!(string(rt_1090_pdf), string(tmp_pdf), cleanup=true)
    end

    for p in rt1099_plots
        plot(p, size=(1000, 800), ylabel="Counts", framestyle=:box, margin=10mm, xtickfontsize=font_size, ytickfontsize=font_size, xguidefontsize=font_size, yguidefontsize=font_size, legendfontsize=font_size)
        savefig(tmp_pdf)
        append_pdf!(string(rt_1099_pdf), string(tmp_pdf), cleanup=true)
    end

    for p in rt9099_plots
        plot(p, size=(1000, 800), ylabel="Counts", framestyle=:box, margin=10mm, xtickfontsize=font_size, ytickfontsize=font_size, xguidefontsize=font_size, yguidefontsize=font_size, legendfontsize=font_size)
        savefig(tmp_pdf)
        append_pdf!(string(rt_9099_pdf), string(tmp_pdf), cleanup=true)
    end

    for p in drifttime_plots
        plot(p, size=(1000, 800), ylabel="Counts", framestyle=:box, margin=10mm, xtickfontsize=font_size, ytickfontsize=font_size, xguidefontsize=font_size, yguidefontsize=font_size, legendfontsize=font_size)
        savefig(tmp_pdf)
        append_pdf!(string(drifttime_pdf), string(tmp_pdf), cleanup=true)
    end

    for p in t0_plots
        plot(p, size=(1000, 800), ylabel="Counts", framestyle=:box, margin=10mm, xtickfontsize=font_size, ytickfontsize=font_size, xguidefontsize=font_size, yguidefontsize=font_size, legendfontsize=font_size)
        savefig(tmp_pdf)
        append_pdf!(string(t0_pdf), string(tmp_pdf), cleanup=true)
    end

    # break

end
# current()

for string_number in string_numbers

    printfmtln("Processing string number: {}", string_number)
    println()
    println()
    println("Check figure folder")
    checkFolder(joinpath(cuts_figure_folder, format("string{}", string_number)), true)
    println()
    println()

    dsp_data, channel_list, label_listExt, label_list = data_strings[string_number]


    blmean_2D_plots = repeat([plot(1)], length(channel_list))
    blstd_2D_plots = repeat([plot(1)], length(channel_list))
    blslope_2D_plots = repeat([plot(1)], length(channel_list))

    for (i, ch) in enumerate(channel_list)
        blmean_ch  = dsp_data[ch].blmean
        blstd_ch   = dsp_data[ch].blsigma
        blslope_ch = dsp_data[ch].blslope
        timestamps_ch = dsp_data[ch].timestamp .- dsp_data[ch].timestamp[1]

        printfmtln("Channel: {}", ch)
        printfmtln("Number of events: {}", length(blmean_ch))
        printfmtln("Median of baseline mean: {}",  median(blmean_ch))
        printfmtln("Median of baseline std: {}",   median(blstd_ch))
        printfmtln("Median of baseline slope: {}", median(blslope_ch))

        # Mean
        xlim_factor = 1
        # blmean_2D_plots[i] = histogram2d(timestamps_ch/unit(timestamps_ch[1]), blmean_ch, nbins=(500, 5000), ylim=(median(blmean_ch)-1000, median(blmean_ch)+1000), title=format("Channel g{:>03d}", ch), color=:plasma, ylabel="Baseline Mean [ADC]", show_empty_bins=true)#, xlim=(timestamps_ch[1], timestamps_ch[end]))
        blmean_2D_plots[i] = histogram2d(uconvert.(u"minute", timestamps_ch), blmean_ch, nbins=(150, 5000), ylim=(median(blmean_ch)-1000, median(blmean_ch)+1000), title=format("Channel g{:>03d}", ch), color=cgrad(:linear_worb_100_25_c53_n256, scale=:log), ylabel="Baseline Mean [ADC]", show_empty_bins=true, dpi=100)#, xlim=(timestamps_ch[1], timestamps_ch[end]))

        # Std
        # blstd_2D_plots[i] = histogram2d(timestamps_ch/unit(timestamps_ch[1]), blstd_ch, nbins=(500, 5000), ylim=(median(blstd_ch)-1000, median(blstd_ch)+1000), title=format("Channel g{:>03d}", ch), color=:plasma, ylabel="Baseline Std [ADC]", show_empty_bins=true)#, xlim=(timestamps_ch[1], timestamps_ch[end]))
        blstd_2D_plots[i] = histogram2d(uconvert.(u"minute", timestamps_ch), blstd_ch, nbins=(150, 5000), ylim=(0, median(blstd_ch)+50), title=format("Channel g{:>03d}", ch), color=cgrad(:linear_worb_100_25_c53_n256, scale=:log), ylabel="Baseline Std [ADC]", show_empty_bins=true, dpi=100)#, xlim=(timestamps_ch[1], timestamps_ch[end]))

        # Slope
        # blslope_2D_plots[i] = histogram2d(timestamps_ch/unit(timestamps_ch[1]), blslope_ch, nbins=(500, 5000), ylim=(median(blslope_ch)-1000, median(blslope_ch)+1000), title=format("Channel g{:>03d}", ch), color=:plasma, ylabel="Baseline Slope [ADC]", show_empty_bins=true)#, xlim=(timestamps_ch[1], timestamps_ch[end]))
        blslope_2D_plots[i] = histogram2d(uconvert.(u"minute", timestamps_ch), blslope_ch, nbins=(150, 5000), title=format("Channel g{:>03d}", ch), color=cgrad(:linear_worb_100_25_c53_n256, scale=:log), ylabel="Baseline Slope [ADC]", show_empty_bins=true, dpi=100)#, xlim=(timestamps_ch[1], timestamps_ch[end]))


        # break
        println()
    end

    font_size = 14

    blmean_2D_pdf   = joinpath(cuts_figure_folder, format("string{}", string_number), format("string{}_blmean-time.pdf", string_number))
    blstd_2D_pdf    = joinpath(cuts_figure_folder, format("string{}", string_number), format("string{}_blstd-time.pdf", string_number))
    blslope_2D_pdf  = joinpath(cuts_figure_folder, format("string{}", string_number), format("string{}_blslope-time.pdf", string_number))
    
    # plot(blmean_2D_plots..., layout=(length(channel_list), 1), size=(2000, 5000), framestyle=:box, margin=10mm, xtickfontsize=18, ytickfontsize=18, xguidefontsize=18, yguidefontsize=18, legendfontsize=18, dpi=100)
    # savefig(blmean_2D_pdf)

    # plot(blstd_2D_plots..., layout=(length(channel_list), 1), size=(2000, 5000), framestyle=:box, margin=10mm, xtickfontsize=18, ytickfontsize=18, xguidefontsize=18, yguidefontsize=18, legendfontsize=18, dpi=100)
    # savefig(blstd_2D_pdf)

    # plot(blslope_2D_plots..., layout=(length(channel_list), 1), size=(2000, 5000), framestyle=:box, margin=10mm, xtickfontsize=18, ytickfontsize=18, xguidefontsize=18, yguidefontsize=18, legendfontsize=18, dpi=100)
    # savefig(blslope_2D_pdf)

    tmp_pdf = joinpath(cuts_figure_folder, format("string{}", string_number), format("string{}_2D_tmp.pdf", string_number))

    for p in blmean_2D_plots
        plot(p, size=(1000, 800), framestyle=:box, margin=10mm, xtickfontsize=font_size, ytickfontsize=font_size, xguidefontsize=font_size, yguidefontsize=font_size, legendfontsize=font_size, dpi=100)
        savefig(tmp_pdf)
        append_pdf!(string(blmean_2D_pdf), string(tmp_pdf), cleanup=true)
    end

    for p in blstd_2D_plots
        plot(p, size=(1000, 800), framestyle=:box, margin=10mm, xtickfontsize=font_size, ytickfontsize=font_size, xguidefontsize=font_size, yguidefontsize=font_size, legendfontsize=font_size, dpi=100)
        savefig(tmp_pdf)
        append_pdf!(string(blstd_2D_pdf), string(tmp_pdf), cleanup=true)
    end

    for p in blslope_2D_plots
        plot(p, size=(800, 800), framestyle=:box, margin=10mm, xtickfontsize=font_size, ytickfontsize=font_size, xguidefontsize=font_size, yguidefontsize=font_size, legendfontsize=font_size, dpi=100)
        savefig(tmp_pdf)
        append_pdf!(string(blslope_2D_pdf), string(tmp_pdf), cleanup=true)
    end
    # break
    
end
# current()

# Save cuts
saveCuts(string(cut_folder), qc_cuts)