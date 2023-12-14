using LegendDataManagement, PropertyFunctions, TypedTables, PropDicts
using Unitful, Formatting, LaTeXStrings, Measures
using Plots, StatsBase
using LegendHDF5IO, LegendDSP, LegendSpecFits
using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked

ENV["JULIA_DEBUG"] = Main # enable debug

gr(size=(1500, 800))
# plotlyjs(size=(800, 500))
# plotlyjs(size=(600, 500))

run = DataRun(0)
period = DataPeriod(3)

@info "Loading Legend MetaData"
l200 = LegendData(:l200)
@info "PSD calibration for period $period and run $run"

filekeys = sort(search_disk(FileKey, l200.tier[:dsp, :cal, period, run]), by = x-> x.time)
filekey = filekeys[1]
@info "Found filekey $filekey"

chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable && $usability == :on)

sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)

hit_folder = l200.tier[:hit_ch, :cal, period, run]
pars_energy = l200.par[:cal, :energy, period, run]

@debug "Create figures folder"
figures_folder = joinpath(l200.tier[:plt, :cal, period, run], "aoe")
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
log_folder = joinpath(l200.tier[:log, :cal, period, run])
if isdir(log_folder)
    @debug("Log folder $figures_folder already exists")
else
    mkpath(log_folder)
end

i = 1
# i = findfirst(chinfo.detector .== :B00035C)
ch_short = chinfo.channel[i]
ch = format("ch{}", ch_short)
string_number = chinfo.string[i]
det = chinfo.detector[i]

@info "Processing channel $ch ($det)"

figures_folder_string = joinpath(figures_folder, format("string{:02d}", string_number))

hitchfilename = joinpath(hit_folder, format("{}-{}-{}-{}-{}-tier_hit.lh5", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch))

# load config
if haskey(l200.metadata.dataprod.config.psd(sel), det)
    psd_config = merge(l200.metadata.dataprod.config.psd(sel).default, l200.metadata.dataprod.config.psd(sel)[det])
    @debug "Use config for detector $det"
else
    psd_config = l200.metadata.dataprod.config.psd(sel).default
    @debug "Use default config"
end

compton_bands  = Vector{Float64}(psd_config.compton_bands)
compton_window = psd_config.compton_window
p_value        = psd_config.p_value
e_type         = Symbol(psd_config.energy_type)

if !haskey(pars_energy, det) || !haskey(pars_energy[det], e_type) || !haskey(pars_energy[det][e_type], :energy)
    @error "Energy calibration for $(det) not found"
    throw(ErrorException("Energy calibration for $(det) not found"))
end
e, aoe = nothing, nothing
try
    data_hit = LHDataStore(hitchfilename, "r");
    # get a
    a = data_hit["$(ch)/dataQC/a"][:];
    # get energy for best resolution
    e = data_hit["$(ch)/dataQC/$(e_type)"][:];
    calibrate_energy!(e, pars_energy[det][e_type].energy)
    # get aoe
    aoe = a ./ e;
    close(data_hit)
catch e
    @error "AoE and E data from $(basename(hitchfilename)) cannot be loaded: $e"
    throw(LoadError(string(basename(hitchfilename)), 154, "AoE and E data from $(basename(hitchfilename)) cannot be loaded"))
end

gr(size=(1500, 800))
histogram2d(e, aoe, nbins=(0:0.5:3000, 0.1:1e-3:0.6), xlims=(0, 3000), ylims=(0.3, 0.6), size=(1000, 600), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy (keV)", ylabel="A/E (a.u.)", margin=5mm)
xticks!(0:250:3000)
plot!(title=format("{} A/E Uncalibrated ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
plot!(margin=1mm, thickness_scaling=1.6, dpi=600, size=(1000, 600), fontfamily=:sansserif)
savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-aoe_uncalibrated_{}.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch, string(e_type))))


