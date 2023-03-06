include("../utils/packages.jl")
include("../utils/loader.jl")
include("../utils/saver.jl")


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

plotlyjs()
ch = 34
histograms_folder = "/remote/ceph2/group/legendex/data/l60/r025/julia/cal/histograms/"
histograms_filename = joinpath(histograms_folder, "energy_histograms.h5")
data = LHDataStore(string(histograms_filename), "r")

energies = data[string(ch)]

nbins = 15000

hist_noCal = fit(Histogram, energies, nbins=nbins)
hist_decon, hist_peak_pos = RadiationSpectra.peakfinder(hist_noCal, σ=10, threshold=1)

plot(hist_noCal.edges[1][1:end-1], log10.(hist_noCal.weights), label="Channel $ch", xlabel="Energy [ADC]", ylabel="Counts", title="Energy spectrum", color=:blue, legend=:topright, xlims=(0, 25e3))
vline!(hist_peak_pos, c=:red, label="Peaks found", lw=1.5, alpha=0.3)
# plot(energies, bins=nbins, yscale=:log, label="Channel $ch", xlabel="Energy [ADC]", ylabel="Counts", title="Energy spectrum", color=:blue, legend=:topleft, xlims=(0, 25e3))
yticks!((1:5, ["10^$i" for i in 1:5]))
xticks!((0:2500:25000, ["$i" for i in 0:2500:25000]))

plot(hist_decon, st=:step, label="Channel $ch", xlabel="Energy [ADC]", ylabel="Counts", title="Energy spectrum", color=:blue, legend=:topright, xlims=(0, 25e3))
vline!(hist_peak_pos, c=:red, label="Peaks found", lw=1.5, alpha=0.3)
fep_guess = quantile(energies, 0.99)
vline!([fep_guess], c=:green, label="FEP guess", lw=2.5, alpha=0.7)
xticks!((0:2500:25000, ["$i" for i in 0:2500:25000]))

# Define Th-228 gamma lines
gamma_lines = [583.191, 727.330, 860.564, 1592.53, 1620.50, 2103.53, 2614.50]
fep_value = 2614.5

simple_calib = fep_value / fep_guess

function checkGammaLine(simple_calib::Float64, peak_pos::Array{Float64}, gamma_lines::Array{Float64}, max_dist::Int)
    is_line = convert.(Bool, zeros(length(peak_pos)))
    for (i, p) in enumerate(peak_pos)
        for gl in gamma_lines
            if abs(gl - p*simple_calib) < max_dist
                is_line[i] = true
                continue
            end
        end
    end
    return is_line
end

bin_width_factor = 20


fit_peak_pos = hist_peak_pos[checkGammaLine(simple_calib, hist_peak_pos, gamma_lines, 10)]

vline!(fit_peak_pos, c=:green, label="Fit guess", lw=1.5, alpha=0.7)

fit_peaks_plots = [plot(1, xlabel="Energy [ADC]", ylabel="Counts", title="Energy spectrum", legend=:topright) for i in 1:length(fit_peak_pos)]

for (i, peak_pos) in enumerate(fit_peak_pos)
    println("Fit peak position: ", peak_pos)

    peak_bin_idx = StatsBase.binindex(hist_noCal, peak_pos)
    peak_bin_width = StatsBase.binvolume(hist_noCal, peak_bin_idx)
    peak_bin_amplitude = hist_noCal.weights[peak_bin_idx]

    h_sub = RadiationSpectra.subhist(hist_noCal, (peak_pos - peak_bin_width * bin_width_factor, peak_pos + peak_bin_width * bin_width_factor))

    plot!(fit_peaks_plots[i], h_sub, st=:step, label="Channel $ch", xlabel="Energy [ADC]", ylabel="Counts", title="Energy spectrum", color=:blue, legend=:topright, xlims=(peak_pos - peak_bin_width * bin_width_factor, peak_pos + peak_bin_width * bin_width_factor))
    vline!(fit_peaks_plots[i], [peak_pos], c=:red, label="mu guess", lw=1.5, alpha=0.3)

    p0 = (A = peak_bin_amplitude*peak_bin_width/2, σ = peak_bin_width, μ = peak_pos, stepAmplitude = 1e-6, skewWidth = peak_bin_width, skewFraction = 0.05, bkgSlope=1e-3, bkgIntercept=mean(h_sub.weights[1:5])/2)
    plot!(fit_peaks_plots[i], RadfordPeakShape(p0), h_sub, label="Initial guess")

    lower_bounds = (A = 1.0, σ = peak_bin_width*0.2, μ = peak_pos - peak_bin_width * 1.5, stepAmplitude = 0.0, skewWidth = 0.0, skewFraction = 0.0, bkgSlope=0.0, bkgIntercept=0.0)
    upper_bounds = (A = 100*peak_bin_amplitude, σ = peak_bin_width/0.8, μ = peak_pos + peak_bin_width * 1.5, stepAmplitude = 50*peak_bin_amplitude, skewWidth = 50.0, skewFraction = 0.5, bkgSlope=100, bkgIntercept=maximum(h_sub.weights))

    fitted_dens, backend_result = fit(RadfordPeakShape, h_sub, p0, lower_bounds, upper_bounds)

    plot!(fit_peaks_plots[i], fitted_dens, h_sub, c=:red, lw=1.5, label=format("Fitted peak {:.2f}", fitted_dens.μ))
    plot!(fit_peaks_plots[i], legend=:topright)
    println("Fitted peak position: ", fitted_dens.μ)
    println()
    println("P0")
    println(p0)
    println("Best Fit")
    println(fitted_dens)
    println()
    println()
end
plot(fit_peaks_plots..., layout=(3, 3), size=(1000, 1000), margin=2mm, framestyle=:box, legend=:none, titlefontsize=10, title="", xlabel="", yscale=:log)