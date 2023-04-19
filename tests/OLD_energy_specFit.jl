include("../utils/packages.jl")
include("../utils/loader.jl")
include("../utils/saver.jl")

plotlyjs()
histograms_folder = "/remote/ceph2/group/legendex/data/l60/r025/julia/cal/histograms/"
histograms_filename = joinpath(histograms_folder, "energy_histograms.h5")
figure_folder = "/remote/ceph2/group/legendex/data/l60/r025/julia/cal/figures/energy/string1/"
data = LHDataStore(string(histograms_filename), "r")

ch = 34

for ch in keys(data)
    println("Processing Channel $ch")
    e_uncal = data[string(ch)]
    nbins = 15000

    h_uncal = fit(Histogram, e_uncal, nbins=nbins)

    th228_lines = [583.191, 727.330, 860.564, 1592.53, 1620.50, 2103.53, 2614.50]
    # th228_lines = [583.191, 727.330, 860.564, 2103.53, 2614.50]

    h_cal, h_deconv, peakpos, threshold, c, c_precal = RadiationSpectra.calibrate_spectrum(
        h_uncal, th228_lines,
        σ = 2.0, threshold = 2.0
    )

    peakhists = RadiationSpectra.subhist.(Ref(h_cal), (x -> (x-25, x+25)).(th228_lines))
    peakstats = StructArray(estimate_single_peak_stats.(peakhists))

    plot(
        (
            plot(LinearAlgebra.normalize(h_cal, mode = :density), st = :stepbins, yscale = :log10, label="Energy");#, xguide="Energy (keV)", xguideposition=:topright);
            vline!(peakpos, label="Peak Positions", legend=:topright);
            xlims!(0, 3000);
            xticks!((0:200:3000, ["$i" for i in 0:200:3000]));
            ylabel!("Counts");
            plot!()
        ),
        plot.(LinearAlgebra.normalize.(peakhists, mode = :density), st = :stepbins, yscale = :log10, label="")...,
        # title=format.("{:.2f}keV peak", th228_lines), titleloc=:right, titlefont=font(8))...;
        # ),
        # label="")...,
        layout = @layout[a{0.25h} ; grid(2,4)], margin=1mm, framestyle=:box,
        # bottom_margin=10px, top_margin=10px, left_margin=10px, right_margin=10px,
        # titleloc=:right, titlefont=font(8),
        grid=true, gridalpha=0.2, gridcolor=:black, gridlinewidth=0.5,
        xlabelfontsize=8, xlabelmargin=0mm,
        legend=:bottomright
    )
    savefig(joinpath(figure_folder, format("Channel{}_simple_calibration.pdf", ch)))

    peak_fit_plots = Plots.Plot[]
    fwhm_vals = Dict{Float64, Float64}()

    f_fit(x, v) = gamma_peakshape(x, v.μ, v.σ, v.n, v.step_amplitude, v.skew_fraction, v.skew_width, v.background)
    f_sig(x, v) = signal_peakshape(x, v.μ, v.σ, v.n, v.skew_fraction)
    f_lowEtail(x, v) = lowEtail_peakshape(x, v.μ, v.σ, v.n, v.skew_fraction, v.skew_width)
    f_bck(x, v) = background_peakshape(x, v.μ, v.σ, v.step_amplitude, v.background)
    f_sigWithTail(x, v) = signal_peakshape(x, v.μ, v.σ, v.n, v.skew_fraction) + lowEtail_peakshape(x, v.μ, v.σ, v.n, v.skew_fraction, v.skew_width) 

    for i in eachindex(peakhists)
        h = peakhists[i]
        ps = peakstats[i]

        pseudo_prior = NamedTupleDist(
            μ = Uniform(ps.peak_pos-10, ps.peak_pos+10),
            σ = weibull_from_mx(ps.peak_sigma, 2*ps.peak_sigma),
            n = weibull_from_mx(ps.peak_counts, 2*ps.peak_counts),
            step_amplitude = weibull_from_mx(ps.mean_background, 2*ps.mean_background),
            skew_fraction = Uniform(0.01, 0.25),
            skew_width = LogUniform(0.001, 0.1),
            background = weibull_from_mx(ps.mean_background, 2*ps.mean_background),
        )

        f_trafo = BAT.DistributionTransform(Normal, pseudo_prior)

        v_init = mean(pseudo_prior)

        f_loglike = let f_fit=f_fit, h=h
            v -> hist_loglike(Base.Fix2(f_fit, v), h)
        end

        opt_r = optimize((-) ∘ f_loglike ∘ inverse(f_trafo), f_trafo(v_init))
        v_ml = inverse(f_trafo)(Optim.minimizer(opt_r))
        showlegend = ifelse(i == 1, true, false)
        global v_ml = v_ml
        plt = plot(LinearAlgebra.normalize(h, mode = :density), st = :stepbins, yscale = :log10, label="Data", showlegend=showlegend, Layout=(width=800, height=800))
        plot!(minimum(h.edges[1]):0.1:maximum(h.edges[1]), Base.Fix2(f_fit, v_ml), label="Best Fit", showlegend=showlegend)
        xlims!(xlims())
        ylims!(ylims())
        plot!(minimum(h.edges[1]):0.1:maximum(h.edges[1]), Base.Fix2(f_sig, v_ml), label="Signal", showlegend=showlegend)
        plot!(minimum(h.edges[1]):0.1:maximum(h.edges[1]), Base.Fix2(f_lowEtail, v_ml), label="Low-E tail", showlegend=showlegend)
        plot!(minimum(h.edges[1]):0.1:maximum(h.edges[1]), Base.Fix2(f_bck, v_ml), label="Background", showlegend=showlegend)
        push!(peak_fit_plots, plt)

        half_max_sig = maximum(Base.Fix2(f_sigWithTail, v_ml).(v_ml.μ - v_ml.σ:0.001:v_ml.μ + v_ml.σ))/2
        roots_low = find_zero(x -> Base.Fix2(f_sigWithTail, v_ml)(x) - half_max_sig, v_ml.μ - v_ml.σ)
        roots_high = find_zero(x -> Base.Fix2(f_sigWithTail, v_ml)(x) - half_max_sig, v_ml.μ + v_ml.σ)
        fwhm_vals[th228_lines[i]] = roots_high - roots_low

    end

    plot(peak_fit_plots..., Layout=(width=8000, height=8000), margin=1mm, framestyle=:box, grid=true, gridalpha=0.2, gridcolor=:black, gridlinewidth=0.5, xlabelfontsize=8, xlabelmargin=0mm, legend=:bottomright)
    plot!(legend=:bottomright, legendfontsize=8, legendfont=font(8), legendtitlefontsize=8, legendtitlefont=font(8))
    plot!(xlabel="Energy (keV)", xlabelfontsize=6)
    plot!(ylabel="Counts", ylabelfontsize=6)
    plot!(margin=3mm, framestyle=:box)
    savefig(joinpath(figure_folder, format("Channel{}_peak_fits.pdf", ch)))


    plot(fwhm_vals, st=:scatter, label="FWHM Channel $ch", xlabel="Energy (keV)", xlabelfontsize=10, ylabel="FWHM (keV)", ylabelfontsize=10, legend=:topleft, legendfontsize=8, legendfont=font(8), legendtitlefontsize=8, legendtitlefont=font(8))

    f_fwhm(x, p) = sqrt.(x.*p[2] .+ p[1])
    fwhm_vals_noDEPSEP = filter(((k,v),) -> k != 1592.53 && k != 2103.53 && v > 0.0, fwhm_vals)
    fwhm_fit_result = curve_fit(f_fwhm, collect(keys(fwhm_vals_noDEPSEP)), collect(values(fwhm_vals_noDEPSEP)), [1, 0.01])


    fwhm_qbb = f_fwhm(2039, fwhm_fit_result.param)
    fwhm_pars_rand = rand(MvNormal(fwhm_fit_result.param, estimate_covar(fwhm_fit_result)), 1000)
    fwhm_qbb_rand = f_fwhm.(2039, eachcol(fwhm_pars_rand))
    fwhm_qbb_err = std(fwhm_qbb_rand)

    plot!(0:0.1:3000, x -> f_fwhm(x, fwhm_fit_result.param), label="Best Fit: Sqrt($(round(fwhm_fit_result.param[1], digits=2)) + x*$(round(fwhm_fit_result.param[2]*1e3, digits=2))e-3)", line_width=2, color=:red)
    xlims!(0, 3000)
    xticks!(0:200:3000)
    vline!([2039], color=:green, label="")
    hline!([fwhm_qbb], label="Qbb/keV: $(round(fwhm_qbb, digits=2))+-$(round(fwhm_qbb_err, digits=2))", color=:green)
    hspan!([fwhm_qbb - fwhm_qbb_err, fwhm_qbb + fwhm_qbb_err], color=:green, alpha=0.2, label="")
    savefig(joinpath(figure_folder, format("Channel{}_fwhm.pdf", ch)))
