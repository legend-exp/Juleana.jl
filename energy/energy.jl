include("../utils/packages.jl")
include("../utils/loader.jl")
include("../utils/saver.jl")

config_folder = "/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts/configs/"

stringsToLoad = [1]
period, run, preName, cal = 1, 25, "l60", true
dsp_folder, hit_folder, cut_folder, figure_folder, string_numbers, data_strings, qc_cuts = prepareHit(config_folder, period=period, run=run, preName=preName, cal=cal, stringsToLoad=stringsToLoad)

string_number = 1
dsp_data, channel_list, label_listExt, label_list = data_strings[string_number]
qc_cuts_strings = qc_cuts[string_number]

printfmtln("Processing string number: {}", string_number)
println()
println()



# Define fit funtions
const MaybeWithUnits{T<:Number} = Union{T,Quantity{<:T}}
const RealQuantity = MaybeWithUnits{<:Real}

struct RadfordPeakShape{T <: RealQuantity} <: RadiationSpectra.UvSpectrumDensity{T}
    area::T
    σ::T
    μ::T
    stepAmplitude::T
    skewWidth::T
    skewFraction::T
    bkgSlope::T
    bkgIntercept::T
end

function skewedGauss(x, μ::T, σ::T, skew::T) where {T <: RealQuantity}
    return exp.((x .- μ) ./ skew .+ σ.^2 ./ (2 * skew^2) ) .* erfc.((x .- μ) ./ (√2 *  σ) .+ σ ./ (√2 * skew)) ./ (2 * skew)
end

function stepWithSigma(x, μ::T, σ::T) where {T <: RealQuantity}
    return 0.5 .* erfc.((x .- μ) ./ (σ * √2))
end

function gauss(x, μ::T, σ::T) where {T <: RealQuantity}
    return exp.(-0.5 .* ((x .- μ) ./ σ).^2) ./ (σ * √(2π))
end
    
function RadiationSpectra.evaluate(peak::RadfordPeakShape, x)
    area, σ, μ, stepAmplitude, skewWidth, skewFraction, bkgSlope, bkgIntercept = peak.area, peak.σ, peak.μ, peak.stepAmplitude, peak.skewWidth, peak.skewFraction, peak.bkgSlope, peak.bkgIntercept
    skew = skewWidth * μ
    return (area - area * skewFraction) .* gauss(x, μ, σ) .+ (area * skewFraction) .* skewedGauss(x, μ, σ, skew) .+ stepAmplitude .* stepWithSigma(x, μ, σ) .+ bkgSlope .* (x - μ) .+ bkgIntercept
end

function RadfordPeakShape(nt::NamedTuple{(:A, :σ, :μ, :stepAmplitude, :skewWidth, :skewFraction, :bkgSlope, :bkgIntercept)})
    T = promote_type(typeof.(values(nt))...)
    return RadfordPeakShape(T(nt.A), T(nt.σ), T(nt.μ), T(nt.stepAmplitude), T(nt.skewWidth), T(nt.skewFraction), T(nt.bkgSlope), T(nt.bkgIntercept))
end

function RadfordPeakShape_FWHM(x::AbstractArray{T}, area::T, μ::T, σ::T, stepAmplitude::T, skewFraction::T, bkgSlope::T, bkgIntercept::T) where {T <: RealQuantity}
    return (area - area * skewFraction) .* gauss(x, μ, σ) .+ stepAmplitude .* stepWithSigma(x, μ, σ) .+ bkgSlope .* (x - μ) .+ bkgIntercept
end

e_10410_plots = repeat([plot(1)], length(channel_list))
e_10410_FEP_plots = repeat([plot(1)], length(channel_list))
e_10210_plots = repeat([plot(1)], length(channel_list))
e_848_plots   = repeat([plot(1)], length(channel_list))
e_434_plots   = repeat([plot(1)], length(channel_list))


