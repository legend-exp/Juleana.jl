using LegendDataManagement, PropertyFunctions, TypedTables, PropDicts
using Unitful, Formatting, LaTeXStrings, Measures
using Plots, StatsBase
using LegendHDF5IO, LegendDSP, LegendSpecFits
using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked

ENV["JULIA_DEBUG"] = Main # enable debug

gr()
plotlyjs()

@info "Loading Legend MetaData"
l200 = LegendData(:l200)

period = DataPeriod(3)
run    = DataRun(1)

@info "PSD calibration for period $period and run $run"

filekeys = sort(search_disk(FileKey, l200.tier[:raw, :cal, period, run]), by = x-> x.time)
filekey = filekeys[1]
@info "Found filekey $filekey"

chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable)

sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)

hit_folder = l200.tier[:hit, :cal, period, run]
@debug "Use Hit folder $hit_folder"

@debug "Create figures folder"
figures_folder = joinpath(l200.tier[:plt, :cal, period, run], "aoe")
ifelse(isdir(figures_folder), @debug("Figure folder $figures_folder already exists"), mkpath(figures_folder))

for str in unique(chinfo.string)
    figures_folder_string = joinpath(figures_folder, format("string{:02d}", str))
    ifelse(isdir(figures_folder_string), @debug("String Figure folder $figures_folder_string already exists"), mkpath(figures_folder_string))
end

@debug "Get calibration pars"
energy_pars_folder   =  joinpath(l200.tier[:par, :cal, period, run], "energy")
energy_pars_filename = format("{}-{}-{}-{}-energy.json", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category))
energy_pars          = readprops(joinpath(energy_pars_folder, energy_pars_filename))

@debug "Create pars folder"
pars_folder = joinpath(l200.tier[:par, :cal, period, run], "aoe")
ifelse(isdir(pars_folder), @debug("Pars folder $pars_folder already exists"), mkpath(pars_folder))

@debug "Create pars db"
pars_db = PropDict()


i = 2
# det = :V09372A
# findfirst(x -> x == det, chinfo.detector)
ch_short = chinfo.channel[i]
ch = format("ch{}", ch_short)
string_number = chinfo.string[i]
det = chinfo.detector[i]

figures_folder_string = joinpath(figures_folder, format("string{:02d}", string_number))

@debug "Processing channel $ch ($det)"

filename = joinpath(l200.tier[:qc, :cal, period, run], format("{}-{}-{}-{}-{}-tier_qc.lh5", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch))

if !isfile(filename)
    @warn "File $(basename(filename)) does not exist, skip"
end

data = LHDataStore(filename, "r")

@debug "Loading data from $(basename(filename))"
dsp_data = data["$ch/after_qc"][:]

if length(dsp_data) < 50000
    @warn "Not enough data points for channel $ch, skip"
end

if haskey(l200.metadata.dataprod.config.cal.energy(sel), det)
    energy_config = l200.metadata.dataprod.config.cal.energy(sel)[det]
    @debug "Use config for detector $det"
else
    energy_config = l200.metadata.dataprod.config.cal.energy(sel).default
    @debug "Use default config"
end

close(data)

m_calib, n_calib = energy_pars[det].m_calib, energy_pars[det].n_calib

e_trap = m_calib .* dsp_data.e_trap .+ n_calib
a      = dsp_data.a
aoe    = a ./ e_trap

plotlyjs()
stephist(e_trap, bins=0:0.5:3000, label="e_trap", legend=:topleft, yscale=:log10)

