include("../utils/packages.jl")
include("../utils/loader.jl")
include("../utils/saver.jl")

f_aoe_sigma(x, p) = p[1] .+ p[2]*exp.(-p[3]./x)

is_cal = true
period = 2
calrun = 6
config_folder = p"/home/iwsatlas1/henkes/l200/l200-p02-analysis/configs/"
experiment = "l200"
println("Start AoE for $experiment, period $period, run $calrun")
println("Loading meta data")

channel_list, label_dict, label_list_ext, string_dict, folder_dict = loadMeta(config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)

aoe_figure_folder = joinpath(folder_dict["folder_figures"], "aoe")
checkFolder(PosixPath(aoe_figure_folder), true)

# Load data
println("Open data")
folder_hit = folder_dict["folder_hit"]
filename = joinpath(folder_hit, format("{}-p{:02d}-r{:03d}-cal-tier_hit.lh5", experiment, period, calrun))
data = LHDataStore(filename, "cw")

# Load resolutions and calib values
channel_label_dict = Dict{String, String}(values(label_dict) .=> keys(label_dict))

m_calib_dict      = loadValues(collect(values(label_dict)), "m_calib", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
m_calib_dict      = Dict{String, Any}([channel_label_dict[k] for k in keys(m_calib_dict)] .=> values(m_calib_dict))

n_calib_dict      = loadValues(collect(values(label_dict)), "n_calib", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
n_calib_dict      = Dict{String, Any}([channel_label_dict[k] for k in keys(n_calib_dict)] .=> values(n_calib_dict))

fwhm_qbb_dict     = loadValues(collect(values(label_dict)), "fwhm_qbb", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
fwhm_qbb_dict     = Dict{String, Any}([channel_label_dict[k] for k in keys(fwhm_qbb_dict)] .=> values(fwhm_qbb_dict))

fwhm_qbb_err_dict = loadValues(collect(values(label_dict)), "fwhm_qbb_err", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
fwhm_qbb_err_dict = Dict{String, Any}([channel_label_dict[k] for k in keys(fwhm_qbb_err_dict)] .=> values(fwhm_qbb_err_dict))

fwhm_fep_dict     = loadValues(collect(values(label_dict)), "fwhm_fep", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
fwhm_fep_dict     = Dict{String, Any}([channel_label_dict[k] for k in keys(fwhm_fep_dict)] .=> values(fwhm_fep_dict))

fwhm_sep_dict     = loadValues(collect(values(label_dict)), "fwhm_sep", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
fwhm_sep_dict     = Dict{String, Any}([channel_label_dict[k] for k in keys(fwhm_sep_dict)] .=> values(fwhm_sep_dict))

fwhm_dep_dict     = loadValues(collect(values(label_dict)), "fwhm_dep", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
fwhm_dep_dict     = Dict{String, Any}([channel_label_dict[k] for k in keys(fwhm_dep_dict)] .=> values(fwhm_dep_dict))

fwhm_bifep_dict   = loadValues(collect(values(label_dict)), "fwhm_bifep", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
fwhm_bifep_dict   = Dict{String, Any}([channel_label_dict[k] for k in keys(fwhm_bifep_dict)] .=> values(fwhm_bifep_dict))

# interesting gamma lines
th228_lines = [583.191, 727.330, 860.564, 1592.53, 1620.50, 2103.53, 2614.50]
dep_line   = th228_lines[4]
bifep_line = th228_lines[5]
sep_line   = th228_lines[6]
fep_line   = th228_lines[7]
qbb_cc     = 2039

# ch = channel_list[1]

# Fit strings
for (string_number, string_channel_list) in string_dict

    printfmtln("Processing string number: {}", string_number)
    println()
    println()
    println("Check figure folder")
    string_aoe_figure_folder = joinpath(aoe_figure_folder, format("string{}", string_number))
    checkFolder(PosixPath(string_aoe_figure_folder), true)
    println()
    println()


    for (i, ch) in enumerate(string_channel_list)
        if startswith(label_dict[ch], "P") || startswith(label_dict[ch], "C")
            println("Skip channel $ch ($(label_dict[ch]))")
            continue
        end
        println("Processing Channel $ch")
        label_ext = label_list_ext[ch]

        data_ch = data[ch][:]

        e_uncal = data_ch.e
        a       = data_ch.a

        e_cal = (e_uncal .- n_calib_dict[ch]) ./ m_calib_dict[ch] 

        a     = a[e_cal .< 3000]
        e_cal = e_cal[e_cal .< 3000]
        aoe = a ./ e_cal

        histogram2d(e_cal, aoe, nbins=(1000, 1000), xlims=(0, 3000), ylims=(0.2, 0.8), color=cgrad(:magma))
        plot!(title="Channel $ch ($label_ext)", xlabel="Energy (keV)", ylabel="A/E (a.u.)")
        savefig(joinpath(string_aoe_figure_folder, format("ch{}_aoe_uncorr.pdf", ch)))

        comptbands = [520, 555, 590, 610, 630, 650, 670, 690, 
                    735, 790, 810, 830, 865, 900, 930, 955,
                    1000, 1020, 1040, 1130, 1150, 1170, 1190, 
                    1210, 1250, 1270, 1290, 1310, 1330, 1420,
                    1520, 1540, 1700, 1780, 1810, 1850, 1870,
                    1890, 1910, 1930, 1950, 1970, 1990, 2010,
                    2030, 2050, 2150]

        comptwindow = 20
        nbins = 200
        peakhists_full = [fit(Histogram, aoe[(e_cal .> c) .&& (e_cal .< c+comptwindow) .&& (aoe .> 0.0)], nbins=nbins) for c in comptbands]
        peakstats = StructArray(estimate_single_peak_stats.(peakhists_full))
        peakhists = [fit(Histogram, aoe[(e_cal .> c) .&& (e_cal .< c+comptwindow) .&& (aoe .> ps.peak_pos - 20 * ps.peak_sigma)], nbins=nbins) for (c, ps) in zip(comptbands, peakstats)]

        f_aoe_compton(x, v) = v.n * LegendSpecFits.gauss_pdf(x, v.μ, v.σ) + v.B * LegendSpecFits.ex_step_gauss(x, v.l, v.k, v.t, v.d)
        f_aoe_sig(x, v) = v.n * LegendSpecFits.gauss_pdf(x, v.μ, v.σ)
        f_aoe_bkg(x, v) = v.B * LegendSpecFits.ex_step_gauss(x, v.l, v.k, v.t, v.d)

        aoe_vals = TypedTables.Table(e = Int[], μ = Float64[], σ = Float64[])
        peak_fit_plots = Plots.Plot[]

        for i in eachindex(peakhists)
            h = peakhists[i]
            h_full = peakhists_full[i]
            ps = peakstats[i]

            pseudo_prior = NamedTupleDist(
                μ = Uniform(ps.peak_pos-2*ps.peak_sigma, ps.peak_pos+2*ps.peak_sigma),
                σ = weibull_from_mx(ps.peak_sigma, 2*ps.peak_sigma),
                n = weibull_from_mx(ps.peak_counts, 2*ps.peak_counts),
                l = Uniform(ps.peak_pos - 5*ps.peak_sigma, ps.peak_pos),
                k = weibull_from_mx(0.01, 0.1),
                d = LogUniform(0.01, 1),
                t = LogUniform(0.001, 1),
                B = weibull_from_mx(ps.mean_background, 5*ps.mean_background),
            )

            f_trafo = BAT.DistributionTransform(Normal, pseudo_prior)

            v_init = mean(pseudo_prior)

            f_loglike = let f_fit=f_aoe_compton, h=h
                v -> hist_loglike(Base.Fix2(f_fit, v), h)
            end

            opt_r = optimize((-) ∘ f_loglike ∘ inverse(f_trafo), f_trafo(v_init))
            v_ml = inverse(f_trafo)(Optim.minimizer(opt_r))
            showlegend = ifelse(i == 1, true, false)
            plt = plot(LinearAlgebra.normalize(h_full, mode = :density), st = :stepbins, label="Data", showlegend=showlegend, Layout=(width=800, height=800))
            plot!(minimum(h_full.edges[1]):0.001:maximum(h_full.edges[1]), Base.Fix2(f_aoe_compton, v_ml), label="Best Fit", showlegend=showlegend)
            xlims!(xlims())
            ylims!(ylims())
            plot!(minimum(h_full.edges[1]):0.001:maximum(h_full.edges[1]), Base.Fix2(f_aoe_sig, v_ml), label="Signal", showlegend=showlegend)
            plot!(minimum(h_full.edges[1]):0.001:maximum(h_full.edges[1]), Base.Fix2(f_aoe_bkg, v_ml), label="Background", showlegend=showlegend)
            push!(peak_fit_plots, plt)

            append!(aoe_vals.μ, v_ml.μ)
            append!(aoe_vals.σ, v_ml.σ)
            append!(aoe_vals.e, comptbands[i])
        end

        p = @animate for i in 1:length(peak_fit_plots)
            plot(peak_fit_plots[i], xlims=(0.4, 0.65))
            plot!(xlabel="A/E (a.u.)", ylabel="Counts", title="Compton Edge Fit for Channel $ch ($label_ext)")
        end
        gif(p, joinpath(string_aoe_figure_folder, format("{}_compton_edge_fit.gif", ch)), fps=2)

        scatter(aoe_vals.e, aoe_vals.μ, ylims=(0.95*minimum(aoe_vals.μ), 1.05*maximum(aoe_vals.μ)), xlabel="Energy (keV)", ylabel=L"\mu_{A/E} (a.u.)", title="$ch $label_ext: A/E μ vs. Energy", label=L"\mu_{SCS}")
        xlims!(500, 2200)
        μ_scs = linregress(aoe_vals.e, aoe_vals.μ)
        μ_scs_slope, μ_scs_intercept = LinearRegression.slope(μ_scs)[1], LinearRegression.bias(μ_scs)[1]
        plot!(500:0.1:2200, x -> μ_scs_slope* x + μ_scs_intercept, label="Best Fit: $(round(μ_scs_slope, digits=2)) + x*$(round(μ_scs_intercept, digits=2)))", line_width=2, color=:red, subplot=1, xformatter=_->"", lw=2)
        savefig(joinpath(string_aoe_figure_folder, format("{}_compton_edge_mu_vs_energy.pdf", ch)))

        scatter(aoe_vals.e, aoe_vals.σ, ylims=(0.5*minimum(aoe_vals.σ), 1.5*maximum(aoe_vals.σ)), xlabel="Energy (keV)", ylabel=L"\sigma_{A/E} (a.u.)", title="$ch $label_ext: A/E σ vs. Energy", label=L"\sigma_{SCS}")
        xlims!(500, 2200)
        σ_scs = curve_fit(f_aoe_sigma, aoe_vals.e, aoe_vals.σ, [0.0, maximum(aoe_vals.σ), 5.0])
        plot!(500:0.1:2200, x -> f_aoe_sigma(x, σ_scs.param), label="Best Fit: $(round(σ_scs.param[1]*1e3, digits=2))e-3 + $(round(σ_scs.param[2]*1e3, digits=2))e-3*exp($(round(σ_scs.param[3], digits=2))/x)", line_width=2, color=:red, subplot=1, xformatter=_->"", lw=2)
        savefig(joinpath(string_aoe_figure_folder, format("{}_compton_edge_sigma_vs_energy.pdf", ch)))

        aoe_corr = aoe ./ (μ_scs_slope .* e_cal .+ μ_scs_intercept)

        histogram2d(e_cal, aoe_corr, nbins=(1000, 1000), xlims=(0, 3000), ylims=(0.5, 1.3), color=cgrad(:magma))
        plot!(title="Channel $ch ($label_ext)", xlabel="Energy (keV)", ylabel=L"A/E_{corr} (a.u.)")
        savefig(joinpath(string_aoe_figure_folder, format("{}_aoe_corr.pdf", ch)))

        aoe_norm = (aoe_corr .- 1) ./ f_aoe_sigma(e_cal, σ_scs.param)

        histogram2d(e_cal, aoe_norm, nbins=(1000, 5000), xlims=(0, 3000), ylims=(-30, 10), color=cgrad(:magma))
        plot!(title="Channel $ch ($label_ext)", xlabel="Energy (keV)", ylabel=L"A/E_{norm} (a.u.)")
        savefig(joinpath(string_aoe_figure_folder, format("{}_aoe_norm.pdf", ch)))

        fwhm_dep = fwhm_dep_dict[ch]
        min_e_low_band  = dep_line - 4*fwhm_dep
        max_e_low_band  = dep_line - 2*fwhm_dep
        min_e           = dep_line - 2*fwhm_dep
        max_e           = dep_line + 2*fwhm_dep
        min_e_high_band = dep_line + 2*fwhm_dep
        max_e_high_band = dep_line + 4*fwhm_dep

        dep_sig       = fit(Histogram, aoe_norm[(e_cal .> min_e) .& (e_cal .< max_e)], -7:0.1:5)
        dep_band_low  = fit(Histogram, aoe_norm[(e_cal .> min_e_low_band) .& (e_cal .< max_e_low_band)], -7:0.1:5)
        dep_band_high = fit(Histogram, aoe_norm[(e_cal .> min_e_high_band) .& (e_cal .< max_e_high_band)], -7:0.1:5)

        # histogram2d(e_cal[(e_cal .> min_e) .& (e_cal .< max_e)], aoe_norm[(e_cal .> min_e) .& (e_cal .< max_e)], nbins=(500, 500), xlims=(min_e, max_e), ylims=(-30, 10), color=cgrad(:magma))

        plot(dep_sig, st=:stepbins, label="Dep. Line", color=:blue)
        plot!(dep_band_low, st=:stepbins, label="Low Band", color=:red)
        plot!(dep_band_high, st=:stepbins, label="High Band", color=:green)
        plot!(title="$ch $label_ext : A/E DEP", ylabel="Counts", xlabel=L"A/E_{norm} (a.u.)")
        savefig(joinpath(string_aoe_figure_folder, format("{}_aoe_dep.pdf", ch)))

        cum_dep_sig_substracted = float(cumsum(reverse(dep_sig.weights)) - cumsum(reverse(dep_band_low.weights)) - cumsum(reverse(dep_band_high.weights)))
        cum_dep_sig_substracted .*= inv(cum_dep_sig_substracted[end])
        plot(reverse(dep_sig.edges[1][2:end]), cum_dep_sig_substracted.*100, st=:steppre, label="Dep. Line", color=:blue)
        plot!(xlabel=L"A/E_{norm} (a.u.)", ylabel="Surrival Fraction (%)", title="$ch $label_ext: A/E DEP", xlims=(-7, 5), ylims=(0, 110))

        aoe_cut     = reverse(dep_sig.edges[1][2:end])[findlast(cum_dep_sig_substracted .< 0.9)]
        aoe_cut_arg = findlast(cum_dep_sig_substracted .< 0.9)
        hline!([90], label="90%", color=:black, lw=2, ls=:dash)
        vline!([aoe_cut], label="Cut: $(round(aoe_cut, digits=2))", color=:black, lw=2, ls=:dash)

        qbb_sig      = fit(Histogram, aoe_norm[(e_cal .> qbb_cc - 35) .& (e_cal .< qbb_cc + 35)], -7:0.1:5)
        cum_qbb_sig  = float(cumsum(reverse(qbb_sig.weights)))
        cum_qbb_sig .*= inv(cum_qbb_sig[end])
        plot!(reverse(qbb_sig.edges[1][2:end]), cum_qbb_sig.*100, st=:steppre, label="CC @ Qbb $(round(cum_qbb_sig[aoe_cut_arg]*100, digits=2))%", color=:green)

        fwhm_fep = fwhm_fep_dict[ch]
        min_e_low_band  = fep_line - 4*fwhm_fep
        max_e_low_band  = fep_line - 2*fwhm_fep
        min_e           = fep_line - 2*fwhm_fep
        max_e           = fep_line + 2*fwhm_fep
        min_e_high_band = fep_line + 2*fwhm_fep
        max_e_high_band = fep_line + 4*fwhm_fep

        fep_sig       = fit(Histogram, aoe_norm[(e_cal .> min_e) .& (e_cal .< max_e)], -7:0.1:5)
        fep_band_low  = fit(Histogram, aoe_norm[(e_cal .> min_e_low_band) .& (e_cal .< max_e_low_band)], -7:0.1:5)
        fep_band_high = fit(Histogram, aoe_norm[(e_cal .> min_e_high_band) .& (e_cal .< max_e_high_band)], -7:0.1:5)

        cum_fep_sig_substracted = float(cumsum(reverse(fep_sig.weights)) - cumsum(reverse(fep_band_low.weights)) - cumsum(reverse(fep_band_high.weights)))
        cum_fep_sig_substracted .*= inv(cum_fep_sig_substracted[end])
        plot!(reverse(fep_sig.edges[1][2:end]), cum_fep_sig_substracted .*100, st=:steppre, label="Tl FEP @ 2.6MeV $(round(cum_fep_sig_substracted[aoe_cut_arg]*100, digits=2))%", color=:purple)

        fwhm_sep = fwhm_sep_dict[ch]
        min_e_low_band  = sep_line - 4*fwhm_sep
        max_e_low_band  = sep_line - 2*fwhm_sep
        min_e           = sep_line - 2*fwhm_sep
        max_e           = sep_line + 2*fwhm_sep
        min_e_high_band = sep_line + 2*fwhm_sep
        max_e_high_band = sep_line + 4*fwhm_sep

        sep_sig       = fit(Histogram, aoe_norm[(e_cal .> min_e) .& (e_cal .< max_e)], -7:0.1:5)
        sep_band_low  = fit(Histogram, aoe_norm[(e_cal .> min_e_low_band) .& (e_cal .< max_e_low_band)], -7:0.1:5)
        sep_band_high = fit(Histogram, aoe_norm[(e_cal .> min_e_high_band) .& (e_cal .< max_e_high_band)], -7:0.1:5)

        cum_sep_sig_substracted = float(cumsum(reverse(sep_sig.weights)) - cumsum(reverse(sep_band_low.weights)) - cumsum(reverse(sep_band_high.weights)))
        cum_sep_sig_substracted .*= inv(cum_sep_sig_substracted[end])
        plot!(reverse(sep_sig.edges[1][2:end]), cum_sep_sig_substracted.*100, st=:steppre, label="Bi SEP @ 2.1MeV $(round(cum_sep_sig_substracted[aoe_cut_arg]*100, digits=2))%", color=:darkred)

        fwhm_bifep = fwhm_bifep_dict[ch]
        min_e_low_band  = bifep_line - 4*fwhm_bifep
        max_e_low_band  = bifep_line - 2*fwhm_bifep
        min_e           = bifep_line - 2*fwhm_bifep
        max_e           = bifep_line + 2*fwhm_bifep
        min_e_high_band = bifep_line + 2*fwhm_bifep
        max_e_high_band = bifep_line + 4*fwhm_bifep

        bifep_sig       = fit(Histogram, aoe_norm[(e_cal .> min_e) .& (e_cal .< max_e)], -7:0.1:5)
        bifep_band_low  = fit(Histogram, aoe_norm[(e_cal .> min_e_low_band) .& (e_cal .< max_e_low_band)], -7:0.1:5)
        bifep_band_high = fit(Histogram, aoe_norm[(e_cal .> min_e_high_band) .& (e_cal .< max_e_high_band)], -7:0.1:5)

        cum_bifep_sig_substracted = float(cumsum(reverse(bifep_sig.weights)) - cumsum(reverse(bifep_band_low.weights)) - cumsum(reverse(bifep_band_high.weights)))
        cum_bifep_sig_substracted .*= inv(cum_bifep_sig_substracted[end])
        plot!(reverse(bifep_sig.edges[1][2:end]), cum_bifep_sig_substracted.*100, st=:steppre, label="Bi FEP @ 2.3MeV $(round(cum_bifep_sig_substracted[aoe_cut_arg]*100, digits=2))%", color=:orange)
        savefig(joinpath(string_aoe_figure_folder, format("{}_aoe_surrivalfractions.pdf", ch)))
    end
end