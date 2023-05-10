include("../utils/packages.jl")
include("../utils/loader.jl")
include("../utils/saver.jl")

is_cal = true
period = 2
calrun = 20
config_folder = p"/home/iwsatlas1/henkes/l200/l200-p02-analysis/configs/"
experiment = "l200"
println("Start Optimization for $experiment, period $period, run $calrun")
println("Loading meta data")

channel_list, label_dict, label_list_ext, string_dict, folder_dict = loadMeta(config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)

optimization_figure_folder = joinpath(folder_dict["folder_figures"], "optimization")
checkFolder(PosixPath(optimization_figure_folder), true)

# load decay times for PZ correction
decay_times = loadValues(collect(values(label_dict)), "tau", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)

# dict to save values
trap_rt_dict, trap_ft_dict = Dict{String, Any}(), Dict{String, Any}()

# global variables
enc_pickoff_trap = 32u"µs"
bl_mean_min, bl_mean_max = 0u"µs", 39u"µs"
pz_fit_min, pz_fit_max = 80u"µs", 110u"µs"
t0_threshold = 5.0

e_grid_rt_trap = 7u"µs":0.1u"µs":12u"µs"
e_grid_ft_trap = 1u"µs":0.2u"µs":4u"µs"

# use fixed window around 0 for all fits
max_enc = 10

# number bins, gamma lines and window size for cailbrations
n_bins = 600
th228_lines = [2614.50]
window_size = 20.0

println()

function processRT(wvfs_ch, τ, ft=4.0u"µs")
    # get baseline mean, std and slope
    bl_stats = signalstats.(wvfs_ch, bl_mean_min, bl_mean_max)

    # substract baseline from waveforms
    wvfs_ch = shift_waveform.(wvfs_ch, -bl_stats.mean)

    # deconvolute waveform
    deconv_flt = InvCRFilter(τ)
    wvfs_ch_pz = deconv_flt.(wvfs_ch)

    # t0 determination
    # filter with fast asymetric trapezoidal filter and truncate waveform
    uflt_asy_t0 = TrapezoidalChargeFilter(40u"ns", 100u"ns", 2000u"ns")
    uflt_trunc_t0 = TruncateFilter(0u"µs"..60u"µs")


    # eventuell zwei schritte!!!
    wvfs_flt_asy_t0 = uflt_asy_t0.(uflt_trunc_t0.(wvfs_ch_pz))

    # get intersect at t0 threshold (fixed as in MJD analysis)
    flt_intersec_t0 = Intersect(mintot = 600u"ns")

    # get t0 for every waveform as pick-off at fixed threshold
    t0 = uconvert.(u"µs", flt_intersec_t0.(wvfs_flt_asy_t0, t0_threshold).x)

    # truncate waveform for ENC filtering
    uflt_trunc_enc = TruncateFilter(0u"µs"..40u"µs")
    wvfs_ch_pz_trunc = uflt_trunc_enc.(wvfs_ch_pz)

    # get energy grid for efficient optimization
    enc_trap_grid = zeros(Float32, length(e_grid_rt_trap), length(wvfs_ch_pz))
    for (r, rt) in enumerate(e_grid_rt_trap)
        if rt < ft
            continue
        end
        uflt_rtft      = TrapezoidalChargeFilter(rt, ft)
        
        wvfs_flt_rtft  = uflt_rtft.(wvfs_ch_pz_trunc)

        enc_rtft       = SignalEstimator(PolynomialDNI(4, 80u"ns")).(wvfs_flt_rtft, enc_pickoff_trap)

        enc_trap_grid[r, :]   = enc_rtft
    end

    return enc_trap_grid
end


function processFT(wvfs_ch, τ, rt=12.0u"µs")
    # get baseline mean, std and slope
    bl_stats = signalstats.(wvfs_ch, bl_mean_min, bl_mean_max)

    # substract baseline from waveforms
    wvfs_ch = shift_waveform.(wvfs_ch, -bl_stats.mean)

    # deconvolute waveform
    deconv_flt = InvCRFilter(τ)
    wvfs_ch_pz = deconv_flt.(wvfs_ch)

    # t0 determination
    # filter with fast asymetric trapezoidal filter and truncate waveform
    uflt_asy_t0 = TrapezoidalChargeFilter(40u"ns", 100u"ns", 2000u"ns")
    uflt_trunc_t0 = TruncateFilter(0u"µs"..60u"µs")


    # eventuell zwei schritte!!!
    wvfs_flt_asy_t0 = uflt_asy_t0.(uflt_trunc_t0.(wvfs_ch_pz))

    # get intersect at t0 threshold (fixed as in MJD analysis)
    flt_intersec_t0 = Intersect(mintot = 600u"ns")

    # get t0 for every waveform as pick-off at fixed threshold
    t0 = uconvert.(u"µs", flt_intersec_t0.(wvfs_flt_asy_t0, t0_threshold).x)

    # get energy grid for efficient optimization
    e_grid   = zeros(Float32, length(e_grid_ft_trap), length(wvfs_ch_pz))
    for (f, ft) in enumerate(e_grid_ft_trap)
        if rt < ft
            continue
        end
        uflt_rtft      = TrapezoidalChargeFilter(rt, ft)
        
        wvfs_flt_rtft  = uflt_rtft.(wvfs_ch_pz)

        e_rtft         = SignalEstimator(PolynomialDNI(4, 80u"ns")).(wvfs_flt_rtft, t0 .+ (rt + ft/2))

        e_grid[f, :]     = e_rtft
    end

    return e_grid