gr()
histogram2d(e_trap, aoe, nbins=(0:0.5:3000, 0.2:5e-4:0.8), xlims=(0, 3000), ylims=(0.2, 0.8), size=(1000, 600), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy (keV)", ylabel="A/E (a.u.)")


compton_bands = Vector{Float64}([520, 555, 590, 610, 630, 650, 670, 690, 
                735, 790, 810, 830, 865, 900, 930, 955,
                1000, 1020, 1040, 1130, 1150, 1170, 1190, 
                1210, 1250, 1270, 1290, 1310, 1330, 1420,
                1520, 1540, 1700, 1780, 1810, 1850, 1870,
                1890, 1910, 1930, 1950, 1970, 1990, 2010,
                2030, 2050, 2150])

compton_window = 20.0

# using StructArrays, BAT, Distributions, ValueShapes
# using InverseFunctions, Optim, LinearAlgebra


compton_band_peakhists = generate_aoe_compton_bands(aoe, e_trap, compton_bands, compton_window)

pars_aoe_simple = (μ = compton_band_peakhists.simple_pars_aoe_μ, μ_err=compton_band_peakhists.simple_pars_error_aoe_μ, σ = compton_band_peakhists.simple_pars_aoe_σ, σ_err = compton_band_peakhists.simple_pars_error_aoe_σ)
result, report = fit_aoe_compton(compton_band_peakhists.peakhists, compton_band_peakhists.peakstats, compton_bands; pars_aoe=pars_aoe_simple)


p = @animate for (band, report_band) in pairs(report) fps=2
    plot(report_band, title=format("{} A/E CC at $band keV ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
    xlims!(minimum(compton_band_peakhists.min_aoe), maximum(compton_band_peakhists.max_aoe))
end

gif(p, fps=2, joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-aoe_compton-bands.gif", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

μ = [result[band].μ for band in compton_bands]
σ = [result[band].σ for band in compton_bands]

aoe_corrections = fit_aoe_corrections(compton_bands, μ, σ)


scatter(aoe_corrections.e, aoe_corrections.μ, ms=5, color=:black, layout = @layout[grid(2, 1, heights=[0.8, 0.2])], xlabel=L"Energy\ (keV)", ylabel=L"\mu_{A/E} (a.u.)", label=L"\mu_{SCS}", xticks = (minimum(compton_bands):200:maximum(compton_bands)), xlims=(minimum(compton_bands)-50, maximum(compton_bands)+50))
plot!(ylims=(0.95*median(aoe_corrections.μ), 1.05*median(aoe_corrections.μ)), subplot=1, xlabel="", xticks = :none)
plot!(0.0:1500:3000, x -> aoe_corrections.f_μ_scs(x), label="Best Fit: $(round(aoe_corrections.μ_scs_intercept, digits=2)) + x*$(round(aoe_corrections.μ_scs_slope*1000, digits=2))e-3", line_width=3.5, color=:red, subplot=1, xformatter=_->"")
plot!(aoe_corrections.e, (aoe_corrections.f_μ_scs.(aoe_corrections.e) .- aoe_corrections.μ) ./ aoe_corrections.μ .* 100 , label="Residuals", ylabel="Residuals (%)", line_width=2, color=:black, st=:scatter, ylims = (-5.0, 5.0), markershape=:x, subplot=2)
plot!(legend = :topright, title=format(L"{}\ A/E\ \mu \ ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)), subplot=1)



scatter(aoe_corrections.e, aoe_corrections.σ, ms=5, color=:black, layout = @layout[grid(2, 1, heights=[0.8, 0.2])], xlabel=L"Energy\ (keV)", ylabel=L"\mu_{A/E} (a.u.)", label=L"\sigma_{SCS}", xticks = (minimum(compton_bands):200:maximum(compton_bands)), xlims = (minimum(compton_bands)-50, maximum(compton_bands)+50))
plot!(ylims=(0.5*aoe_corrections.f_σ_scs(maximum(compton_bands)), 2*aoe_corrections.f_σ_scs(minimum(compton_bands))), subplot=1, xlabel="", xticks = :none)
plot!(minimum(compton_bands)-50:0.1:maximum(compton_bands)+50, x -> aoe_corrections.f_σ_scs(x), label=format("Best Fit: {:.2E} + {:.2E}e^(-x/{:.2E})", aoe_corrections.σ_scs...), line_width=3.5, color=:red, subplot=1, xformatter=_->"")
plot!(aoe_corrections.e, (aoe_corrections.f_σ_scs.(aoe_corrections.e) .- aoe_corrections.σ) ./ aoe_corrections.σ .* 100 , label="Residuals", ylabel="Residuals (%)", line_width=2, color=:black, st=:scatter, ylims = (-20.0, 20.0), markershape=:x, subplot=2)
plot!(legend = :topright, title=format(L"{}\ A/E\ \sigma \ ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)), subplot=1)

correct_aoe!(aoe, e_trap, aoe_corrections)

gr()
histogram2d(e_trap, aoe, nbins=(0:0.5:3000, -20:0.1:10), xlims=(0, 3000), ylims=(-20, 10), size=(1000, 600), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel=L"Energy\ (keV)", ylabel=L"A/E (\sigma_{A/E})")

result = get_psd_cut(aoe, e_trap)

hline!([result.cut], color=:red, lw=3, label="PSD Cut")
xlims!(1550, 1650)

plotlyjs()
stephist(e_trap, bins=0:0.5:3000, label="e_trap", legend=:topleft, yscale=:log10)
stephist!(e_trap[aoe .> result.cut], bins=0:0.5:3000, label="e_trap after PSD", legend=:topleft, yscale=:log10)


psd_peaks       = [1592.53,    1620.50,    2103.53,    2614.51]
psd_windows     = [20.0,       25.0,       25.0,       35.0]
psd_peak_names_str = ["Tl208DEP", "Bi212FEP", "Tl208SEP", "Tl208FEP"]
psd_peak_names = Symbol.(psd_peak_names_str)

result_peaks, report_peaks = get_peaks_surrival_fractions(aoe, e_trap, psd_peaks, psd_peak_names, psd_windows, result.cut)

qbb_result = get_continuum_surrival_fraction(aoe, e_trap, 2039.0, 35.0, result.cut)

gr()
peak_sf_plot = plot.([rep.after for rep in values(report_peaks)], titleloc=:left, titlefont=font(8), ticks=:native,; show_label=true)
for (p, rep_before) in zip(peak_sf_plot, [rep.before for rep in values(report_peaks)])
    plot!(p, rep_before,; show_label=false)
end
for (p, peak_name, peak, res) in zip(peak_sf_plot, psd_peak_names, psd_peaks, values(result_peaks))
    xticks!(p, convert(Int, round(xlims(p)[1], digits=0)):20:convert(Int, round(xlims(p)[2], digits=0)))
    title!(p, format("{} ({} keV) - SF: {:.2f} ± {:.2f}%", string(peak_name), peak, res.sf*100, res.err.sf*100))
end
plot(
    peak_sf_plot...,
    layout = @layout[grid(2, 2)], 
    size=(2000, 1200), legend=:topright,
    framestyle=:box, label_margin=0,
    grid=true, minor=true, gridalpha=0.2, gridcolor=:black, gridlinewidth=0.5,
    xlabelfontsize=8, xlabelmargin=0,
    ylabelfontsize=8, ylabelmargin=0,
    xlabel="Energy (keV)", ylabel="Counts",
    dpi = 900, thickness_scaling = 2
)
plot(result_peak.after; )
plot!(result_peak.before; show_label=false)












dep_peakhist = get_dep_peakhists(aoe, e_trap)

plot(dep_peakhist.hist, st=:stepbins)

result, report = fit_single_peak_th228(dep_peakhist.hist, dep_peakhist.stats, uncertainty=false)

plot(report)

n90 = result.n * 0.9

using Roots

objective_f = cut -> get_n_after_psd_cut(cut, dep_peakhist.aoe, dep_peakhist.e, dep_peakhist.dep, dep_peakhist.window, uncertainty=false) - n90

plotlyjs()
plot(-20.0:0.1:0.0, x -> objective_f(x))

objective_f(20.0)
cut_interval = (-20.0, 0.0)
find_zero(objective_f, cut_interval, Bisection())



plot(u"µs", NoUnits)
plot!(wvfs[1:10], label=permutedims(ts[1:10]))








scatter(compton_bands, σ)
ylims!(0.001, 0.02)

xlims!(500, 2200)
μ_scs = linregress(aoe_vals.e, aoe_vals.μ)
μ_scs_slope, μ_scs_intercept = LinearRegression.slope(μ_scs)[1], LinearRegression.bias(μ_scs)[1]
plot!(500:0.1:2200, x -> μ_scs_slope* x + μ_scs_intercept, label="Best Fit: $(round(μ_scs_slope, digits=2)) + x*$(round(μ_scs_intercept, digits=2)))", line_width=2, color=:red, subplot=1, xformatter=_->"", lw=2)
savefig(joinpath(string_aoe_figure_folder, format("{}_compton_edge_mu_vs_energy.pdf", ch)))


using ValueShapes, BAT, InverseFunctions, Optim, LinearAlgebra, Distributions
using LinearRegression
using DataFrames, GLM
using LsqFit

f_aoe_μ(x::Real, v::Array{T}) where T<:Real = linear_function(x, -v[1], v[2])
f_aoe_μ(x::Array{<:Real}, v::Array{T}) where T<:Real = linear_function.(x, -v[1], v[2])
f_aoe_μ(x::T, v::NamedTuple) where T<:Real = f_aoe_μ(x, [v.μ_scs_slope, v.μ_scs_intercept])

f_aoe_σ(x::Real, v::Array{T}) where T<:Real = exponential_decay(x, v[1], v[2], v[3])
f_aoe_σ(x::Array{<:Real}, v::Array{T}) where T<:Real = exponential_decay.(x, v[1], v[2], v[3])
f_aoe_σ(x::T, v::NamedTuple) where T<:Real = f_aoe_σ(x, [v.σ_scs_amplitude, v.σ_scs_decay, v.σ_scs_offset])

function f_fit(x, v)
    μ = f_aoe_μ(v.e, v)
    σ = f_aoe_σ(v.e, v)
    aoe_compton_peakshape(x, μ, σ, v.n, v.B, v.δ)
end

# get peakstats and hists
ps = compton_band_peakhists.peakstats
hists = compton_band_peakhists.peakhists
# pre-calculate some values
# mu
peak_pos = ps.peak_pos
mean_peak_pos, std_peak_pos = mean(peak_pos), std(peak_pos)
peak_pos_cut = peak_pos .< mean_peak_pos + 3*std_peak_pos .&& peak_pos .> mean_peak_pos - 3*std_peak_pos
# sigma 
peak_sigma = ps.peak_sigma
mean_peak_sigma_end, std_peak_sigma_end = mean(peak_sigma[20:end]), std(peak_sigma[20:end])


simple_fit_aoe_μ        = curve_fit(f_aoe_μ, compton_bands[peak_pos_cut], peak_pos[peak_pos_cut], [0.0, mean_peak_pos])
simple_pars_aoe_μ       = simple_fit_aoe_μ.param
simple_pars_error_aoe_μ = standard_errors(simple_fit_aoe_μ)


scatter(compton_bands, peak_pos)
plot!(compton_bands, x -> Base.Fix2(f_aoe_μ, simple_pars_aoe_μ)(x), lw=3, color=:red)



simple_fit_aoe_σ        = curve_fit(f_aoe_σ, compton_bands, peak_sigma, [0.0, 0.0, mean_peak_sigma_end])
simple_pars_aoe_σ       = simple_fit_aoe_σ.param
simple_pars_error_aoe_σ = standard_errors(simple_fit_aoe_σ)

scatter(compton_bands, peak_sigma)
plot!(compton_bands, x -> Base.Fix2(f_aoe_σ, simple_pars_aoe_σ)(x), lw=3, color=:red)


pseudo_prior = NamedTupleDist(
    e = BAT.ConstValueDist(compton_bands),
    # μ slope and intercept
    μ_scs_slope     = weibull_from_mx(simple_pars_aoe_μ[1], 2*simple_pars_aoe_μ[1]),
    μ_scs_intercept = Uniform(simple_pars_aoe_μ[2]-2*simple_pars_error_aoe_μ[2], simple_pars_aoe_μ[2]+2*simple_pars_error_aoe_μ[2]),
    # σ amplitude, decay and offset
    σ_scs_offset    = Uniform(simple_pars_aoe_σ[3]-2*simple_pars_error_aoe_σ[3], simple_pars_aoe_σ[3]+2*simple_pars_error_aoe_σ[3]),
    σ_scs_decay     = weibull_from_mx(simple_pars_aoe_σ[2], 2*simple_pars_aoe_σ[2]),
    σ_scs_amplitude = weibull_from_mx(simple_pars_aoe_σ[1], 2*simple_pars_aoe_σ[1]),
    # signal and background counts per compton band
    n = product_distribution(weibull_from_mx.(ps.peak_counts, 2*ps.peak_counts)),
    B = product_distribution(weibull_from_mx.(ps.mean_background, 2*ps.mean_background)),
    δ = product_distribution(fill(weibull_from_mx(0.1, 0.5), length(ps))),
)

# pseudo_prior = NamedTupleDist(
#     e = BAT.ConstValueDist(compton_bands),
#     μ_scs_slope = weibull_from_mx(1e-6, 3*1e-6),
#     μ_scs_intercept = Uniform(mean_peak_pos-3*std_peak_pos, mean_peak_pos+3*std_peak_pos),
    
#     σ_scs_offset = Uniform(mean_peak_sigma_end-5*std_peak_sigma_end, mean_peak_sigma_end+5*std_peak_sigma_end),
#     σ_scs_shift = weibull_from_mx(1e-3, 0.1),
#     σ_scs_phase = weibull_from_mx(500, 10000),

#     n = product_distribution(weibull_from_mx.(ps.peak_counts, 5*ps.peak_counts)),
#     B = product_distribution(weibull_from_mx.(ps.mean_background, 5*ps.mean_background)),
#     δ = product_distribution(fill(weibull_from_mx(0.1, 0.5), length(ps))),
# )

# transform back to frequency space
f_trafo = BAT.DistributionTransform(Normal, pseudo_prior)

# start values for MLE
v_init = mean(pseudo_prior)

# create loglikehood function
f_loglike = let f_fit=f_fit, hists=hists
    v -> sum(hist_loglike.(Base.Fix2.(f_fit, LegendSpecFits.expand_vars(v)), hists))
end

# MLE
opt_r = optimize((-) ∘ f_loglike ∘ inverse(f_trafo), f_trafo(v_init))

# best fit results
v_ml = inverse(f_trafo)(Optim.minimizer(opt_r))

plotlyjs()
scatter(v_ml.e, x -> Base.Fix2(f_aoe_μ, v_ml)(x), label="Best Fit", xlabel="Energy (keV)", ylabel="A/E (a.u.)", legend=:topleft)
ylims!(0.2, 0.8)

scatter(v_ml.e, x -> Base.Fix2(f_aoe_σ, v_ml)(x), label="Best Fit", xlabel="Energy (keV)", ylabel="A/E (a.u.)", legend=:topleft)
scatter!(compton_bands, peak_sigma)
plot!(compton_bands, x -> Base.Fix2(f_aoe_σ, simple_pars_aoe_σ)(x), lw=3, color=:red)



best_fit = Base.Fix2.(f_fit, expand_vars(v_ml))
k = 12
plot!(0.1:0.001:0.6, x -> best_fit[k](x))
plot(hists[k])

best_fit_μ = Base.Fix2.(f_aoe_μ, expand_vars(v_ml))[1]
# k = 12
scatter(v_ml.e, x -> best_fit_μ(x))
ylims!(0.2, 0.8)

best_fit_σ = Base.Fix2.(f_aoe_σ, expand_vars(v_ml))[1]
# k = 12
scatter(v_ml.e, x -> best_fit_σ(x))