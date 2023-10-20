using LegendDataManagement, PropertyFunctions, TypedTables, PropDicts
using Unitful, Formatting, LaTeXStrings
using Plots
using LegendHDF5IO, LegendDSP, LegendSpecFits

ENV["JULIA_DEBUG"] = Main # enable debug

gr()
plotlyjs(size=(1200, 700))
# plotlyjs(size=(800, 300))

@info "Loading Legend MetaData"
l200 = LegendData(:l200)

period = DataPeriod(3)
run    = DataRun(1)

@info "Optimize PSD filter for period $period and run $run"

filekey = sort(search_disk(FileKey, l200.tier[:raw, :cal, period, run]), by = x-> x.time)[1]
@info "Found filekey $filekey"

chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable)

sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)
dsp_meta = l200.metadata.dataprod.config.cal.dsp(sel).default
dsp_config = create_dsp_config(dsp_meta)
@debug "Loaded DSP config: $(dsp_config)"

pars_tau_folder     = joinpath(l200.tier[:par, :cal, period, run], "decay_time")
pars_filename       = format("{}-{}-{}-{}-decay_time.json", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category))
pars_tau            = readprops(joinpath(pars_tau_folder, pars_filename))
@debug "Loaded decay times"

pars_optimization_folder = joinpath(l200.tier[:par, :cal, period, run], "optimization")
pars_filename           = format("{}-{}-{}-{}-filter_optimization.json", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category))
pars_optimization       = readprops(joinpath(pars_optimization_folder, pars_filename))
@debug "Loaded optimization parameters"

@debug "Create figures folder"
figures_folder = joinpath(l200.tier[:plt, :cal, period, run], "optimization")
ifelse(isdir(figures_folder), @debug("Figure folder $figures_folder already exists"), mkpath(figures_folder))

@debug "Create pars folder"
pars_folder = joinpath(l200.tier[:par, :cal, period, run], "optimization")
ifelse(isdir(pars_folder), @debug("Pars folder $pars_folder already exists"), mkpath(pars_folder))

@debug "Create pars db"
pars_db = PropDict()


i = findfirst(chinfo.detector .== :B00002A)
ch_short = chinfo.channel[i]
ch = format("ch{}", ch_short)
det = chinfo.detector[i]

@debug "Processing channel $ch ($det)"

if haskey(l200.metadata.dataprod.config.cal.dsp.optimization(sel), det)
    optimization_config = l200.metadata.dataprod.config.cal.dsp.optimization(sel)[det]
    @debug "Use config for detector $det"
else
    optimization_config = l200.metadata.dataprod.config.cal.dsp.optimization(sel).default
    @debug "Use default config"
end

# unpack config
min_enc, max_enc = optimization_config.min_enc, optimization_config.max_enc
nbins = optimization_config.nbins
rel_cut_fit = optimization_config.rel_cut_fit
dep, dep_window = 1592.53, 25.0
sep, sep_window = 2103.53, 25.0

filename = joinpath(l200.tier[DataTier(:peaks), :cal, period, run], format("{}-{}-{}-{}-{}-tier_peaks.lh5", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch))
if !isfile(filename)
    @warn "File $filename does not exist, Skip channel $ch"
    # continue
end

data = LHDataStore(filename, "r")

@debug "Loading Tl208 FEP data from $(filename)"
using StatsBase
wvfs_ch_dep_bi121fep = data[ch].Tl208DEP_Bi212FEP.waveform[:]
e_ch_dep_bi121fep    = data[ch].Tl208DEP_Bi212FEP.daqenergy[:]
wvfs_ch_dep          = wvfs_ch_dep_bi121fep[e_ch_dep_bi121fep .< quantile(e_ch_dep_bi121fep, 0.5)]
wvfs_ch_sep          = data[ch].Tl208SEP.waveform[:]

close(data)
plot(wvfs_ch_dep[1:10])

