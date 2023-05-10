include("../utils/packages.jl")
include("../utils/loader.jl")
include("../utils/saver.jl")


function fitChannel(e_uncal::Array, ch::String, th228_lines::Array, window_size::Float64, n_bins::Integer, string_energy_figure_folder::PosixPath, label_Ext::String; save_fig::Bool=true, quantile_perc::Float64=0.995)

    # get simple calibration by searching for FEP peak with 99% quantile
    h_calsimple, h_uncal, c, fep_guess, peakhists, peakstats = simpleCalibration(Array(e_uncal), th228_lines, window_size=window_size, n_bins=n_bins, calib_type="th228", quantile_perc=quantile_perc)

    # Plot uncalibrated energy histogram
    plot(LinearAlgebra.normalize(h_uncal, mode = :density), st = :stepbins, yscale = :log10, label="Energy")
    ylims!(0.2, maximum(LinearAlgebra.normalize(h_uncal, mode = :density).weights)*1.1)
    y_vline = ylims()[1]:1:ylims()[2]
    plot!(fill(fep_guess, length(y_vline)), y_vline, label="FEP Guess", legend=:topright, color="red", line_width=3.5)
    xlabel!("Energy (ADC)")
    ylabel!("Counts")
    xticks!((0:3000:1.2*fep_guess, ["$i" for i in 0:3000:1.2*fep_guess]))
    xlims!(0, 1.2*fep_guess)
    plot!(legend = :topright, title="Channel $ch ($label_Ext)")
    if save_fig
        savefig(joinpath(string_energy_figure_folder, format("{}_uncalibrated_channel.pdf", ch)))
    end

    # Plot calibrated energy histogram
    plot(LinearAlgebra.normalize(h_calsimple, mode = :density), st = :stepbins, yscale = :log10, label="Energy")
    ylims!(1, maximum(LinearAlgebra.normalize(h_calsimple, mode = :density).weights)*1.1)
    y_vline = ylims()[1]:1:ylims()[2]
    plot!(fill.(th228_lines, length(y_vline)), fill(y_vline, length(th228_lines)), label=hcat("Peak Positions", fill("", 1, length(th228_lines)-1)), color="green", line_width=2.5)
    xlabel!("Energy (keV)")
    ylabel!("Counts")
    xlims!(0, 3000)
    xticks!((0:200:3000, ["$i" for i in 0:200:3000]))
    plot!(legend = :topright, title="Channel $ch ($label_Ext)")
    if save_fig
        savefig(joinpath(string_energy_figure_folder, format("{}_simpleCalibrated.pdf", ch)))
    end

    # Plot peak histograms
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
    if save_fig
        savefig(joinpath(string_energy_figure_folder, format("{}_peaks_channel.pdf", ch)))
    end

    try 
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
        if save_fig
            savefig(joinpath(string_energy_figure_folder, format("{}_peaks_fit_channel.pdf", ch)))
        end

        # fit calibration function
        calib_vals = Dict(collect(keys(peak_fit_vals)) .=> [val.μ for val in values(peak_fit_vals)]./c)
        calib_slope, calib_intercept = fitCalibration(calib_vals)
        plot(calib_vals, st=:scatter, layout = @layout[grid(2, 1, heights=[0.8, 0.2])], link=:x, label="FWHM Channel $ch", xlabel="Energy (keV)", xlabelfontsize=10, ylabel="Energy (ADC)", ylabelfontsize=10, legend=:topleft, legendfontsize=8, legendfont=font(8), legendtitlefontsize=8, legendtitlefont=font(8))
        xlims!(0, 3000)
        xticks!(0:200:3000)
        plot!(0:0.1:3000, x -> calib_slope* x + calib_intercept, label="Best Fit: $(round(calib_intercept, digits=2)) + x*$(round(calib_slope, digits=2)))", line_width=2, color=:red, subplot=1, xformatter=_->"")
        plot!(collect(keys(calib_vals)), x -> ((calib_slope* x + calib_intercept) - calib_vals[x])/calib_vals[x]*100 , label="Residuals", ylabel="Residuals (%)", line_width=2, color=:red, st=:scatter, subplot=2)
        plot!(legend = :topright, title="Channel $ch ($label_Ext)")
        if save_fig
            savefig(joinpath(string_energy_figure_folder, format("{}_calibrationCurve_channel.pdf", ch)))
        end

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
        plot!(legend = :topright, title="Channel $ch ($label_Ext)")
        if save_fig
            savefig(joinpath(string_energy_figure_folder, format("{}_fwhm_channel.pdf", ch)))
        end

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
        plot!(legend = :topright, title="Channel $ch ($label_Ext)")
        if save_fig 
            savefig(joinpath(string_energy_figure_folder, format("{}_energy_channel.pdf", ch)))
        end
        
        return calib_slope, calib_intercept, fwhm_qbb, fwhm_qbb_err, fwhm_vals
    catch e
        println("Error in channel $ch: $e")
        println("Could not calibrate and fit peaks")

        return NaN, NaN, NaN, NaN, NaN
    end
end