for (i, ch) in enumerate(channel_list)
    e_10410_ch = dsp_data[ch].e_10410[qc_cuts[ch].qc]
    e_10210_ch = dsp_data[ch].e_10210[qc_cuts[ch].qc]
    e_848_ch   = dsp_data[ch].e_848[qc_cuts[ch].qc]
    e_434_ch   = dsp_data[ch].e_434[qc_cuts[ch].qc]

    printfmtln("Channel: {}", ch)
    printfmtln("Number of events: {}", length(e_10410_ch))
    println()

    nbins = 10000
    e_10410_plots[i] = stephist(e_10410_ch, bins=nbins, label=label_listExt[i], xlabel="Energy [ADC]", ylabel="Counts", title="Energy spectrum", yaxis=:log)#, density=:pdf)
    # stephist!(dsp_data[ch].e_10410, bins=nbins, label="No QC", xlabel="Energy [ADC]", ylabel="Counts", yaxis=:log)
    xlims!(10, 25000)

    # println(length(e_10410_ch[e_10410_ch .> 0]))

    hist_10410_uncal = fit(Histogram, e_10410_ch[e_10410_ch .> 0], nbins=nbins)

    hist_10410_decon, hist_10410_peak_pos = RadiationSpectra.peakfinder(hist_10410_uncal)
    plot!(hist_10410_peak_pos, st=:vline, c=:green, label="Peaks found", lw=0.3)

    plot_label = true
    bin_width_factor = 30
    for (j, peak_pos) in enumerate(hist_10410_peak_pos)
        if peak_pos < 100
            continue
        end
        println("Fit peak position: ", peak_pos)

        peak_bin_idx = StatsBase.binindex(hist_10410_uncal, peak_pos)
        peak_bin_width = StatsBase.binvolume(hist_10410_uncal, peak_bin_idx)
        peak_bin_amplitude = hist_10410_uncal.weights[peak_bin_idx]

        h_sub = RadiationSpectra.subhist(hist_10410_uncal, (peak_pos - peak_bin_width * bin_width_factor, peak_pos + peak_bin_width * bin_width_factor))



        p0 = (A = peak_bin_amplitude, σ = peak_bin_width, μ = peak_pos, skewWidth = peak_bin_width, skewAmplitude = peak_bin_amplitude, skewFraction = 0.1)
        lower_bounds = (A = 1.0, σ = 0.1, μ = peak_pos - peak_bin_width * 20, skewWidth = 0, skewAmplitude = 0, skewFraction = 0)
        upper_bounds = (A = 1000000, σ = 1000000.0, μ = peak_pos + peak_bin_width * 20, skewWidth = 10000.0, skewAmplitude = 100000.0, skewFraction = 0.3)
        
        # println(p0)
        # println(lower_bounds)
        # println(upper_bounds)
        
        # global p0_test = p0
        # global h_fep_test = h_sub
        
        fitted_dens, backend_result = fit(RadfordPeakShape, h_sub, p0, lower_bounds, upper_bounds)
        
        # global fitted_dens_test = fitted_dens
        # break
        # println(fitted_dens)
        if plot_label
            plot!(e_10410_plots[i], fitted_dens, h_sub, c=:red, lw=1.5, label="Fitted peak", yaxis=:log)
            e_10410_FEP_plots[i] = plot(h_sub, st=:step, yaxis=:log)
            plot!(e_10410_FEP_plots[i], fitted_dens, h_sub, c=:red, lw=1.5, label="Fitted peak", yaxis=:log)
            println(backend_result)
            global backend_result_test = backend_result
            global fitted_dens_test = fitted_dens
            plot_label = false
            continue
        end
        plot!(e_10410_plots[i], fitted_dens, h_sub, c=:red, lw=1.5, yaxis=:log, label="")
        println("Fitted peak position: ", fitted_dens.μ)
    end

    # e_10210_plots[i] = stephist(e_10210_ch, bins=3000, label=label_listExt[i], xlabel="Energy [ADC]", ylabel="Counts", yaxis=:log)
    # stephist!(dsp_data[ch].e_10410, bins=3000, label="No QC", xlabel="Energy [ADC]", ylabel="Counts", title="Energy spectrum", yaxis=:log)
    # xlims!(0, 25000)
    
    # e_848_plots[i]   = stephist(e_848_ch, bins=3000, label=label_listExt[i], xlabel="Energy [ADC]", ylabel="Counts", title="Energy spectrum", yaxis=:log)
    # stephist!(dsp_data[ch].e_10410, bins=3000, label="No QC", xlabel="Energy [ADC]", ylabel="Counts", title="Energy spectrum", yaxis=:log)
    # xlims!(0, 25000)
    
    # e_434_plots[i]   = stephist(e_434_ch, bins=3000, label=label_listExt[i], xlabel="Energy [ADC]", ylabel="Counts", title="Energy spectrum", yaxis=:log)
    # stephist!(dsp_data[ch].e_10410, bins=3000, label="No QC", xlabel="Energy [ADC]", ylabel="Counts", title="Energy spectrum", yaxis=:log)
    # xlims!(0, 25000)

