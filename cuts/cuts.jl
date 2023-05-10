include("../utils/packages.jl")
include("../utils/loader.jl")
include("../utils/saver.jl")

is_cal = true
period = 2
calrun = 12
config_folder = p"/home/iwsatlas1/henkes/l200/l200-p02-analysis/configs/"
experiment = "l200"
println("Start Cuts for $experiment, period $period, run $calrun")
println("Loading meta data")

channel_list, label_dict, label_list_ext, string_dict, folder_dict = loadMeta(config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)

cuts_figure_folder = joinpath(folder_dict["folder_figures"], "cuts")
checkFolder(PosixPath(cuts_figure_folder), true)

# load dsp data
folder_dsp = folder_dict["folder_dsp"]
moveBrokenFiles(folder_dsp)
data_dsp = loadDSP(folder_dsp, channel_list)


# Create cuts TypedTables
qc_cuts_dict = Dict{String, TypedTables.Table}()
bl_mean_cut_dict = Dict{String, Array{Float32}}()
bl_std_cut_dict = Dict{String, Array{Float32}}()
bl_slope_cut_dict = Dict{String, Array{Float32}}()
t0_cut_dict = Dict{String, Array{Float32}}()
rt1090_cut_dict = Dict{String, Array{Float32}}()
drift_time_cut_dict = Dict{String, Array{Float32}}()
τ_cut_dict = Dict{String, Array{Float32}}()
e_trap_cut_dict = Dict{String, Array{Float32}}()
a_cut_dict = Dict{String, Array{Float32}}()
for ch in channel_list
    qc_cuts_dict[ch] = TypedTables.Table(
        blmeancut = Bool[], blsigmacut = Bool[], blslopecut = Bool[], 
        t0cut = Bool[], rt1090cut = Bool[], driftTimecut = Bool[], τ_cut = Bool[],
        e_trap_cut = Bool[], a_cut = Bool[], 
        timestamp = Float64[]u"s", eventID_fadc = Int[]
        )
end