# DSP
dsp_dep = dsp_sg_optimization(wvfs_ch_dep, dsp_config, pars_tau[det].tau.val*u"µs", pars_optimization[det])
dsp_sep = dsp_sg_optimization(wvfs_ch_sep, dsp_config, pars_tau[det].tau.val*u"µs", pars_optimization[det])

# Load DEP data and prepare Pile-up cut
blslope_dep = dsp_dep.blslope[isfinite.(dsp_dep.e)]
aoe_dep, e_dep = dsp_dep.aoe[:, isfinite.(dsp_dep.e)], dsp_dep.e[isfinite.(dsp_dep.e)]
wvfs_ch_dep = wvfs_ch_dep[isfinite.(dsp_dep.e)]

bin_window_cut = blslope_dep .> mean(blslope_dep) - 0.5*std(blslope_dep) .&& blslope_dep .< mean(blslope_dep) + 0.5*std(blslope_dep)
bin_width   = 2 * (quantile(blslope_dep[bin_window_cut], 0.75) - quantile(blslope_dep[bin_window_cut], 0.25)) / ∛(length(blslope_dep[bin_window_cut]))
h_blslope_dep = fit(Histogram, ustrip.(blslope_dep), ustrip(mean(blslope_dep)-0.5*std(blslope_dep):bin_width:mean(blslope_dep)+0.5*std(blslope_dep)))

cuts_dep_blslope = cut_single_peak(blslope_dep, -0.1u"ns^-1", 0.1u"ns^-1", 500, 0.2)

result_fit_dep_blslope, report_fit_dep_blslope = fit_half_centered_trunc_gauss(blslope_dep, zero(blslope_dep[1]), cuts_dep_blslope)

using LinearAlgebra

plot(LinearAlgebra.normalize(h_blslope_dep, mode=:pdf), color=:lightblue)
plot!(ustrip(zero(blslope_dep[1])):1e-5:ustrip(cuts_dep_blslope.high), t -> report_fit_dep_blslope.f_fit(t), lw=3, color=:red)
vline!(ustrip.([-3*result_fit_dep_blslope.σ, 3*result_fit_dep_blslope.σ]), label="Cut window", color=:green)
vspan!(ustrip.([-3*result_fit_dep_blslope.σ, 3*result_fit_dep_blslope.σ]), color=:lightgreen, alpha=0.2)
xlims!(ustrip(-5*result_fit_dep_blslope.σ),  ustrip(5*result_fit_dep_blslope.σ), showlegend=false)

# Cut on blslope and energy from fit
qc_cut_dep = blslope_dep .> -3*result_fit_dep_blslope.σ .&& blslope_dep .< 3*result_fit_dep_blslope.σ .&& e_dep .> 1000 .&& e_dep .> quantile(e_dep, 0.05) .&& e_dep .< quantile(e_dep, 0.999)
aoe_dep, e_dep = aoe_dep[:, qc_cut_dep], e_dep[qc_cut_dep]
wvfs_ch_dep = wvfs_ch_dep[qc_cut_dep]

blslope_sep = dsp_sep.blslope[isfinite.(dsp_sep.e)]
aoe_sep, e_sep = dsp_sep.aoe[:, isfinite.(dsp_sep.e)], dsp_sep.e[isfinite.(dsp_sep.e)]
wvfs_ch_sep = wvfs_ch_sep[isfinite.(dsp_sep.e)]

bin_window_cut = blslope_sep .> mean(blslope_sep) - 0.5*std(blslope_sep) .&& blslope_sep .< mean(blslope_sep) + 0.5*std(blslope_sep)
bin_width   = 2 * (quantile(blslope_sep[bin_window_cut], 0.75) - quantile(blslope_sep[bin_window_cut], 0.25)) / ∛(length(blslope_sep[bin_window_cut]))
h_blslope_sep = fit(Histogram, ustrip.(blslope_sep), ustrip(mean(blslope_sep)-0.5*std(blslope_sep):bin_width:mean(blslope_sep)+0.5*std(blslope_sep)))