end

println("Rise Time Optimization")
println()
println()
println()
# ch = channel_list[1]
for ch in channel_list

    label_ext = label_list_ext[ch]
    println("Processing channel $ch")
    println()
    println("Load data")
    filename = joinpath(folder_dict["folder_peaks"], format("{}-p{:02d}-r{:03d}-cal-{}-tier_peaks.lh5", experiment, period, calrun, ch))
    data_ch = LHDataStore(filename, "r")

    peaks_ch = data_ch["$ch/Tl208a"][:]
    # append!(peaks_ch, data_ch["$ch/Tl208dFEP"][:])

    wvfs_ch = peaks_ch.waveform

    τ = decay_times[label_dict[ch]]u"µs"

    println("Generate grid")
    enc_trap_grid = processRT(wvfs_ch, τ)


    println("Optimization Rise Time of Trap filter")

    # rt_variation_plots = Plots.Plot[]
    rt_enc_sigma = zeros(length(e_grid_rt_trap))

    for (r, rt) in enumerate(e_grid_rt_trap)
        # println("Risetime $rt")

        enc_rt = flatview(enc_trap_grid)[r, :]

        d = fit(Normal, enc_rt[enc_rt .> -max_enc .&& enc_rt .< max_enc])

        # p = histogram(enc_rt[enc_rt .> -max_enc .&& enc_rt .< max_enc], normalize=:pdf, bins=1000, title="ENC RT $rt", legend=:topright, xlabel="ENC (ADC)", ylabel="Counts")
        # xlims!(-max_enc, max_enc)
        # plot!(Normal(d.μ, d.σ), label=format("ENC Fit (µ = {:.2f}, σ = {:.2f})", d.μ, d.σ), color="red", line_width=3.5)
        # plot!(legend=:bottomright)
        # push!(rt_variation_plots, p)

        rt_enc_sigma[r] = d.σ
    end

    # plot(rt_variation_plots..., legend=:none,
    # layout = @layout[grid(13, 8)], margin=0.1mm, framestyle=:box, label_margin=0mm,
    # grid=true, gridalpha=0.2, gridcolor=:black, gridlinewidth=0.5,
    # xlabelfontsize=8, xlabelmargin=0mm, ylabelfontsize=8, ylabelmargin=0mm, titlefontsize=8, xlabel="", figsize=(2000, 800))
    # savefig(joinpath(string_optimnization_figure_folder, format("allRT_variation_ch{}.pdf", ch)))

    min_enc = minimum(rt_enc_sigma[rt_enc_sigma .> 0])
    min_enc_rt = e_grid_rt_trap[rt_enc_sigma .> 0][findmin(rt_enc_sigma[rt_enc_sigma .> 0])[2]]

    scatter(e_grid_rt_trap[rt_enc_sigma .> 0], rt_enc_sigma[rt_enc_sigma .> 0], xlabel="Risetime", ylabel="ENC Noise (ADC)", label="ENC Noise", grid=true, gridalpha=0.2, gridcolor=:black, gridlinewidth=0.5)
    hline!([min_enc], label=format("Min. ENC Noise (RT: {})", min_enc_rt), color="red", line_width=5)
    plot!(title="Channel $ch ($label_ext)", legend=:topright)
    savefig(joinpath(optimization_figure_folder, format("{}_noisesweep_rt_enc.pdf", ch)))

    printfmtln("Found optimal rise time at {} with ENC {:.2f}ADC", min_enc_rt, min_enc)
    println()
    println()

    trap_rt_dict[label_dict[ch]] = min_enc_rt
end


# trap_rt_dict = loadValues(collect(values(label_dict)), "trap_rt", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
# trap_rt_dict = Dict{String, Any}(keys(trap_rt_dict) .=> values(trap_rt_dict).*1u"µs")

println("Flat-top time Optimization")

# ch = channel_list[1]
# label_ext = label_list_ext[ch]
# println("Processing channel $ch")
# println("Load data")
# filename = joinpath(folder_dict["folder_peaks"], format("{}-p{:02d}-r{:03d}-cal-{}-tier_peaks.lh5", experiment, period, calrun, ch))
# data_ch = LHDataStore(filename, "r")
# peaks_ch = data_ch["$ch/Tl208a"][:]
# wvfs_ch = peaks_ch.waveform