end

# plot(2600:0.1:2620, Base.Fix2(f_fit, v_ml), yscale=:log10, label="Peak")
# ylims!(ylims())
# xlims!(xlims())
# plot!(2600:0.1:2620, Base.Fix2(f_bck, v_ml), yscale=:log10, label="Background")
# plot!(2600:0.1:2620, Base.Fix2(f_sig, v_ml), yscale=:log10, label="Signal")
# plot!(2600:0.1:2620, Base.Fix2(f_lowEtail, v_ml), yscale=:log10, label="Low-E tail")
# plot!(LinearAlgebra.normalize(peakhists[end], mode = :density), st = :stepbins, yscale = :log10, label="data")
# plot!(xlabel="Energy (keV)", ylabel="Counts", legend=:bottomright)

# half_max_sig = maximum(Base.Fix2(f_sigWithTail, v_ml).(2610:0.01:2620))/2
# fwhm_roots_low = find_zero(x -> Base.Fix2(f_sigWithTail, v_ml)(x) - half_max_sig, v_ml.μ - v_ml.σ)
# fwhm_roots_high = find_zero(x -> Base.Fix2(f_sigWithTail, v_ml)(x) - half_max_sig, v_ml.μ + v_ml.σ)
# fwhm = fwhm_roots_high - fwhm_roots_low