# Baseline cuts
for (string_number, string_channel_list) in string_dict

    printfmtln("Processing string number: {}", string_number)
    println()
    println()
    println("Check figure folder")
    string_cuts_figure_folder = joinpath(cuts_figure_folder, format("string{}", string_number))
    checkFolder(PosixPath(string_cuts_figure_folder), true)
    println()
    println()

    font_size = 14

    blmean_plots = repeat([plot(1)], length(string_channel_list))
    blstd_plots = repeat([plot(1)], length(string_channel_list))
    blslope_plots = [plot(u"ns^-1", Unitful.NoUnits, size=(1000, 800), xlabel="Baseline Slope", ylabel="Counts", framestyle=:box, margin=10mm, xtickfontsize=font_size, ytickfontsize=font_size, xguidefontsize=font_size, yguidefontsize=font_size, legendfontsize=font_size) for i in 1:length(string_channel_list)]

    for (i, ch) in enumerate(string_channel_list)
        label_ext = label_list_ext[ch]

        blmean_ch  = data_dsp[ch].blmean
        blstd_ch   = data_dsp[ch].blsigma
        blslope_ch = data_dsp[ch].blslope

        printfmtln("Channel: {}", ch)
        printfmtln("Number of events: {}", length(blmean_ch))
        printfmtln("Median of baseline mean: {}",  median(blmean_ch))
        printfmtln("Median of baseline std: {}",   median(blstd_ch))
        printfmtln("Median of baseline slope: {}", median(blslope_ch))

        append!(qc_cuts_dict[ch].timestamp, data_dsp[ch].timestamp)
        append!(qc_cuts_dict[ch].eventID_fadc, data_dsp[ch].eventID_fadc)

    
        # Mean
        xlim_factor, mean_cut_factor = 2, 0.2
        blmean_plots[i]  = stephist(blmean_ch, label="Bl Mean", title="Channel $ch ($label_ext)", xlim=(median(blmean_ch)-xlim_factor*std(blmean_ch), median(blmean_ch)+xlim_factor*std(blmean_ch)), normalize=:pdf)
        hists = fit(Histogram, blmean_ch, nbins=convert(Int, round(length(blmean_ch)/100)))
        cts_argmax = mapslices(argmax, hists.weights, dims=1)[1]
        cts_max = hists.weights[cts_argmax]

        cut_low_arg  = filter((x) -> hists.weights[x] < mean_cut_factor * cts_max, reverse(1:cts_argmax))[1]
        cut_high_arg = filter((x) -> hists.weights[x] < mean_cut_factor * cts_max, cts_argmax:length(hists.weights))[1]
        cut_low, cut_high = Array(hists.edges[1])[cut_low_arg], Array(hists.edges[1])[cut_high_arg]

        printfmtln("BL Mean Cut window: [{}, {}]", cut_low, cut_high)
        vline!([cut_low, cut_high], color=:red, lw=3, label="")
        vspan!([cut_low, cut_high], fillrange=cut_high, label="Cut window", color=:red, lw=1.5, alpha=0.2)

        append!(qc_cuts_dict[ch].blmeancut, (blmean_ch .> cut_low) .& (blmean_ch .< cut_high))
        bl_mean_cut_dict[ch] = [cut_low, cut_high]

        # Std
        xlim_factor, std_cut_factor = 1, 0.2
        blstd_plots[i]   = stephist(blstd_ch, label="Bl Std", title="Channel $ch ($label_ext)", xlim=(0, median(blstd_ch)+xlim_factor*std(blstd_ch)), normalize=:pdf, nbins=convert(Int, round(length(blstd_ch)/30)))
        hists = fit(Histogram, blstd_ch, nbins=convert(Int, round(length(blstd_ch)/30)))
        cts_argmax = mapslices(argmax, hists.weights, dims=1)[1]
        cts_max = hists.weights[cts_argmax]

        try
            cut_low_arg = filter((x) -> hists.weights[x] < std_cut_factor * cts_max, reverse(1:cts_argmax))[1]
        catch
            cut_low_arg = 1
        end
        cut_high_arg = filter((x) -> hists.weights[x] < std_cut_factor * cts_max, cts_argmax:length(hists.weights))[1]
        cut_low, cut_high = Array(hists.edges[1])[cut_low_arg], Array(hists.edges[1])[cut_high_arg]
        printfmtln("BL Std Cut window: [{}, {}]", cut_low, cut_high)
        vline!([cut_low, cut_high], color=:red, lw=3, label="")
        vspan!([cut_low, cut_high], fillrange=cut_high, label="Cut window", color=:red, lw=1.5, alpha=0.2)

        append!(qc_cuts_dict[ch].blsigmacut, (blstd_ch .> cut_low) .& (blstd_ch .< cut_high))
        bl_std_cut_dict[ch] = [cut_low, cut_high]


        # Slope
        xlim_factor, slope_cut_factor = 1, 0.2
        stephist!(blslope_plots[i], blslope_ch, label="Bl Slope", title="Channel $ch ($label_ext)", xlim=(median(blslope_ch)-xlim_factor*std(blslope_ch), median(blslope_ch)+xlim_factor*std(blslope_ch)), normalize=:pdf, nbins=convert(Int, round(length(blslope_ch)/30)))
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

        append!(qc_cuts_dict[ch].blslopecut, (blslope_ch .> cut_low) .& (blslope_ch .< cut_high))
        bl_slope_cut_dict[ch] = uconvert.(NoUnits, [cut_low, cut_high]./blslope_unit)

        # break
        println()
    end



    bl_mean_pdf = joinpath(string_cuts_figure_folder, format("string{}_blmean.pdf", string_number))
    bl_mean_pdf_tmp = joinpath(string_cuts_figure_folder, format("string{}_blmean_tmp.pdf", string_number))

    for p in blmean_plots
        p_save = plot(p, size=(1000, 800), xlabel="Baseline Mean [ADC]", ylabel="Counts", framestyle=:box, margin=10mm, xtickfontsize=font_size, ytickfontsize=font_size, xguidefontsize=font_size, yguidefontsize=font_size, legendfontsize=font_size)
        savefig(p_save, bl_mean_pdf_tmp)
        append_pdf!(string(bl_mean_pdf), string(bl_mean_pdf_tmp), cleanup=true)
    end

    bl_std_pdf = joinpath(string_cuts_figure_folder, format("string{}_blstd.pdf", string_number))
    bl_std_pdf_tmp = joinpath(string_cuts_figure_folder, format("string{}_blstd_tmp.pdf", string_number))

    for p in blstd_plots
        p_save = plot(p, size=(1000, 800), xlabel="Baseline Std [ADC]", ylabel="Counts", framestyle=:box, margin=10mm, xtickfontsize=font_size, ytickfontsize=font_size, xguidefontsize=font_size, yguidefontsize=font_size, legendfontsize=font_size)
        savefig(p_save, bl_std_pdf_tmp)
        append_pdf!(string(bl_std_pdf), string(bl_std_pdf_tmp), cleanup=true)
    end

    bl_slope_pdf = joinpath(string_cuts_figure_folder, format("string{}_blslope.pdf", string_number))
    bl_slope_pdf_tmp = joinpath(string_cuts_figure_folder, format("string{}_blslope_tmp.pdf", string_number))
    
    for p in blslope_plots
        # plot!(p, )
        savefig(p, bl_slope_pdf_tmp)
        append_pdf!(string(bl_slope_pdf), string(bl_slope_pdf_tmp), cleanup=true)
    end
    # break