result_fit, report_fit, compton_band_peakhists = nothing, nothing, nothing
# get compton band peak histograms with generated peakstats
compton_band_peakhists = generate_aoe_compton_bands(aoe, e, compton_bands, compton_window)

# pars_aoe_simple = (μ = compton_band_peakhists.simple_pars_aoe_μ, μ_err=compton_band_peakhists.simple_pars_error_aoe_μ, σ = compton_band_peakhists.simple_pars_aoe_σ, σ_err = compton_band_peakhists.simple_pars_error_aoe_σ)
# result, report = fit_aoe_compton(compton_band_peakhists.peakhists, compton_band_peakhists.peakstats, compton_bands; pars_aoe=pars_aoe_simple)
result_fit, report_fit = fit_aoe_compton(compton_band_peakhists.peakhists, compton_band_peakhists.peakstats, compton_bands,; uncertainty=true)

# # generate plots of compton bands as gif
p = @animate for band in compton_bands fps=2
    report_band = report_fit[band]
    plot(report_band, title=format("{} A/E CC at $band keV ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)), legend=:topleft)
    plot!(title=format("{} A/E CC at $band keV ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
    plot!(margin=5mm, thickness_scaling=1.6, dpi=600, size=(1400, 800))#, fontfamily=font(family="monospace",halign=:center, pointsize=18))
    xlims!(0.51, 0.56)
end
gif(p, fps=0.5)
gif(p, fps=0.5, joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-aoe_compton-bands_{}.gif", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch, string(e_type))))

# compton_bands = [band for band in compton_bands if result_fit[band].p_value > p_value]
p_values = [result_fit[band].p_value for band in compton_bands]
μ = [result_fit[band].μ for band in compton_bands]
μ_err = [result_fit[band].err.μ for band in compton_bands]
σ = [result_fit[band].σ for band in compton_bands]
σ_err = [result_fit[band].err.σ for band in compton_bands]

aoe_corrections = fit_aoe_corrections(compton_bands, μ, σ)

# # fit μ and σ with correction functions
# aoe_corrections = nothing
using Distributions, ValueShapes, LinearAlgebra
plotlyjs()
band = 1290.0
report_band = report_fit[band]
# ps = compton_band_peakhists.peakstats[compton_bands .== band][1]
# pseudo_prior = NamedTupleDist(
#                 μ = Uniform(ps.peak_pos-0.5*ps.peak_sigma, ps.peak_pos+0.5*ps.peak_sigma),
#                 # σ = weibull_from_mx(ps.peak_sigma, 2*ps.peak_sigma),
#                 σ = Uniform(0.95*ps.peak_sigma, 1.05*ps.peak_sigma),
#                 # σ = Normal(ps.peak_sigma, 0.01*ps.peak_sigma),
#                 # n = weibull_from_mx(ps.peak_counts, 1.1*ps.peak_counts),
#                 # n = Normal(ps.peak_counts, 0.5*ps.peak_counts),
#                 n = Normal(0.9*ps.peak_counts, 0.5*ps.peak_counts),
#                 # n = Uniform(0.8*ps.peak_counts, 1.2*ps.peak_counts),
#                 # B = weibull_from_mx(ps.mean_background, 1.2*ps.mean_background),
#                 B = Normal(2*ps.mean_background, 0.8*ps.mean_background),
#                 # B = Uniform(0.8*ps.mean_background, 1.2*ps.mean_background),
#                 # B = Uniform(0.8*ps.mean_background, 1.2*ps.mean_background),
#                 # δ = weibull_from_mx(0.1, 0.8)
#                 δ = LogUniform(0.1, 1.0)
#             )
plot(report_band, title=format("{} A/E CC at $band keV ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
xlims!(0.41, 0.45)
plot!(margin=1mm, thickness_scaling=1.6, dpi=600, size=(1400, 800), fontfamily=:sansserif)

plot(LinearAlgebra.normalize(report_band.h, mode=:density), yscale=:log10)
plot!(0.24:1e-5:0.44, x -> LegendSpecFits.f_aoe_compton(x, mean(pseudo_prior)), lw=3, color=:red)
plot!(0.24:1e-5:0.44, x -> LegendSpecFits.f_aoe_compton(x, merge(mean(pseudo_prior), (B = 1000, ))), lw=3, color=:green)

plot!(0.24:1e-5:0.45, x -> LegendSpecFits.f_aoe_compton(x, merge(report_band.v, (σ = 0.0032, ))))
xlims!(minimum(compton_band_peakhists.min_aoe), maximum(compton_band_peakhists.max_aoe))


scatter(aoe_corrections.e, aoe_corrections.μ, yerr=μ_err, ms=5, color=:black, layout = @layout[grid(2, 1, heights=[0.8, 0.2])], xlabel=L"Energy\ (keV)", ylabel=L"\mu_{A/E} (a.u.)", label=L"\mu_{SCS}", xticks = (minimum(compton_bands):200:maximum(compton_bands)), xlims=(minimum(compton_bands)-50, maximum(compton_bands)+50))
plot!(ylims=(0.95*median(aoe_corrections.μ), 1.05*median(aoe_corrections.μ)), subplot=1, xlabel="", xticks = :none)
plot!(0.0:1500:3000, x -> aoe_corrections.f_μ_scs(x), label="Best Fit", line_width=3.5, color=:red, subplot=1, xformatter=_->"")
plot!(aoe_corrections.e, (aoe_corrections.f_μ_scs.(aoe_corrections.e) .- aoe_corrections.μ) ./ aoe_corrections.μ .* 100 , label="Residuals", ylabel=L"Residuals (\%)", line_width=2, color=:black, st=:scatter, ylims = (-5.0, 5.0), markershape=:x, subplot=2)
plot!(legend = :topright, title=format(L"{}\ A/E\ \mu \ ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)), subplot=1)
plot!(margin=1mm, thickness_scaling=1.6, dpi=600, size=(1000, 600))
savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-aoe_mu_{}.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch, string(e_type))))



scatter(aoe_corrections.e, aoe_corrections.σ, yerr=σ_err, ms=5, color=:black, layout = @layout[grid(2, 1, heights=[0.8, 0.2])], xlabel=L"Energy\ (keV)", ylabel=L"\mu_{A/E} (a.u.)", label=L"\sigma_{SCS}", xticks = (minimum(compton_bands):200:maximum(compton_bands)), xlims = (minimum(compton_bands)-50, maximum(compton_bands)+50))
plot!(ylims=(0.1*aoe_corrections.f_σ_scs(maximum(compton_bands)), 2*aoe_corrections.f_σ_scs(minimum(compton_bands))), subplot=1, xlabel="", xticks = :none)
plot!(minimum(compton_bands)-50:0.1:maximum(compton_bands)+50, x -> aoe_corrections.f_σ_scs(x), label=format("Best Fit: sqrt({:.2E}+({:.2E}/x^2)", aoe_corrections.σ_scs...), line_width=3.5, color=:red, subplot=1, xformatter=_->"")
plot!(aoe_corrections.e, (aoe_corrections.f_σ_scs.(aoe_corrections.e) .- aoe_corrections.σ) ./ aoe_corrections.σ .* 100 , label="Residuals", ylabel="Residuals (%)", line_width=2, color=:black, st=:scatter, ylims = (-50.0, 50.0), markershape=:x, subplot=2)
plot!(legend = :topright, title=format(L"{}\ A/E\ \sigma \ ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)), subplot=1)

correct_aoe!(aoe, e, aoe_corrections)

gr()
histogram2d(e, aoe, nbins=(0:0.5:3000, -20:0.1:10), xlims=(0, 3000), ylims=(-20, 10), size=(1000, 600), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel=L"Energy\ (keV)", ylabel=L"A/E\ (\sigma_{A/E})")
plot!(margin=1mm, thickness_scaling=1.6, dpi=600, size=(1000, 600))
