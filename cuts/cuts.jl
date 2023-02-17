using RadiationDetectorDSP
using Plots
using LegendHDF5IO
using Unitful
using RadiationDetectorSignals
using Statistics
using GLM
using LinearRegression
using InverseFunctions
using ArraysOfArrays
using TypedTables
using BenchmarkTools
using LaTeXStrings
using Measures
using HDF5
using ProgressBars
using FilePathsBase
using Formatting
using Base
using ConfParser
using IntervalSets
using ThreadsX
using DataFrames
using ElasticArrays
using Distributions
using StatsPlots
using StatsBase

include("../utils/loader.jl")
include("../utils/saver.jl")

tier2_folder = "/mnt/atlas01/users/henkes/l60_r025/julia/cal/tier2/"
tier3_folder = "/mnt/atlas01/users/henkes/l60_r025/julia/cal/tier3/"

config_file = "/home/ga26tel/legend/julia/l60/configs/config_l60_r025.json"

figure_folder = "/home/ga26tel/legend/julia/l60/figures/"

string_numbers = [1, 2, 7, 8]

data_strings = Dict{Int, Any}()
qc_cuts = TypedTables.Table(channel=Int[], blmeancut = Bool[], blsigmacut = Bool[], blslopecut = Bool[], 
        timestamp = Float64[]u"s", eventID_fadc = Int[]
        )

for string_number in string_numbers
    printfmtln("Loading string number: {}", string_number)
    println()
    println()

    # Load config file
    channel_dict = configLoader_string(string_number, config_file)
    channel_list, label_listExt, label_list = channel_dict["channel_list"], channel_dict["label_listExt"], channel_dict["label_list"]

    dsp_data = runLoader(channel_list, tier2_folder)
    data_strings[string_number] = [dsp_data, channel_list, label_listExt, label_list]
end

# Baseline cuts
for string_number in string_numbers

    printfmtln("Processing string number: {}", string_number)
    println()
    println()

    dsp_data, channel_list, label_listExt, label_list = data_strings[string_number]

    blmean_plots = repeat([plot(1)], length(channel_list))
    blstd_plots = repeat([plot(1)], length(channel_list))
    blslope_plots = repeat([plot(1)], length(channel_list))

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
        blslope_plots[i] = stephist(blslope_ch, label="Bl Slope", title=format("Channel g{:>03d}", ch), xlim=(median(blslope_ch)-xlim_factor*std(blslope_ch), median(blslope_ch)+xlim_factor*std(blslope_ch)), normalize=:pdf, nbins=convert(Int, round(length(blslope_ch)/30)))
        blslope_unit = unit(blslope_ch[1])
        hists = fit(Histogram, blslope_ch/blslope_unit, nbins=convert(Int, round(length(blslope_ch)/30)))
        cts_argmax = mapslices(argmax, hists.weights, dims=1)[1]
        cts_max = hists.weights[cts_argmax]

        cut_low_arg = filter((x) -> hists.weights[x] < slope_cut_factor * cts_max, reverse(1:cts_argmax))[1]
        cut_high_arg = filter((x) -> hists.weights[x] < slope_cut_factor * cts_max, cts_argmax:length(hists.weights))[1]
        cut_low, cut_high = Array(hists.edges[1])[cut_low_arg]*blslope_unit, Array(hists.edges[1])[cut_high_arg]*blslope_unit
        printfmtln("BL Slope Cut window: [{}, {}]", cut_low, cut_high)
        vline!([cut_low, cut_high], color=:red, lw=3, label="")
        vspan!([cut_low, cut_high], fillrange=cut_high, label="Cut window", color=:red, lw=1.5, alpha=0.2)

        append!(qc_cuts.blslopecut, (blslope_ch .> cut_low) .& (blslope_ch .< cut_high))


        # break
        println()
    end


    plot(blmean_plots..., layout=(length(channel_list), 1), size=(1000, 3000), framestyle=:box, margin=10mm, xtickfontsize=18, ytickfontsize=18, xguidefontsize=18, yguidefontsize=18, legendfontsize=18)
    xlabel!("Baseline Mean [ADC]")
    ylabel!("Counts")
    savefig(figure_folder * format("string{}_blmean.pdf", string_number))


    plot(blstd_plots..., layout=(length(channel_list), 1), size=(1000, 3000), framestyle=:box, margin=10mm, xtickfontsize=18, ytickfontsize=18, xguidefontsize=18, yguidefontsize=18, legendfontsize=18)
    xlabel!("Baseline Std [ADC]")
    ylabel!("Counts")
    savefig(figure_folder * format("string{}_blstd.pdf", string_number))

    plot(blslope_plots..., layout=(length(channel_list), 1), size=(1000, 3000), framestyle=:box, margin=10mm, xtickfontsize=18, ytickfontsize=18, xguidefontsize=18, yguidefontsize=18, legendfontsize=18)
    # xlabel!("Baseline Slope")
    ylabel!("Counts")
    savefig(figure_folder * format("string{}_blslope.pdf", string_number))


end


# Time Plots 