end
# current()


# Time Plots 

for (string_number, string_channel_list) in string_dict

    printfmtln("Processing string number: {}", string_number)
    println()
    println()
    println("Check figure folder")
    string_cuts_figure_folder = joinpath(cuts_figure_folder, format("string{}", string_number))
    checkFolder(PosixPath(string_cuts_figure_folder), true)
    println()
    println()


    rt1090_plots = repeat([plot(1)], length(string_channel_list))
    rt1099_plots = repeat([plot(1)], length(string_channel_list))
    rt9099_plots = repeat([plot(1)], length(string_channel_list))
    drifttime_plots = repeat([plot(1)], length(string_channel_list))
    t0_plots = repeat([plot(1)], length(string_channel_list))
    τ_plots = repeat([plot(1)], length(string_channel_list))


    for (i, ch) in enumerate(string_channel_list)
        label_ext = label_list_ext[ch]

        rt1090_ch      = data_dsp[ch].rt1090
        rt1099_ch      = data_dsp[ch].rt1099
        rt9099_ch      = data_dsp[ch].rt9099
        drifttime_ch   = data_dsp[ch].drift_time
        t0_ch          = data_dsp[ch].t0
        τ_ch           = uconvert.(u"µs", data_dsp[ch].τ)
        

        printfmtln("Channel: {}", ch)
        printfmtln("Number of events: {}", length(rt1090_ch))
        printfmtln("Median of rt1090: {}", median(rt1090_ch))
        printfmtln("Median of rt1099: {}", median(rt1099_ch))
        printfmtln("Median of rt9099: {}", median(rt9099_ch))
        printfmtln("Median of drifttime: {}", median(drifttime_ch))
        printfmtln("Median of t0: {}", median(t0_ch))
        printfmtln("Median of τ: {}", median(τ_ch))

        # rise time plots (cut only on RT-10-90)
        xlim_factor, rt1090_cut_factor = 1, 0.15
        rt1090_plots[i]  = stephist(rt1090_ch, label="RT 10-90", title="Channel $ch ($label_ext)", xlim=(zero(rt1090_ch[1]), median(rt1090_ch)+xlim_factor*median(rt1090_ch)), normalize=:pdf, nbins=convert(Int, round(length(rt1090_ch)/30)))
        rt1090_unit = unit(rt1090_ch[1])
        hists = fit(Histogram, rt1090_ch/rt1090_unit, nbins=convert(Int, round(length(rt1090_ch)/30)))
        cts_argmax = mapslices(argmax, hists.weights, dims=1)[1]
        cts_max = hists.weights[cts_argmax]

        cut_low_arg = filter((x) -> hists.weights[x] < rt1090_cut_factor * cts_max, reverse(1:cts_argmax))[1]
        cut_high_arg = filter((x) -> hists.weights[x] < rt1090_cut_factor * cts_max, cts_argmax:length(hists.weights))[1]
        cut_low, cut_high = Array(hists.edges[1])[cut_low_arg]*rt1090_unit, Array(hists.edges[1])[cut_high_arg]*rt1090_unit
        printfmtln("RT1090 Cut window: [{}, {}]", cut_low, cut_high)
        vline!([cut_low, cut_high], color=:red, lw=3, label="")
        vspan!([cut_low, cut_high], fillrange=cut_high, label="Cut window", color=:red, lw=1.5, alpha=0.2)

        append!(qc_cuts_dict[ch].rt1090cut, (rt1090_ch .> cut_low) .& (rt1090_ch .< cut_high))
        rt1090_cut_dict[ch] = uconvert.(NoUnits, [cut_low, cut_high]./rt1090_unit)

        rt9099_plots[i] = stephist(rt9099_ch, label="RT 90-99", title="Channel $ch ($label_ext)", xlim=(zero(rt9099_ch[1]), median(rt9099_ch)+xlim_factor*median(rt9099_ch)), normalize=:pdf, nbins=convert(Int, round(length(rt9099_ch)/30)))

        rt1099_plots[i] = stephist(rt1099_ch, label="RT 10-99", title="Channel $ch ($label_ext)", xlim=(zero(rt1099_ch[1]), median(rt1099_ch)+xlim_factor*median(rt1099_ch)), normalize=:pdf, nbins=convert(Int, round(length(rt1099_ch)/30)))

        # drift time plots
        xlim_factor, drifttime_cut_factor = 1, 0.08
        drifttime_plots[i] = stephist(drifttime_ch, label="Drift Time", title="Channel $ch ($label_ext)", xlim=(zero(drifttime_ch[1]), median(drifttime_ch)+xlim_factor*median(drifttime_ch)), normalize=:pdf, nbins=convert(Int, round(length(drifttime_ch)/30)))
        drifttime_unit = unit(drifttime_ch[1])
        hists = fit(Histogram, drifttime_ch/drifttime_unit, nbins=convert(Int, round(length(drifttime_ch)/30)))
        cts_argmax = mapslices(argmax, hists.weights, dims=1)[1]
        cts_max = hists.weights[cts_argmax]

        cut_low_arg = filter((x) -> hists.weights[x] < drifttime_cut_factor * cts_max, reverse(1:cts_argmax))[1]
        cut_high_arg = filter((x) -> hists.weights[x] < drifttime_cut_factor * cts_max, cts_argmax:length(hists.weights))[1]
        cut_low, cut_high = Array(hists.edges[1])[cut_low_arg]*drifttime_unit, Array(hists.edges[1])[cut_high_arg]*drifttime_unit
        printfmtln("Drifttime Cut window: [{}, {}]", cut_low, cut_high)
        vline!([cut_low, cut_high], color=:red, lw=3, label="")
        vspan!([cut_low, cut_high], fillrange=cut_high, label="Cut window", color=:red, lw=1.5, alpha=0.2)

        append!(qc_cuts_dict[ch].driftTimecut, (drifttime_ch .> cut_low) .& (drifttime_ch .< cut_high))
        drift_time_cut_dict[ch] = uconvert.(NoUnits, [cut_low, cut_high]./drifttime_unit)

        # t0 plots
        xlim_factor, t0_cut_factor = 1, 0.1
        t0_plots[i] = stephist(t0_ch, label="t0", title="Channel $ch ($label_ext)", xlim=(46u"µs", 52u"µs"), normalize=:pdf, nbins=convert(Int, round(length(t0_ch)/500)))
        t0_unit = unit(t0_ch[1])
        hists = fit(Histogram, t0_ch/t0_unit, nbins=convert(Int, round(length(t0_ch)/500)))
        cts_argmax = mapslices(argmax, hists.weights, dims=1)[1]
        cts_max = hists.weights[cts_argmax]

        try
            cut_low_arg = filter((x) -> hists.weights[x] < t0_cut_factor * cts_max, reverse(1:cts_argmax))[1]
        catch
            cut_low_arg = 1
        end
        cut_high_arg = filter((x) -> hists.weights[x] < t0_cut_factor * cts_max, cts_argmax:length(hists.weights))[1]
        cut_low, cut_high = Array(hists.edges[1])[cut_low_arg]*t0_unit, Array(hists.edges[1])[cut_high_arg]*t0_unit
        printfmtln("t0 Cut window: [{}, {}]", cut_low, cut_high)
        vline!([cut_low, cut_high], color=:red, lw=3, label="")
        vspan!([cut_low, cut_high], fillrange=cut_high, label="Cut window", color=:red, lw=1.5, alpha=0.2)

        append!(qc_cuts_dict[ch].t0cut, (t0_ch .> cut_low) .& (t0_ch .< cut_high))
        t0_cut_dict[ch] = uconvert.(NoUnits, [cut_low, cut_high]./t0_unit)

        # decay time 
        xlim_factor, τ_cut_factor = 1, 0.2
        τ_ch_cut = τ_ch[τ_ch .> 0u"µs" .&& τ_ch .< 1100u"µs"]
        τ_plots[i] = stephist(τ_ch_cut, label="τ", title="Channel $ch ($label_ext)", xlim=(250u"µs", 800u"µs"), normalize=:pdf, nbins=convert(Int, round(length(τ_ch_cut)/500)))
        τ_unit = unit(τ_ch_cut[1])
        hists = fit(Histogram, τ_ch_cut/τ_unit, nbins=convert(Int, round(length(τ_ch_cut)/500)))
        cts_argmax = mapslices(argmax, hists.weights, dims=1)[1]
        cts_max = hists.weights[cts_argmax]

        cut_low_arg = filter((x) -> hists.weights[x] < τ_cut_factor * cts_max, reverse(1:cts_argmax))[1]
        cut_high_arg = filter((x) -> hists.weights[x] < τ_cut_factor * cts_max, cts_argmax:length(hists.weights))[1]
        cut_low, cut_high = Array(hists.edges[1])[cut_low_arg]*τ_unit, Array(hists.edges[1])[cut_high_arg]*τ_unit
        printfmtln("τ Cut window: [{}, {}]", cut_low, cut_high)
        vline!([cut_low, cut_high], color=:red, lw=3, label="")
        vspan!([cut_low, cut_high], fillrange=cut_high, label="Cut window", color=:red, lw=1.5, alpha=0.2)

        append!(qc_cuts_dict[ch].τ_cut, (τ_ch .> cut_low) .& (τ_ch .< cut_high))
        τ_cut_dict[ch] = uconvert.(NoUnits, [cut_low, cut_high]./τ_unit)

        # break
        println()
    end

    font_size = 14

    rt_1090_pdf     = joinpath(string_cuts_figure_folder, format("string{}_rt1090.pdf", string_number))
    rt_1099_pdf     = joinpath(string_cuts_figure_folder, format("string{}_rt1099.pdf", string_number))
    rt_9099_pdf     = joinpath(string_cuts_figure_folder, format("string{}_rt9099.pdf", string_number))
    drifttime_pdf   = joinpath(string_cuts_figure_folder, format("string{}_drifttime.pdf", string_number))
    t0_pdf          = joinpath(string_cuts_figure_folder, format("string{}_t0.pdf", string_number))
    τ_pdf           = joinpath(string_cuts_figure_folder, format("string{}_tau.pdf", string_number))

    tmp_pdf        = joinpath(string_cuts_figure_folder, format("string{}_tmp.pdf", string_number))

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

    for p in τ_plots
        plot(p, size=(1000, 800), ylabel="Counts", framestyle=:box, margin=10mm, xtickfontsize=font_size, ytickfontsize=font_size, xguidefontsize=font_size, yguidefontsize=font_size, legendfontsize=font_size)
        savefig(tmp_pdf)
        append_pdf!(string(τ_pdf), string(tmp_pdf), cleanup=true)
    end

    # break