end

plot(e_10410_plots..., layout=(length(channel_list), 1), size=(1000, 3000), framestyle=:box, leftmargin=25mm, xtickfontsize=8, ytickfontsize=8, xguidefontsize=12, yguidefontsize=12, legendfontsize=10, fmt=:pdf)
ylims!(1, 100000)
xlims!(4e3, 5e3)
plot(e_10210_plots..., layout=(length(channel_list), 1), size=(1000, 3000))
plot(e_848_plots..., layout=(length(channel_list), 1), size=(1000, 3000))
plot(e_434_plots..., layout=(length(channel_list), 1), size=(1000, 3000))
plot(e_10410_FEP_plots..., layout=(length(channel_list), 1), size=(1000, 3000), framestyle=:box, leftmargin=25mm, xtickfontsize=8, ytickfontsize=8, xguidefontsize=12, yguidefontsize=12, legendfontsize=10, fmt=:pdf)


# tests for channel 34
plotlyjs()
ch = 34
# histograms_folder = "/remote/ceph2/group/legendex/data/l60/r025/julia/cal/histograms/"
# outfilename = joinpath(histograms_folder, "energy_histograms.h5")
# out_data = LHDataStore(string(outfilename), "cw")

# for ch in channel_list
#     e_10410_ch = dsp_data[ch].e_10410[qc_cuts_strings[ch].qc .&& dsp_data[ch].e_10410 .> 0.0]
#     out_data[string(ch)] = e_10410_ch
# end
# close(out_data)

e_10410_ch = dsp_data[ch].e_10410[qc_cuts_strings[ch].qc .&& dsp_data[ch].e_10410 .> 0.0]
# e_10210_ch = dsp_data[ch].e_10210[qc_cuts_strings[ch].qc .&& dsp_data[ch].e_10210 .> 0.0]
# e_848_ch   = dsp_data[ch].e_848[qc_cuts_strings[ch].qc .&& dsp_data[ch].e_848 .> 0.0]
# e_434_ch   = dsp_data[ch].e_434[qc_cuts_strings[ch].qc .&& dsp_data[ch].e_434 .> 0.0]


printfmtln("Channel: {}", ch)
printfmtln("Number of events: {}", length(e_10410_ch))
println()

nbins = 5000
hist_10410_uncal = fit(Histogram, e_10410_ch, nbins=nbins)

hist_10410_decon, hist_10410_peak_pos = RadiationSpectra.peakfinder(hist_10410_uncal, σ=10, threshold=1)

hist_10410_plot = vline(hist_10410_peak_pos, c=:red, label="Peaks found", lw=1.5, alpha=0.3)