# vline!([fwhm_roots_low, fwhm_roots_high], label="FWHM")
# savefig("FEP_ch34.pdf")

ch = 27
println("Processing Channel $ch")
e_uncal = data[string(ch)]
nbins = 15000

# h_calsimple, h_uncal, c, fep_guess, peakhists, peakstats = LegendSpecFits.simpleCalibration(e_uncal::Array, th228_lines::Array)

h_uncal = fit(Histogram, e_uncal, nbins=nbins)

# th228_lines = [583.191, 727.330, 860.564, 2103.53, 2614.50]
th228_lines = [583.191, 727.330, 860.564, 1592.53, 1620.50, 2103.53, 2614.50]
fep_guess = quantile(e_uncal, 0.99)

plot(LinearAlgebra.normalize(h_uncal, mode = :density), st = :stepbins, yscale = :log10, label="Energy")
ylims!(0.2, maximum(LinearAlgebra.normalize(h_uncal, mode = :density).weights)*1.1)
y_vline = ylims()[1]:1:ylims()[2]
plot!(fill(fep_guess, length(y_vline)), y_vline, label="FEP Guess", legend=:topright, color="red", line_width=3.5)
xlabel!("Energy (ADC)")
ylabel!("Counts")
xticks!((0:3000:1.2*fep_guess, ["$i" for i in 0:3000:1.2*fep_guess]))
plot!(legend = :topright, title="Channel $ch")