cuts_sep_blslope = cut_single_peak(blslope_sep, -0.1u"ns^-1", 0.1u"ns^-1", 500, 0.2)

result_fit_sep_blslope, report_fit_sep_blslope = fit_half_centered_trunc_gauss(blslope_sep, zero(blslope_sep[1]), cuts_sep_blslope)

using LinearAlgebra

plot(LinearAlgebra.normalize(h_blslope_sep, mode=:pdf), color=:lightblue)
plot!(ustrip(zero(blslope_sep[1])):1e-5:ustrip(cuts_sep_blslope.high), t -> report_fit_sep_blslope.f_fit(t), lw=3, color=:red)
vline!(ustrip.([-3*result_fit_sep_blslope.σ, 3*result_fit_sep_blslope.σ]), label="Cut window", color=:green)
vspan!(ustrip.([-3*result_fit_sep_blslope.σ, 3*result_fit_sep_blslope.σ]), color=:lightgreen, alpha=0.2)
xlims!(ustrip(-5*result_fit_sep_blslope.σ),  ustrip(5*result_fit_sep_blslope.σ), showlegend=false)


qc_cut_sep = blslope_sep .> -3*result_fit_sep_blslope.σ .&& blslope_sep .< 3*result_fit_sep_blslope.σ .&& e_sep .> 1000 .&& e_sep .> quantile(e_sep, 0.05) .&& e_sep .< quantile(e_sep, 0.999)
aoe_sep, e_sep = aoe_sep[:, qc_cut_sep], e_sep[qc_cut_sep]
wvfs_ch_sep = wvfs_ch_sep[qc_cut_sep]

# prepare DEP energy histogram and fit initial histogram
bin_width = 2 * (quantile(e_dep[e_dep .> quantile(e_dep, 0.5)], 0.75) - quantile(e_dep[e_dep .> quantile(e_dep, 0.5)], 0.25)) / ∛(length(e_dep[e_dep .> quantile(e_dep, 0.5)]))
e_dep_hist = fit(Histogram, e_dep, minimum(e_dep):bin_width:maximum(e_dep))

ps_dep = LegendSpecFits.estimate_single_peak_stats(e_dep_hist)
result_dep, report_dep = fit_single_peak_th228(e_dep_hist, ps_dep,; uncertainty=false)

plot(report_dep, xlabel="Energy (ADC)")

m_calib = dep / result_dep.μ

e_dep_calib = e_dep .* m_calib
e_sep_calib = e_sep .* m_calib

sep_sfs     = ones(length(dsp_config.a_grid_wl_sg))
sep_sfs_err = zeros(length(dsp_config.a_grid_wl_sg))

for (i_aoe, wl) in enumerate(dsp_config.a_grid_wl_sg)

    aoe_dep_i = aoe_dep[i_aoe, :][isfinite.(aoe_dep[i_aoe, :])] ./ m_calib
    e_dep_i   = e_dep_calib[isfinite.(aoe_dep[i_aoe, :])]

    # prepare AoE
    max_aoe_dep_i = quantile(aoe_dep_i, 0.99) + 0.05
    min_aoe_dep_i = quantile(aoe_dep_i, 0.1)

    try
        psd_cut = get_psd_cut(aoe_dep_i, e_dep_i; cut_search_interval=(min_aoe_dep_i, max_aoe_dep_i))

        aoe_sep_i = aoe_sep[i_aoe, :][isfinite.(aoe_sep[i_aoe, :])] ./ m_calib
        e_sep_i   = e_sep_calib[isfinite.(aoe_sep[i_aoe, :])]

        result_sep, report_sep = get_peak_surrival_fraction(aoe_sep_i, e_sep_i, sep, sep_window, psd_cut.cut; uncertainty=true)
        sep_sfs[i_aoe]     = result_sep.sf
        sep_sfs_err[i_aoe] = result_sep.err.sf
    catch
        @warn "Couldn't process window length $wl"
    end
