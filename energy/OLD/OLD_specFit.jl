include("../utils/packages.jl")
include("../utils/loader.jl")
include("../utils/saver.jl")

gr()
histograms_folder = "/remote/ceph2/group/legendex/data/l60/r025/julia/cal/histograms/"
histograms_filename = joinpath(histograms_folder, "energy_histograms.h5")
figure_folder = "/remote/ceph2/group/legendex/data/l60/r025/julia/cal/figures/energy/string1/"
data = LHDataStore(string(histograms_filename), "r")


n_bins = 15000
th228_lines = [583.191, 727.330, 860.564, 1592.53, 1620.50, 2103.53, 2614.50]
window_size = 20.0
for ch in keys(data)
    println("Processing Channel $ch")
    e_uncal = data[string(ch)]

    # get simple calibration by searching for FEP peak with 99% quantile
    h_calsimple, h_uncal, c, fep_guess, peakhists, peakstats = simpleCalibration(Array(e_uncal), th228_lines, window_size=window_size, n_bins=n_bins, calib_type="th228")

    # Plot uncalibrated energy histogram
    plot(LinearAlgebra.normalize(h_uncal, mode = :density), st = :stepbins, yscale = :log10, label="Energy")
    ylims!(0.2, maximum(LinearAlgebra.normalize(h_uncal, mode = :density).weights)*1.1)
    y_vline = ylims()[1]:1:ylims()[2]
    plot!(fill(fep_guess, length(y_vline)), y_vline, label="FEP Guess", legend=:topright, color="red", line_width=3.5)
    xlabel!("Energy (ADC)")
    ylabel!("Counts")
    xticks!((0:3000:1.2*fep_guess, ["$i" for i in 0:3000:1.2*fep_guess]))
    xlims!(0, 1.2*fep_guess)
    plot!(legend = :topright, title="Channel $ch")
    savefig(joinpath(figure_folder, "uncalibrated_channel_$ch.pdf"))

    # Plot calibrated energy histogram
    plot(LinearAlgebra.normalize(h_calsimple, mode = :density), st = :stepbins, yscale = :log10, label="Energy")
    ylims!(1, maximum(LinearAlgebra.normalize(h_calsimple, mode = :density).weights)*1.1)
    y_vline = ylims()[1]:1:ylims()[2]
    plot!(fill.(th228_lines, length(y_vline)), fill(y_vline, length(th228_lines)), label=hcat("Peak Positions", fill("", 1, length(th228_lines)-1)), color="green", line_width=2.5)
    xlabel!("Energy (keV)")
    ylabel!("Counts")
    xlims!(0, 3000)
    xticks!((0:200:3000, ["$i" for i in 0:200:3000]))
    plot!(legend = :topright, title="Channel $ch")
    savefig(joinpath(figure_folder, "simpleCalibrated_channel_$ch.pdf"))

    # Plot peak histograms
    gr()
    hist_plots = plot.(LinearAlgebra.normalize.(peakhists, mode = :density), st = :stepbins, yscale = :log10, label="",
    titleloc=:right, titlefont=font(8), ticks=:native)
    for (i, p) in enumerate(hist_plots)
        xticks!(p, convert(Int, round(xlims(p)[1], digits=0)):20:convert(Int, round(xlims(p)[2], digits=0)))
        title!(p, string(round(th228_lines[i], digits=2)) * " keV")
    end

    plot(
        hist_plots...,
        layout = @layout[grid(2, 4)], margin=0.5mm, framestyle=:box, label_margin=0mm,
        grid=true, gridalpha=0.2, gridcolor=:black, gridlinewidth=0.5,
        xlabelfontsize=8, xlabelmargin=0mm,
        ylabelfontsize=8, ylabelmargin=0mm,
        legend=:bottomright, figsize=(1000, 800),
        xlabel="Energy (keV)", ylabel="Counts",
    )
    savefig(joinpath(figure_folder, "peaks_channel_$ch.pdf"))

    # fit Peaks with Raddford peak shape
    peak_fit_plots, peak_fit_vals = fitPeaks(peakhists, peakstats, th228_lines)
    peak_fit_plot = plot.(peak_fit_plots, titleloc=:right, titlefont=font(8), ticks=:native, label="")
    for (i, p) in enumerate(peak_fit_plot)
        xticks!(p, convert(Int, round(xlims(p)[1], digits=0)):20:convert(Int, round(xlims(p)[2], digits=0)))
        title!(p, string(round(th228_lines[i], digits=2)) * " keV")
    end
    plot(
        peak_fit_plot...,
        layout = @layout[grid(3, 3)], margin=0.1mm, framestyle=:box, label_margin=0mm,
        grid=true, gridalpha=0.2, gridcolor=:black, gridlinewidth=0.5,
        xlabelfontsize=8, xlabelmargin=0mm,
        ylabelfontsize=8, ylabelmargin=0mm,
        figsize=(1000, 800), legend=:none,
        xlabel="Energy (keV)", ylabel="Counts",
    )
    savefig(joinpath(figure_folder, "peaks_fit_channel_$ch.pdf"))

    # fit calibration function
    calib_vals = Dict(collect(keys(peak_fit_vals)) .=> [val.μ for val in values(peak_fit_vals)]./c)
    calib_slope, calib_intercept = fitCalibration(calib_vals)
    plot(calib_vals, st=:scatter, layout = @layout[grid(2, 1, heights=[0.8, 0.2])], link=:x, label="FWHM Channel $ch", xlabel="Energy (keV)", xlabelfontsize=10, ylabel="Energy (ADC)", ylabelfontsize=10, legend=:topleft, legendfontsize=8, legendfont=font(8), legendtitlefontsize=8, legendtitlefont=font(8))
    xlims!(0, 3000)
    xticks!(0:200:3000)
    plot!(0:0.1:3000, x -> calib_slope* x + calib_intercept, label="Best Fit: $(round(calib_intercept, digits=2)) + x*$(round(calib_slope, digits=2)))", line_width=2, color=:red, subplot=1, xformatter=_->"")
    plot!(collect(keys(calib_vals)), x -> ((calib_slope* x + calib_intercept) - calib_vals[x])/calib_vals[x]*100 , label="Residuals", ylabel="Residuals (%)", line_width=2, color=:red, st=:scatter, subplot=2)
    savefig(joinpath(figure_folder, "calibration_channel_$ch.pdf"))

    # plot resulting FWHM values
    fwhm_vals = Dict(collect(keys(peak_fit_vals)) .=> [val.fwhm for val in values(peak_fit_vals)])
    plot(fwhm_vals, st=:scatter, label="FWHM Channel $ch", xlabel="Energy (keV)", xlabelfontsize=10, ylabel="FWHM (keV)", ylabelfontsize=10, legend=:topleft, legendfontsize=8, legendfont=font(8), legendtitlefontsize=8, legendtitlefont=font(8))

    # fit FWHM vals with square root function
    fwhm_fit_param, fwhm_qbb, fwhm_qbb_err = fitFWHM(fwhm_vals)
    plot!(0:0.1:3000, x -> LegendSpecFits.f_fwhm(x, fwhm_fit_param), label="Best Fit: Sqrt($(round(fwhm_fit_param[1], digits=2)) + x*$(round(fwhm_fit_param[2]*1e3, digits=2))e-3)", line_width=2, color=:red)
    xlims!(0, 3000)
    xticks!(0:200:3000)
    vline!([2039], color=:green, label="")
    hline!([fwhm_qbb], label="Qbb/keV: $(round(fwhm_qbb, digits=2))+-$(round(fwhm_qbb_err, digits=2))", color=:green)
    hspan!([fwhm_qbb - fwhm_qbb_err, fwhm_qbb + fwhm_qbb_err], color=:green, alpha=0.2, label="")
    savefig(joinpath(figure_folder, "fwhm_channel_$ch.pdf"))

    # plot cailbrated energy histogram
    e_cal = (e_uncal .- calib_intercept)./calib_slope
    h_cal = fit(Histogram, e_cal[e_cal .< 3000] , nbins=3000)
    plot(LinearAlgebra.normalize(h_cal, mode = :density), st = :stepbins, yscale = :log10, label="Energy")
    ylims!(1, maximum(LinearAlgebra.normalize(h_cal, mode = :density).weights)*1.1)
    y_vline = ylims()[1]:1:ylims()[2]
    plot!(fill.(th228_lines, length(y_vline)), fill(y_vline, length(th228_lines)), label=hcat("Peak Positions", fill("", 1, length(th228_lines)-1)), color="green", line_width=2.5)
    xlabel!("Energy (keV)")
    ylabel!("Counts")
    xlims!(0, 3000)
    xticks!((0:200:3000, ["$i" for i in 0:200:3000]))
    plot!(legend = :topright, title="Channel $ch")
    savefig(joinpath(figure_folder, "calibrated_channel_$ch.pdf"))
end