end

# energy and current plots
for (string_number, string_channel_list) in string_dict

    printfmtln("Processing string number: {}", string_number)
    println()
    println()
    println("Check figure folder")
    string_cuts_figure_folder = joinpath(cuts_figure_folder, format("string{}", string_number))
    checkFolder(PosixPath(string_cuts_figure_folder), true)
    println()
    println()


    e_trap_plots = repeat([plot(1)], length(string_channel_list))
    a_plots = repeat([plot(1)], length(string_channel_list))


    for (i, ch) in enumerate(string_channel_list)
        label_ext = label_list_ext[ch]

        e_trap_ch      = data_dsp[ch].e_trap
        a_ch           = data_dsp[ch].a

        printfmtln("Channel: {}", ch)
        printfmtln("Number of events: {}", length(e_trap_ch))

        if length(qc_cuts_dict[ch].e_trap_cut) == 0
            cut_low = 100
            append!(qc_cuts_dict[ch].e_trap_cut, (e_trap_ch .> cut_low))
            e_trap_cut_dict[ch] = [cut_low, 0.0]

            cut_low = 0
            append!(qc_cuts_dict[ch].a_cut, (a_ch .> cut_low))
            a_cut_dict[ch] = [cut_low, 0.0]
        end


        nbins = 10000
        qc_cuts_ch = qc_cuts_dict[ch]
        qc_ch = ones(Bool, length(qc_cuts_ch.blmeancut))
        for (col, name) in zip(columns(qc_cuts_ch), columnnames(qc_cuts_ch))
            if name != :timestamp && name != :eventID_fadc
                printfmt("Merge {} cut", name)
                println()
                qc_ch .= qc_ch .& col
            end
        end

        e_trap_plots[i] = stephist(e_trap_ch, label="Energy Trap FTP", normalize=:pdf, nbins=nbins, yscale=:log10)
        try 
            stephist!(e_trap_ch[qc_ch], label="Energy Trap FTP after QC", title="Channel $ch ($label_ext)", xlim=(zero(e_trap_ch[1]), 25000), normalize=:pdf, nbins=nbins, yscale=:log10)
        catch e 
            println("Error: ", e)
            println("No spectrum after QC in channel $ch")
        end
        # break
        println()
    end

    font_size = 14

    e_trap_pdf     = joinpath(string_cuts_figure_folder, format("string{}_e_trap.pdf", string_number))

    tmp_pdf        = joinpath(cuts_figure_folder, format("string{}", string_number), format("string{}_tmp.pdf", string_number))

    for p in e_trap_plots
        plot(p, size=(1000, 800), ylabel="Counts", framestyle=:box, margin=10mm, xtickfontsize=font_size, ytickfontsize=font_size, xguidefontsize=font_size, yguidefontsize=font_size, legendfontsize=font_size)
        savefig(tmp_pdf)
        append_pdf!(string(e_trap_pdf), string(tmp_pdf), cleanup=true)
    end
    # break