c = 2614.5 / fep_guess
h_calsimple = fit(Histogram, e_uncal .* c, nbins=nbins)


plot(LinearAlgebra.normalize(h_calsimple, mode = :density), st = :stepbins, yscale = :log10, label="Energy")
ylims!(0.2, maximum(LinearAlgebra.normalize(h_calsimple, mode = :density).weights)*1.1)
y_vline = ylims()[1]:1:ylims()[2]
plot!(fill.(th228_lines, length(y_vline)), fill(y_vline, length(th228_lines)), label=hcat("Peak Positions", fill("", 1, length(th228_lines)-1)), color="green", line_width=2.5)
xlabel!("Energy (keV)")
ylabel!("Counts")
xlims!(0, 3000)
xticks!((0:200:3000, ["$i" for i in 0:200:3000]))
plot!(legend = :topright, title="Channel $ch")



peakhists = LegendSpecFits.subhist.(Ref(h_calsimple), (x -> (x-25, x+25)).(th228_lines))
peakstats = StructArray(estimate_single_peak_stats.(peakhists))

plot(
    plot.(LinearAlgebra.normalize.(peakhists, mode = :density), st = :stepbins, yscale = :log10, label="",
    titleloc=:right, titlefont=font(8))...;
    layout = @layout[grid(2,4)], margin=1mm, framestyle=:box, label_margin=0mm,
    grid=true, gridalpha=0.2, gridcolor=:black, gridlinewidth=0.5,
    xlabelfontsize=8, xlabelmargin=0mm,
    legend=:bottomright, figsize=(800, 400),
    xlabel="Energy (keV)", ylabel="Counts"
)

peak_fit_plots = Plots.Plot[]
fwhm_vals = Dict{Float64, Float64}()

f_fit(x, v) = gamma_peakshape(x, v.μ, v.σ, v.n, v.step_amplitude, v.skew_fraction, v.skew_width, v.background)
f_sig(x, v) = signal_peakshape(x, v.μ, v.σ, v.n, v.skew_fraction)
f_lowEtail(x, v) = lowEtail_peakshape(x, v.μ, v.σ, v.n, v.skew_fraction, v.skew_width)
f_bck(x, v) = background_peakshape(x, v.μ, v.σ, v.step_amplitude, v.background)
f_sigWithTail(x, v) = signal_peakshape(x, v.μ, v.σ, v.n, v.skew_fraction) + lowEtail_peakshape(x, v.μ, v.σ, v.n, v.skew_fraction, v.skew_width) 