# string_number = 1
for string_number in string_numbers

    printfmtln("Processing string number: {}", string_number)
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
    plot(rt1090_plots..., layout=(length(channel_list), 1), size=(1000, 3000), framestyle=:box, margin=10mm, xtickfontsize=18, ytickfontsize=18, xguidefontsize=18, yguidefontsize=18, legendfontsize=18)
    ylabel!("Counts")
    savefig(figure_folder * format("string{}_rt1090.pdf", string_number))

    plot(rt1099_plots..., layout=(length(channel_list), 1), size=(1000, 3000), framestyle=:box, margin=10mm, xtickfontsize=18, ytickfontsize=18, xguidefontsize=18, yguidefontsize=18, legendfontsize=18)
    ylabel!("Counts")
    savefig(figure_folder * format("string{}_rt1099.pdf", string_number))

    plot(rt9099_plots..., layout=(length(channel_list), 1), size=(1000, 3000), framestyle=:box, margin=10mm, xtickfontsize=18, ytickfontsize=18, xguidefontsize=18, yguidefontsize=18, legendfontsize=18)
    ylabel!("Counts")
    savefig(figure_folder * format("string{}_rt9099.pdf", string_number))

    plot(drifttime_plots..., layout=(length(channel_list), 1), size=(1000, 3000), framestyle=:box, margin=10mm, xtickfontsize=18, ytickfontsize=18, xguidefontsize=18, yguidefontsize=18, legendfontsize=18)
    ylabel!("Counts")
    savefig(figure_folder * format("string{}_drifttime.pdf", string_number))

    plot(t0_plots..., layout=(length(channel_list), 1), size=(1000, 3000), framestyle=:box, margin=10mm, xtickfontsize=18, ytickfontsize=18, xguidefontsize=18, yguidefontsize=18, legendfontsize=18)
    ylabel!("Counts")
    savefig(figure_folder * format("string{}_t0.pdf", string_number))

    # break

end
# current()

for string_number in string_numbers

    printfmtln("Processing string number: {}", string_number)
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
        blmean_2D_plots[i] = histogram2d(uconvert.(u"minute", timestamps_ch), blmean_ch, nbins=(150, 5000), ylim=(median(blmean_ch)-1000, median(blmean_ch)+1000), title=format("Channel g{:>03d}", ch), color=cgrad(:linear_worb_100_25_c53_n256, scale=:log), ylabel="Baseline Mean [ADC]", show_empty_bins=true)#, xlim=(timestamps_ch[1], timestamps_ch[end]))


        # Std
        # blstd_2D_plots[i] = histogram2d(timestamps_ch/unit(timestamps_ch[1]), blstd_ch, nbins=(500, 5000), ylim=(median(blstd_ch)-1000, median(blstd_ch)+1000), title=format("Channel g{:>03d}", ch), color=:plasma, ylabel="Baseline Std [ADC]", show_empty_bins=true)#, xlim=(timestamps_ch[1], timestamps_ch[end]))
        blstd_2D_plots[i] = histogram2d(uconvert.(u"minute", timestamps_ch), blstd_ch, nbins=(150, 5000), ylim=(0, median(blstd_ch)+50), title=format("Channel g{:>03d}", ch), color=cgrad(:linear_worb_100_25_c53_n256, scale=:log), ylabel="Baseline Std [ADC]", show_empty_bins=true)#, xlim=(timestamps_ch[1], timestamps_ch[end]))

        # Slope
        # blslope_2D_plots[i] = histogram2d(timestamps_ch/unit(timestamps_ch[1]), blslope_ch, nbins=(500, 5000), ylim=(median(blslope_ch)-1000, median(blslope_ch)+1000), title=format("Channel g{:>03d}", ch), color=:plasma, ylabel="Baseline Slope [ADC]", show_empty_bins=true)#, xlim=(timestamps_ch[1], timestamps_ch[end]))
        blslope_2D_plots[i] = histogram2d(uconvert.(u"minute", timestamps_ch), blslope_ch, nbins=(150, 5000), title=format("Channel g{:>03d}", ch), color=cgrad(:linear_worb_100_25_c53_n256, scale=:log), ylabel="Baseline Slope [ADC]", show_empty_bins=true)#, xlim=(timestamps_ch[1], timestamps_ch[end]))


        # break
        println()
    end


    plot(blmean_2D_plots..., layout=(length(channel_list), 1), size=(2000, 5000), framestyle=:box, margin=10mm, xtickfontsize=18, ytickfontsize=18, xguidefontsize=18, yguidefontsize=18, legendfontsize=18, dpi=100)
    savefig(figure_folder * format("string{}_blmean-time.png", string_number))

    plot(blstd_2D_plots..., layout=(length(channel_list), 1), size=(2000, 5000), framestyle=:box, margin=10mm, xtickfontsize=18, ytickfontsize=18, xguidefontsize=18, yguidefontsize=18, legendfontsize=18, dpi=100)
    savefig(figure_folder * format("string{}_blstd-time.png", string_number))

    plot(blslope_2D_plots..., layout=(length(channel_list), 1), size=(2000, 5000), framestyle=:box, margin=10mm, xtickfontsize=18, ytickfontsize=18, xguidefontsize=18, yguidefontsize=18, legendfontsize=18, dpi=100)
    savefig(figure_folder * format("string{}_blslope-time.png", string_number))

    # break
    
end
# current()

# Save cuts
saveCuts(tier3_folder, qc_cuts)