end
# current()

for (string_number, string_channel_list) in string_dict

    printfmtln("Processing string number: {}", string_number)
    println()
    println()
    println("Check figure folder")
    string_cuts_figure_folder = joinpath(cuts_figure_folder, format("string{}", string_number))
    checkFolder(PosixPath(string_cuts_figure_folder), true)
    println()
    println()

    blmean_2D_plots = repeat([plot(1)], length(string_channel_list))
    blstd_2D_plots = repeat([plot(1)], length(string_channel_list))
    blslope_2D_plots = repeat([plot(1)], length(string_channel_list))

    for (i, ch) in enumerate(string_channel_list)
        label_ext = label_list_ext[ch]

        blmean_ch     = data_dsp[ch].blmean
        blstd_ch      = data_dsp[ch].blsigma
        blslope_ch    = data_dsp[ch].blslope
        timestamps_ch = data_dsp[ch].timestamp .- data_dsp[ch].timestamp[1]

        printfmtln("Channel: {}", ch)
        printfmtln("Number of events: {}", length(blmean_ch))
        printfmtln("Median of baseline mean: {}",  median(blmean_ch))
        printfmtln("Median of baseline std: {}",   median(blstd_ch))
        printfmtln("Median of baseline slope: {}", median(blslope_ch))

        # Mean
        xlim_factor = 1
        # blmean_2D_plots[i] = histogram2d(timestamps_ch/unit(timestamps_ch[1]), blmean_ch, nbins=(500, 5000), ylim=(median(blmean_ch)-1000, median(blmean_ch)+1000), title=format("Channel g{:>03d}", ch), color=:plasma, ylabel="Baseline Mean [ADC]", show_empty_bins=true)#, xlim=(timestamps_ch[1], timestamps_ch[end]))
        blmean_2D_plots[i] = histogram2d(uconvert.(u"minute", timestamps_ch), blmean_ch, nbins=(150, 5000), ylim=(median(blmean_ch)-1000, median(blmean_ch)+1000), title="Channel $ch ($label_ext)", color=cgrad(:linear_worb_100_25_c53_n256, scale=:log), ylabel="Baseline Mean [ADC]", show_empty_bins=true, dpi=100)#, xlim=(timestamps_ch[1], timestamps_ch[end]))

        # Std
        # blstd_2D_plots[i] = histogram2d(timestamps_ch/unit(timestamps_ch[1]), blstd_ch, nbins=(500, 5000), ylim=(median(blstd_ch)-1000, median(blstd_ch)+1000), title=format("Channel g{:>03d}", ch), color=:plasma, ylabel="Baseline Std [ADC]", show_empty_bins=true)#, xlim=(timestamps_ch[1], timestamps_ch[end]))
        blstd_2D_plots[i] = histogram2d(uconvert.(u"minute", timestamps_ch), blstd_ch, nbins=(150, 5000), ylim=(0, median(blstd_ch)+50), title="Channel $ch ($label_ext)", color=cgrad(:linear_worb_100_25_c53_n256, scale=:log), ylabel="Baseline Std [ADC]", show_empty_bins=true, dpi=100)#, xlim=(timestamps_ch[1], timestamps_ch[end]))

        # Slope
        # blslope_2D_plots[i] = histogram2d(timestamps_ch/unit(timestamps_ch[1]), blslope_ch, nbins=(500, 5000), ylim=(median(blslope_ch)-1000, median(blslope_ch)+1000), title=format("Channel g{:>03d}", ch), color=:plasma, ylabel="Baseline Slope [ADC]", show_empty_bins=true)#, xlim=(timestamps_ch[1], timestamps_ch[end]))
        blslope_2D_plots[i] = histogram2d(uconvert.(u"minute", timestamps_ch), blslope_ch, nbins=(150, 5000), title="Channel $ch ($label_ext)", color=cgrad(:linear_worb_100_25_c53_n256, scale=:log), ylabel="Baseline Slope [ADC]", show_empty_bins=true, dpi=100)#, xlim=(timestamps_ch[1], timestamps_ch[end]))


        # break
        println()
    end

    font_size = 14

    blmean_2D_pdf   = joinpath(string_cuts_figure_folder, format("string{}_blmean-time.pdf", string_number))
    blstd_2D_pdf    = joinpath(string_cuts_figure_folder, format("string{}_blstd-time.pdf", string_number))
    blslope_2D_pdf  = joinpath(string_cuts_figure_folder, format("string{}_blslope-time.pdf", string_number))

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