end

plot(u"ns", NoUnits)
scatter!(collect(dsp_config.a_grid_wl_sg), sep_sfs .* 100, yerr=sep_sfs_err*100, xlabel="Window length", ylabel="Survival fraction (%)", label="SEP", legend=:topright, ylims=(0, maximum(sep_sfs[sep_sfs .< 1.0]) * 100 * 1.2))


i_aoe = 8
collect(dsp_config.a_grid_wl_sg)[i_aoe]
aoe_dep_i = aoe_dep[i_aoe, :][isfinite.(aoe_dep[i_aoe, :])] ./ m_calib
e_dep_i   = e_dep_calib[isfinite.(aoe_dep[i_aoe, :])]

# prepare AoE
max_aoe_dep_i = quantile(aoe_dep_i, 0.99) + 0.05
min_aoe_dep_i = quantile(aoe_dep_i, 0.1)

# cuts_aoe_i = cut_single_peak(aoe_dep_i, min_aoe_dep_i, max_aoe_dep_i, 500, 0.5)

# result_fit_aoe_dep_i, report_fit_aoe_dep_i = fit_single_trunc_gauss(aoe_dep_i, cuts_aoe_i)
# μ_scs = result_fit_aoe_dep_i.μ / dep
# σ_scs = result_fit_aoe_dep_i.σ / dep
# aoe_dep_i_corr = aoe_dep_i ./ μ_scs ./ e_dep_i .- 1.0
# aoe_dep_i_corr ./= (σ_scs .* e_dep_i)

# stephist(aoe_dep_i, bins=1500)

# histogram2d(e_dep_i, aoe_dep_i_corr, bins=(800, 2500), colorbar_scale=:log10)

histogram(e_dep_i, bins=200, label="DEP")


psd_cut = get_psd_cut(aoe_dep_i, e_dep_i; cut_search_interval=(max_aoe_dep_i, min_aoe_dep_i))
scatter(0.6:0.001:0.68, psd_cut .* 100)

histogram(aoe_dep_i, bins=1500, label="DEP")
vline!([0.649], label="PSD cut")
vline!([psd_cut.cut], label="PSD cut")
wvfs_ch_dep_surrive = wvfs_ch_dep[aoe_dep_i .> psd_cut.cut]
wvfs_ch_dep_cut = wvfs_ch_dep[aoe_dep_i .< psd_cut.cut]
plot(wvfs_ch_dep_surrive[1:10])
plot(wvfs_ch_dep_cut[1:10])
plot(wvfs_ch_dep[50:100])

aoe_sep_i = aoe_sep[i_aoe, :][isfinite.(aoe_sep[i_aoe, :])] ./ m_calib
e_sep_i   = e_sep_calib[isfinite.(aoe_sep[i_aoe, :])]

histogram(aoe_sep_i, bins=1000, label="SEP")
vline!([psd_cut.cut], label="PSD cut")

wvfs_ch_sep_surrive = wvfs_ch_sep[aoe_sep_i .> psd_cut.cut]
wvfs_ch_sep_cut = wvfs_ch_sep[aoe_sep_i .< psd_cut.cut]
plot(wvfs_ch_sep_surrive[1:10])
plot(wvfs_ch_sep_cut[1:10])

xlims!(45e3, 55e3)
# peakhist = fit(Histogram, e_sep_i, sep-sep_window:0.5:sep+sep_window)
# plot(peakhist)


result_sep, report_sep = get_peak_surrival_fraction(aoe_sep_i, e_sep_i, sep, sep_window, psd_cut.cut; uncertainty=true, low_e_tail=false)
result_sep.sf * 100
result_sep.err.sf * 100
plot(report_sep.after)
plot!(report_sep.before)