# stephist!(e_10410_ch, bins=nbins, label=label_listExt[1], xlabel="Energy [ADC]", ylabel="Counts", title="Energy spectrum", yaxis=:log, color=:lightblue)
plot!(hist_10410_uncal.edges[1][1:end-1], log10.(hist_10410_uncal.weights), label=label_listExt[1], xlabel="Energy [ADC]", ylabel="Counts", title="Energy spectrum", color=:lightblue)

xlims!(10, 25000)
xticks!((0:2500:25000, ["$i" for i in 0:2500:25000]))
plot!(yscale=:normal, minorgrid=true, gridalpha=0.5, gridcolor=:grey, legend=:topright, fmt=:pdf)

# vline!(hist_10410_peak_pos, c=:red, label="Peaks found", lw=2.5)
# vspan!([hist_10410_peak_pos[1] - 10, hist_10410_peak_pos[1] + 10], c=:red, label="Peaks found", lw=2.5)
# println(length(e_10410_ch[e_10410_ch .> 0]))


bin_width_factor = 30
peak_fits_ch = repeat([plot(1)], length(hist_10410_peak_pos))

for (j, peak_pos) in enumerate(hist_10410_peak_pos)
    if peak_pos < 100
        continue
    end
    println("Fit peak position: ", peak_pos)

    peak_bin_idx = StatsBase.binindex(hist_10410_uncal, peak_pos)
    peak_bin_width = StatsBase.binvolume(hist_10410_uncal, peak_bin_idx)
    peak_bin_amplitude = hist_10410_uncal.weights[peak_bin_idx]

    h_sub = RadiationSpectra.subhist(hist_10410_uncal, (peak_pos - peak_bin_width * bin_width_factor, peak_pos + peak_bin_width * bin_width_factor))

    p0 = (A = peak_bin_amplitude, σ = peak_bin_width, μ = peak_pos, stepAmplitude = peak_bin_amplitude, skewWidth = peak_bin_width, skewFraction = 0.05, bkgSlope=1e-9, bkgIntercept=mean(h_sub.weights[1:10]))
    lower_bounds = (A = 1.0, σ = 0.1, μ = peak_pos - peak_bin_width * 1.5, stepAmplitude = 0.0, skewWidth = 0.0, skewFraction = 0.0, bkgSlope=0.0, bkgIntercept=0.0)
    upper_bounds = (A = 100*peak_bin_amplitude, σ = 50.0, μ = peak_pos + peak_bin_width * 1.5, stepAmplitude = 50*peak_bin_amplitude, skewWidth = 50.0, skewFraction = 0.5, bkgSlope=100, bkgIntercept=maximum(h_sub.weights))
    
    # println(p0)
    # println(RadfordPeakShape(p0))
    fitted_dens, backend_result = fit(RadfordPeakShape, h_sub, p0, lower_bounds, upper_bounds)
    
    peak_fits_ch[j] = plot(h_sub, st=:step, yaxis=:log)
    plot!(peak_fits_ch[j], fitted_dens, h_sub, c=:red, lw=1.5, label=format("Fitted peak {:.2f}", fitted_dens.μ), yaxis=:log)
    println("Fitted peak position: ", fitted_dens.μ)
    println(p0)
    println(fitted_dens)
    println()
end

plot(peak_fits_ch..., layout=(length(hist_10410_peak_pos), 1), size=(1000, 3000), framestyle=:box, leftmargin=25mm, xtickfontsize=8, ytickfontsize=8, xguidefontsize=12, yguidefontsize=12, legendfontsize=10, fmt=:pdf)
ylims!(1e1, 1e4)


# using BAT, ValueShapes, Distributions, InverseFunctions

# prior = NamedTupleDist(
#     A = Weibull(3, 5),
#     μ = Uniform(500, 660),
#     σ = Weibull(10, 5)
# )

# # Dummy likelihood
# log_likelihood(pars) = pars.A + pars.μ + pars.σ

# f_trafo = BAT.DistributionTransform(Normal, prior)

# init_pars = rand(prior)

# Optim.optimize(log_likelihood ∘ inverse(f_trafo), f_trafo(init_pars))