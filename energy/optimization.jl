include("../utils/packages.jl")
include("../utils/loader.jl")
include("../utils/saver.jl")

function fitChannel(e_uncal::Array, ch::Int, ft::String, th228_lines::Array, window_size::Float64, n_bins::Integer, figure_folder::PosixPath, label::String, label_Ext::String, save_fig::Bool=true)

    # get simple calibration by searching for FEP peak with 99% quantile
    h_calsimple, h_uncal, c, fep_guess, peakhists, peakstats = simpleCalibration(Array(e_uncal), th228_lines, window_size=window_size, n_bins=n_bins, calib_type="th228")

    # # Plot calibrated energy histogram
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
        savefig(joinpath(figure_folder, "FT$ft _simpleCalibrated_channel_$ch.pdf"))
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
        ifelse(save_fig, savefig(joinpath(figure_folder, "FT$ft _peaks_fit_channel_$ch.pdf")), 0)

        # fit calibration function
        calib_vals = Dict(collect(keys(peak_fit_vals)) .=> [val.μ for val in values(peak_fit_vals)]./c)
        calib_slope, calib_intercept = fitCalibration(calib_vals)

        # plot resulting FWHM values
        fwhm_vals = Dict(collect(keys(peak_fit_vals)) .=> [val.fwhm for val in values(peak_fit_vals)])
        plot(fwhm_vals, st=:scatter, label="FWHM Channel $ch (FT $ft)", xlabel="Energy (keV)", xlabelfontsize=10, ylabel="FWHM (keV)", ylabelfontsize=10, legend=:topleft, legendfontsize=8, legendfont=font(8), legendtitlefontsize=8, legendtitlefont=font(8))

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
            savefig(joinpath(figure_folder, "FT$ft _fwhm_channel_$ch.pdf"))
        end
        
        return fwhm_qbb, fwhm_qbb_err
    catch e
        println("Error in channel $ch: $e")
        println("Could not calibrate and fit peaks")

        return 100, 100
    end
end

optimnization_figure_folder = joinpath(figure_folder, "optimization")
checkFolder(optimnization_figure_folder, true)

string_number = 1

# energy grids
e_grid_rt = 1u"µs":0.5u"µs":12u"µs"
e_grid_ft = 1u"µs":0.2u"µs":4u"µs"

# number bins, gamma lines and window size for cailbrations
n_bins = 15000
th228_lines = [583.191, 727.330, 860.564, 1592.53, 1620.50, 2103.53, 2614.50]
window_size = 20.0

# use fixed window around 0 for all fits
max_enc = 10

# dict to save values
best_rt_ft_strings = Dict{Int, Any}()