for i in eachindex(peakhists)
    h = peakhists[i]
    ps = peakstats[i]

    pseudo_prior = NamedTupleDist(
        μ = Uniform(ps.peak_pos-10, ps.peak_pos+10),
        σ = weibull_from_mx(ps.peak_sigma, 2*ps.peak_sigma),
        n = weibull_from_mx(ps.peak_counts, 2*ps.peak_counts),
        step_amplitude = weibull_from_mx(ps.mean_background, 2*ps.mean_background),
        skew_fraction = Uniform(0.01, 0.25),
        skew_width = LogUniform(0.001, 0.1),
        background = weibull_from_mx(ps.mean_background, 2*ps.mean_background),
    )

    f_trafo = BAT.DistributionTransform(Normal, pseudo_prior)

    v_init = mean(pseudo_prior)

    f_loglike = let f_fit=f_fit, h=h
        v -> hist_loglike(Base.Fix2(f_fit, v), h)
    end

    opt_r = optimize((-) ∘ f_loglike ∘ inverse(f_trafo), f_trafo(v_init))
    v_ml = inverse(f_trafo)(Optim.minimizer(opt_r))
    showlegend = ifelse(i == 1, true, false)
    global v_ml = v_ml
    plt = plot(LinearAlgebra.normalize(h, mode = :density), st = :stepbins, yscale = :log10, label="Data", showlegend=showlegend, Layout=(width=800, height=800))
    plot!(minimum(h.edges[1]):0.1:maximum(h.edges[1]), Base.Fix2(f_fit, v_ml), label="Best Fit", showlegend=showlegend)
    xlims!(xlims())
    ylims!(ylims())
    plot!(minimum(h.edges[1]):0.1:maximum(h.edges[1]), Base.Fix2(f_sig, v_ml), label="Signal", showlegend=showlegend)
    plot!(minimum(h.edges[1]):0.1:maximum(h.edges[1]), Base.Fix2(f_lowEtail, v_ml), label="Low-E tail", showlegend=showlegend)
    plot!(minimum(h.edges[1]):0.1:maximum(h.edges[1]), Base.Fix2(f_bck, v_ml), label="Background", showlegend=showlegend)
    push!(peak_fit_plots, plt)

    half_max_sig = maximum(Base.Fix2(f_sigWithTail, v_ml).(v_ml.μ - v_ml.σ:0.001:v_ml.μ + v_ml.σ))/2
    roots_low = find_zero(x -> Base.Fix2(f_sigWithTail, v_ml)(x) - half_max_sig, v_ml.μ - v_ml.σ)
    roots_high = find_zero(x -> Base.Fix2(f_sigWithTail, v_ml)(x) - half_max_sig, v_ml.μ + v_ml.σ)
    fwhm_vals[th228_lines[i]] = roots_high - roots_low
end

plot(peak_fit_plots..., Layout=(width=8000, height=8000), margin=1mm, framestyle=:box, grid=true, gridalpha=0.2, gridcolor=:black, gridlinewidth=0.5, xlabelfontsize=8, xlabelmargin=0mm, legend=:bottomright)
plot!(legend=:bottomright, legendfontsize=8, legendfont=font(8), legendtitlefontsize=8, legendtitlefont=font(8))
plot!(xlabel="Energy (keV)", xlabelfontsize=6)
plot!(ylabel="Counts", ylabelfontsize=6)
plot!(margin=3mm, framestyle=:box)

plot(fwhm_vals, st=:scatter, label="FWHM Channel $ch", xlabel="Energy (keV)", xlabelfontsize=10, ylabel="FWHM (keV)", ylabelfontsize=10, legend=:topleft, legendfontsize=8, legendfont=font(8), legendtitlefontsize=8, legendtitlefont=font(8))

f_fwhm(x, p) = sqrt.(x.*p[2] .+ p[1])
fwhm_vals_noDEPSEP = filter(((k,v),) -> k != 1592.53 && k != 2103.53 && v > 0.0, fwhm_vals)
fwhm_fit_result = curve_fit(f_fwhm, collect(keys(fwhm_vals_noDEPSEP)), collect(values(fwhm_vals_noDEPSEP)), [1, 0.01])


fwhm_qbb = f_fwhm(2039, fwhm_fit_result.param)
fwhm_pars_rand = rand(MvNormal(fwhm_fit_result.param, estimate_covar(fwhm_fit_result)), 1000)
fwhm_qbb_rand = f_fwhm.(2039, eachcol(fwhm_pars_rand))
fwhm_qbb_err = std(fwhm_qbb_rand)

plot!(0:0.1:3000, x -> f_fwhm(x, fwhm_fit_result.param), label="Best Fit: Sqrt($(round(fwhm_fit_result.param[1], digits=2)) + x*$(round(fwhm_fit_result.param[2]*1e3, digits=2))e-3)", line_width=2, color=:red)
xlims!(0, 3000)
xticks!(0:200:3000)
vline!([2039], color=:green, label="")
hline!([fwhm_qbb], label="Qbb/keV: $(round(fwhm_qbb, digits=2))+-$(round(fwhm_qbb_err, digits=2))", color=:green)
hspan!([fwhm_qbb - fwhm_qbb_err, fwhm_qbb + fwhm_qbb_err], color=:green, alpha=0.2, label="")

