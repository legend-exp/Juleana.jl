include("../utils/packages.jl")
include("../utils/loader.jl")
include("../utils/saver.jl")
include("../utils/utils.jl")

# global variables
enc_pickoff = 32u"µs"
bl_mean_min, bl_mean_max = 0u"µs", 39u"µs"
pz_fit_min, pz_fit_max = 80u"µs", 110u"µs"
t0_threshold = 5.0
# zac_filter_length = 30u"µs"

e_grid_rt = 7u"µs":0.5u"µs":12u"µs"
e_grid_ft = 1u"µs":0.2u"µs":4u"µs"


# function processChannel(wvfs_ch::RDWaveform, bl_fc::Vector, ts_ch::Array, evID_ch::Array, ch_ch::Array, efc_ch::Array, out_t::TypedTables.Table, τ::Float32)
function processChannel(wvfs_ch)
    # get baseline mean, std and slope
    bl_stats = signalstats.(wvfs_ch, bl_mean_min, bl_mean_max)

    # pretrace difference 
    pretrace_diff = flatview(wvfs_ch.signal)[1, :] - bl_stats.mean

    # substract baseline from waveforms
    wvfs_ch = shift_waveform.(wvfs_ch, -bl_stats.mean)

    # extract decay times
    decay_times_extracted = uconvert.(u"µs", tailstats.(wvfs_ch, pz_fit_min, pz_fit_max))

    return decay_times_extracted
end

cal = true
period = 2
calrun = 6
config_folder = p"/home/iwsatlas1/henkes/l200/l200-p02-analysis/configs/"
experiment = "l200"
println("Start Decay Time extraction for $experiment, period $period, run $calrun")
println("Loading meta data")

channel_list, label_dict, label_list_ext, string_dict, folder_dict = loadMeta(config_folder, period=period, run=calrun, experiment=experiment, cal=cal)

decay_time_figure_folder = joinpath(folder_dict["folder_figures"], "decay_time")
checkFolder(PosixPath(decay_time_figure_folder), true)
println("Using folder $decay_time_figure_folder for figures")

decay_times_dict = Dict{String, Float32}()


# ch = channel_list[1]
for ch in channel_list
    if ch != "ch039"
        continue
    end
    print("Processing channel $ch\n")
    label_ext = label_list_ext[ch]
    filename = joinpath(folder_dict["folder_peaks"], format("{}-p{:02d}-r{:03d}-cal-{}-tier_peaks.lh5", experiment, period, calrun, ch))
    data_ch = LHDataStore(filename, "r")

    fep_ch = data_ch["$ch/Tl208a"][:]

    wvfs_ch = fep_ch.waveform

    τ = processChannel(wvfs_ch)
    min_τ, max_τ = 200u"µs", 1000u"µs"
    nbins = 800
    rel_cut_fit = 0.5

    τ = τ[τ .> min_τ .&& τ .< max_τ]


    histogram(τ, bins=nbins, xrange=(min_τ, max_τ), label="Decay Times")
    xlim_factor, mean_cut_factor = 2, 0.2
    hists = fit(Histogram, uconvert.(NoUnits, τ./1u"µs"), nbins=nbins)
    cts_argmax = mapslices(argmax, hists.weights, dims=1)[1]
    cts_max = hists.weights[cts_argmax]

    cut_low_arg  = filter((x) -> hists.weights[x] < rel_cut_fit * cts_max, reverse(1:cts_argmax))[1]
    cut_high_arg = filter((x) -> hists.weights[x] < rel_cut_fit * cts_max, cts_argmax:length(hists.weights))[1]
    cut_low, cut_high = Array(hists.edges[1])[cut_low_arg], Array(hists.edges[1])[cut_high_arg]

    printfmtln("Decay Time Fit window: [{}, {}]", cut_low, cut_high)
    vline!([cut_low, cut_high], color=:red, lw=3, label="")
    vspan!([cut_low, cut_high], fillrange=cut_high, label="Cut window", color=:red, lw=1.5, alpha=0.2)

    τ_fit = τ[τ .> cut_low*1u"µs" .&& τ .< cut_high*1u"µs"]

    ps = (peak_pos = hists.edges[1][cts_argmax], peak_sigma = 15)

    pseudo_prior = NamedTupleDist(
        μ = Uniform(ps.peak_pos-20, ps.peak_pos+20),
        σ = weibull_from_mx(ps.peak_sigma, 3*ps.peak_sigma),
    )
    f_trafo = BAT.DistributionTransform(Normal, pseudo_prior)

    v_init = mean(pseudo_prior)

    f_loglike = let cut_low = cut_low, cut_high = cut_high, τ_fit = uconvert.(NoUnits, τ_fit./1u"µs")
        v -> (-1) * loglikelihood(truncated(Normal(v[1], v[2]), cut_low, cut_high), τ_fit)
    end
    opt_r = optimize(f_loglike ∘ inverse(f_trafo), f_trafo(v_init))
    μ, σ = inverse(f_trafo)(opt_r.minimizer)

    d = fit(Normal, uconvert.(NoUnits, τ_fit./1u"µs"))

    # histogram(τ_fit, bins=100, normalize=:pdf, xrange=(min_τ, max_τ), label="Decay Times")
    plot!(truncated(Normal(μ, σ), cut_low, cut_high)*sum(hists.weights[cut_low_arg:cut_high_arg]), label=format("Decay Time Fit (µ = {:.2f}, σ = {:.2f})", μ, σ), color="red", line_width=3.5)
    plot!(legend=:topright, ylabel="Counts", xlabel="Decay Time (µs)", title="$ch $label_ext")
    xlims!(uconvert(NoUnits, min_τ/1u"µs"), uconvert(NoUnits, max_τ/1u"µs"))
    xlims!(450, 500)
    savefig(joinpath(decay_time_figure_folder, format("{}_decay_time_fit.pdf", ch)))

    printfmtln("Found decay time at {:.2f} µs", μ)
    println()
    println()
    decay_times_dict[label_dict[ch]] = round(μ, digits=2)
end

println()
println()
println()
println("Finished decay time extraction")
println()
println("Save deacy time values to metadata")
# saveValues(decay_times_dict, "tau", config_folder, period=period, run=calrun, experiment=experiment, cal=cal)