# # Save cuts
folder_cuts = folder_dict["folder_cuts"]
checkFolder(PosixPath(folder_cuts), true)

outfile_cuts = joinpath(folder_cuts, format("{}-p{:02d}-r{:03d}-cal-tier_cuts.lh5", experiment, period, calrun))
outdata_cuts = LHDataStore(outfile_cuts, "cw")

for ch in channel_list
    print("QC cut channel $ch")
    qc_cuts_ch = qc_cuts_dict[ch]
    qc_ch = ones(Bool, length(qc_cuts_ch.blmeancut))
    for (col, name) in zip(columns(qc_cuts_ch), columnnames(qc_cuts_ch))
        if name != :timestamp && name != :eventID_fadc
            printfmt("Merge {} cut", name)
            println()
            qc_ch .= qc_ch .& col
        end
    end
    qc_cuts_dict[ch] = TypedTables.Table(qc_cuts_ch; qc = qc_ch)
    outdata_cuts[ch] = qc_cuts_dict[ch]
    printfmtln("QC Surrival fraction: {:.2f}%", count(qc_cuts_dict[ch].qc)/length(qc_cuts_dict[ch].qc)*100)
    println()
end
close(outdata_cuts)

# # Save energy and A value after cuts
println("Save energy and A value after cuts")
folder_hit = folder_dict["folder_hit"]
checkFolder(PosixPath(folder_hit), true)

outfile_hit = joinpath(folder_hit, format("{}-p{:02d}-r{:03d}-cal-tier_hit.lh5", experiment, period, calrun))
outdata_hit = LHDataStore(outfile_hit, "cw")

for ch in channel_list
    e_trap_ch      = data_dsp[ch].e_trap
    a_ch           = data_dsp[ch].a
    qc_ch          = qc_cuts_dict[ch].qc
    
    out_t = TypedTables.Table(e = e_trap_ch[qc_ch], a = a_ch[qc_ch])
    
    outdata_hit[ch] = out_t
end
close(outdata_hit)

println()
println()
println()
println("Finished cuts for period $period, calrun $calrun")