# τ = decay_times[label_dict[ch]]u"µs"

# println("Generate grid")
# e_trap_grid = processFT(wvfs_ch, τ, trap_rt_dict[label_dict[ch]])

# e_ft = Array(flatview(e_trap_grid)[10, :])
# e_ft = e_ft[.!isnan.(e_ft)]
# e_ft = e_ft[e_ft .> median(e_ft) - 100 .&& e_ft .< median(e_ft) + 100]

# histogram(e_ft, bins=n_bins)
# vline!([median(e_ft)])

# h_calsimple, h_uncal, c, fep_guess, peakhists, peakstats = simpleCalibration(e_ft, th228_lines, window_size=window_size, n_bins=n_bins, calib_type="th228")

for ch in channel_list
    label_ext = label_list_ext[ch]
    println("Processing channel $ch")
    println()
    println("Load data")
    filename = joinpath(folder_dict["folder_peaks"], format("{}-p{:02d}-r{:03d}-cal-{}-tier_peaks.lh5", experiment, period, calrun, ch))
    data_ch = LHDataStore(filename, "r")

    peaks_ch = data_ch["$ch/Tl208a"][:]
    # append!(peaks_ch, data_ch["$ch/Tl208dFEP"][:])

    wvfs_ch = peaks_ch.waveform

    τ = decay_times[label_dict[ch]]u"µs"

    println("Generate grid")
    e_trap_grid = processFT(wvfs_ch, τ, trap_rt_dict[label_dict[ch]])


    println("Optimization Flat-Top Time of Trap filter")
    ft_fwhm = zeros(length(e_grid_ft_trap))

    for (f, ft) in enumerate(e_grid_ft_trap)

        e_ft = Array(flatview(e_trap_grid)[f, :])
        e_ft = e_ft[.!isnan.(e_ft)]
        e_ft = e_ft[e_ft .> median(e_ft) - 100 .&& e_ft .< median(e_ft) + 100]

        h_calsimple, h_uncal, c, fep_guess, peakhists, peakstats = simpleCalibration(e_ft, th228_lines, window_size=window_size, n_bins=n_bins, calib_type="th228")

        try
            peak_fit_plots, peak_fit_vals = fitPeaks(peakhists, peakstats, th228_lines) 
            ft_fwhm[f] = peak_fit_vals[th228_lines[1]].fwhm
        catch e
            println("Error in fitting peaks")
            println(e)
            ft_fwhm[f] = 100.0
            continue
        end
    end

    if all(collect(values(ft_fwhm)) .== 100.0)
        println("No FWHM fit possible in $ch")
        printfmtln("Will use 2.0µs as default value for flat-top time")

        println()
        println()
        trap_ft_dict[label_dict[ch]] = 2.0u"µs"
        continue
    end

    min_fwhm = minimum(ft_fwhm[ft_fwhm .> 0])
    min_fwhm_ft = e_grid_ft_trap[ft_fwhm .> 0][findmin(ft_fwhm[ft_fwhm .> 0])[2]]

    scatter(e_grid_ft_trap[ft_fwhm .!= 100], ft_fwhm[ft_fwhm .!= 100], xlabel="Flat Top Time", ylabel="FWHM at 2.6 MeV FEP", label="FWHM", grid=true, gridalpha=0.2, gridcolor=:black, gridlinewidth=0.5)
    hline!([min_fwhm], label=format("Min. FWHM (FT: {})", min_fwhm_ft), color="red", line_width=5)
    ylims!(1, 8)
    plot!(title="Channel $ch ($label_ext)", legend=:topright)
    savefig(joinpath(optimization_figure_folder, format("{}_fwhm_FEP_ft.pdf", ch)))

    printfmtln("Found optimal flat top time at {} with FWHM at 2.6 MeV FEP of {:.2f}keV", min_fwhm_ft, min_fwhm)

    println()
    println()
    trap_ft_dict[label_dict[ch]] = min_fwhm_ft
end


println()
println()
println()
println("Finished energy optimization")
println()
println("Save best rise time values to metadata")
trap_rt_savedict = Dict{String, Float32}(keys(trap_rt_dict) .=> uconvert.(NoUnits, values(trap_rt_dict)./1u"µs"))
saveValues(trap_rt_savedict, "trap_rt", config_folder, period=period, run=calrun, experiment=experiment, cal=cal)

println("Save best flat-top time values to metadata")
trap_ft_savedict = Dict{String, Float32}(keys(trap_ft_dict) .=> uconvert.(NoUnits, values(trap_ft_dict)./1u"µs"))
saveValues(trap_ft_savedict, "trap_ft", config_folder, period=period, run=calrun, experiment=experiment, cal=cal)