for string_number in string_numbers
    println("Processing String $string_number")
    println()
    println()
    println("Check figure folder")
    string_optimnization_figure_folder = joinpath(optimnization_figure_folder, format("string{}", string_number))
    checkFolder(string_optimnization_figure_folder, true)
    println()
    println()

    dsp_data, channel_list, label_listExt, label_list = data_strings[string_number]

    # perform RT optimization first at fixed flat top time
    f = length(e_grid_ft)

    # store dict for all best rise time (RT) values at min(ENC)
    best_rt = Dict{Int, Any}()

    println("Start rise time optimization")

    for (i, ch) in enumerate(channel_list)
        println("Process Channel $ch")
        data_ch = dsp_data[ch]
        qc_ch = qc_cuts[string_number][ch]
        label = label_list[i]
        label_Ext = label_listExt[i]

        if !(all(data_ch.timestamp .== qc_ch.timestamp))
            error("Timestamps do not match")
            continue
        end

        e_grid_ch = data_ch.e_grid[qc_ch.qc]
        enc_grid_ch = data_ch.enc_grid[qc_ch.qc]


        rt_variation_plots = Plots.Plot[]
        rt_enc_sigma = zeros(length(e_grid_rt))

        for (r, rt) in enumerate(e_grid_rt)
            # println("Risetime $rt")

            enc_rt = flatview(enc_grid_ch)[f, r, :]

            d = fit(Normal, enc_rt[enc_rt .> -max_enc .&& enc_rt .< max_enc])

            p = histogram(enc_rt[enc_rt .> -max_enc .&& enc_rt .< max_enc], normalize=:pdf, bins=1000, title="ENC RT $rt", legend=:topright, xlabel="ENC (ADC)", ylabel="Counts")
            xlims!(-max_enc, max_enc)
            plot!(Normal(d.μ, d.σ), label=format("ENC Fit (µ = {:.2f}, σ = {:.2f})", d.μ, d.σ), color="red", line_width=3.5)
            plot!(legend=:bottomright)
            push!(rt_variation_plots, p)

            rt_enc_sigma[r] = d.σ
        end

        plot(rt_variation_plots..., legend=:none,
        layout = @layout[grid(7, 4)], margin=0.1mm, framestyle=:box, label_margin=0mm,
        grid=true, gridalpha=0.2, gridcolor=:black, gridlinewidth=0.5,
        xlabelfontsize=8, xlabelmargin=0mm, ylabelfontsize=8, ylabelmargin=0mm, titlefontsize=8, xlabel="", figsize=(2000, 800))
        savefig(joinpath(string_optimnization_figure_folder, format("allRT_variation_ch{}.pdf", ch)))

        min_enc = minimum(rt_enc_sigma[rt_enc_sigma .> 0])
        min_enc_rt = e_grid_rt[rt_enc_sigma .> 0][findmin(rt_enc_sigma[rt_enc_sigma .> 0])[2]]
        best_rt[ch] = min_enc_rt

        scatter(e_grid_rt[rt_enc_sigma .> 0], rt_enc_sigma[rt_enc_sigma .> 0], xlabel="Risetime", ylabel="ENC Noise (ADC)", label="ENC Noise", grid=true, gridalpha=0.2, gridcolor=:black, gridlinewidth=0.5)
        hline!([min_enc], label=format("Min. ENC Noise (RT: {})", min_enc_rt), color="red", line_width=5)
        plot!(title="Channel $ch ($label_Ext)", legend=:topright)
        savefig(joinpath(string_optimnization_figure_folder, format("BestRT_ch{}_enc.pdf", ch)))
    end

    

    # store dict for all best flat top time (FT) values at min(FWHM)
    best_ft = Dict{Int, Any}()

    for (i, ch) in enumerate(channel_list)

        println("Process Channel $ch")
        data_ch = dsp_data[ch]
        qc_ch = qc_cuts[string_number][ch]
        label = label_list[i]
        label_Ext = label_listExt[i]

        if !(all(data_ch.timestamp .== qc_ch.timestamp))
            error("Timestamps do not match")
            continue
        end

        e_grid_ch = data_ch.e_grid[qc_ch.qc]
        enc_grid_ch = data_ch.enc_grid[qc_ch.qc]

        rt = best_rt[ch]
        r  = findfirst(x -> x == rt, e_grid_rt)

        ft_e_fwhm     = zeros(length(e_grid_ft))
        ft_e_fwhm_err = zeros(length(e_grid_ft))

        println("Best Risetime $rt")

        for (f, ft) in enumerate(e_grid_ft)
            println("Flat-top time $ft")

            e_uncal_ft_ch = Array(flatview(e_grid_ch)[f, r, :])

            fwhm_qbb, fwhm_qbb_err = fitChannel(e_uncal_ft_ch[.!isnan.(e_uncal_ft_ch)], ch, string(ft), th228_lines, window_size, n_bins, string_optimnization_figure_folder, label, label_Ext, true)

            ft_e_fwhm[f]     = fwhm_qbb
            ft_e_fwhm_err[f] = fwhm_qbb_err
        end

        try 
            min_fwhm = minimum(ft_e_fwhm[ft_e_fwhm .> 0])
            min_fwhm_ft = e_grid_ft[ft_e_fwhm .> 0][findmin(ft_e_fwhm[ft_e_fwhm .> 0])[2]]
            best_ft[ch] = min_fwhm_ft

            scatter(e_grid_ft[ft_e_fwhm .== 100], ft_e_fwhm[ft_e_fwhm .== 100], yerr=ft_e_fwhm_err, xlabel="Flat Top Time", ylabel=L"FWHM $Q_{\beta\beta}$ (keV)", label="FWHM", grid=true, gridalpha=0.2, gridcolor=:black, gridlinewidth=0.5)
            hline!([min_fwhm], label=format("Min. FWHM (FT: {})", min_fwhm_ft), color="red", line_width=5)
            vline!([min_fwhm_ft], label="", showlegend=:false, color="red", line_width=5)
            ylims!(1, 5)
            plot!(title="Channel $ch ($label_Ext)", legend=:topright)
            savefig(joinpath(string_optimnization_figure_folder, format("BestFT_ch{}_fwhm.pdf", ch)))
        catch e
            println("Error in Channel $ch: $e")
        end

    end

    # save all best values in dict
    best_rt_ft_strings[string_number] = [best_rt, best_ft]
end

# save all best values to JSON
best_rt_channels = Dict{Int, Float32}()
best_ft_channels = Dict{Int, Float32}()
for (key, val) in best_rt_ft_strings
    for (ch, rt) in val[1]
        best_rt_channels[ch] = uconvert(NoUnits, rt/1u"µs")
    end
    for (ch, ft) in val[2]
        best_ft_channels[ch] = uconvert(NoUnits, ft/1u"µs")
    end
end

results_folder = "/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts/results/"

out_json_rt = JSON.json(best_rt_channels, 4)
open(joinpath(results_folder, "best_rt.json"), "w") do io
    write(io, out_json_rt, 4)
end

out_json_ft = JSON.json(best_ft_channels, 4)
open(joinpath(results_folder, "best_ft.json"), "w") do io
    write(io, out_json_ft, 4)
end

JSON.parsefile(joinpath(results_folder, "best_rt.json"))