is_cal = true
period = 2
calrun = 19
config_folder = p"/home/iwsatlas1/henkes/l200/l200-p02-analysis/configs/"
experiment = "l200"
println("Start Energy for $experiment, period $period, run $calrun")
println("Loading meta data")

channel_list, label_dict, label_list_ext, string_dict, folder_dict = loadMeta(config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)

energy_figure_folder = joinpath(folder_dict["folder_figures"], "energy")
checkFolder(PosixPath(energy_figure_folder), true)

# Load data
println("Open data")
folder_hit = folder_dict["folder_hit"]
filename = joinpath(folder_hit, format("{}-p{:02d}-r{:03d}-cal-tier_hit.lh5", experiment, period, calrun))
data = LHDataStore(filename, "cw")

# th-228 lines in keV
th228_lines = [583.191, 727.330, 860.564, 1592.53, 1620.50, 2103.53, 2614.50]

# window size aroung gamma lines
window_size = 20.0

# create save dict for calibration values
m_calib_dict = Dict{String, Float32}()
n_calib_dict = Dict{String, Float32}()

# create save dicts for FWHM values
fwhm_qbb_dict     = Dict{String, Float32}()
fwhm_qbb_err_dict = Dict{String, Float32}()
fwhm_fep_dict     = Dict{String, Float32}()
fwhm_sep_dict     = Dict{String, Float32}()
fwhm_dep_dict     = Dict{String, Float32}()
fwhm_bifep_dict   = Dict{String, Float32}()

# Fit strings
for (string_number, string_channel_list) in string_dict

    printfmtln("Processing string number: {}", string_number)
    println()
    println()
    println("Check figure folder")
    string_energy_figure_folder = joinpath(energy_figure_folder, format("string{}", string_number))
    checkFolder(PosixPath(string_energy_figure_folder), true)
    println()
    println()

    for (i, ch) in enumerate(string_channel_list)
        println("Processing Channel $ch")
        label_ext = label_list_ext[ch]

        data_ch = data[ch]
        e_uncal = Array(data_ch.e)
        if isempty(e_uncal)
            println("No data for channel $ch")
            println()
            continue
        end
        n_bins = 10000
        calib_slope, calib_intercept, fwhm_qbb, fwhm_qbb_err, fwhm_vals = fitChannel(e_uncal, ch, th228_lines, window_size, n_bins, PosixPath(string_energy_figure_folder), label_ext)
        if isnan(calib_slope)
            n_bins = 8000
            println("Try nbins $n_bins")
            println()
            calib_slope, calib_intercept, fwhm_qbb, fwhm_qbb_err, fwhm_vals = fitChannel(e_uncal, ch, th228_lines, window_size, n_bins, PosixPath(string_energy_figure_folder), label_ext)
        end
        if isnan(calib_slope)
            quantile_perc = 0.99
            println("Try quantile $quantile_perc")
            println()
            calib_slope, calib_intercept, fwhm_qbb, fwhm_qbb_err, fwhm_vals = fitChannel(e_uncal, ch, th228_lines, window_size, n_bins, PosixPath(string_energy_figure_folder), label_ext, save_fig=true, quantile_perc=quantile_perc)
        end
        println("Calibration slope: $calib_slope")
        println("Calibration intercept: $calib_intercept")
        printfmtln("FWHM Qbb: {:.2f}keV +- {:.2f}keV", fwhm_qbb, fwhm_qbb_err)

        # save values to dict
        m_calib_dict[label_dict[ch]]      = calib_slope
        n_calib_dict[label_dict[ch]]      = calib_intercept
        fwhm_qbb_dict[label_dict[ch]]     = fwhm_qbb
        fwhm_qbb_err_dict[label_dict[ch]] = fwhm_qbb_err
        try
            fwhm_fep_dict[label_dict[ch]]     = fwhm_vals[2614.50]
            fwhm_sep_dict[label_dict[ch]]     = fwhm_vals[2103.53]
            fwhm_dep_dict[label_dict[ch]]     = fwhm_vals[1592.53]
            fwhm_bifep_dict[label_dict[ch]]   = fwhm_vals[1620.50]
        catch
            fwhm_fep_dict[label_dict[ch]]     = 0.0
            fwhm_sep_dict[label_dict[ch]]     = 0.0
            fwhm_dep_dict[label_dict[ch]]     = 0.0
            fwhm_bifep_dict[label_dict[ch]]   = 0.0
        end

        println()
    end
end


println()
println()
println()
println()
println("Save energy FWHM values to metadata")
saveValues(m_calib_dict, "m_calib", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
saveValues(n_calib_dict, "n_calib", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
saveValues(fwhm_qbb_dict, "fwhm_qbb", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
saveValues(fwhm_qbb_err_dict, "fwhm_qbb_err", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
saveValues(fwhm_fep_dict, "fwhm_fep", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
saveValues(fwhm_sep_dict, "fwhm_sep", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
saveValues(fwhm_dep_dict, "fwhm_dep", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
saveValues(fwhm_bifep_dict, "fwhm_bifep", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
println()
println()
println()
println("Finished energy calibration for period $period, calrun $calrun")




