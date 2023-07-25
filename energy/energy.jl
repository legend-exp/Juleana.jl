# using LegendDataManagement, PropertyFunctions, TypedTables, PropDicts
# using Unitful, Formatting, LaTeXStrings, Measures
# using Plots, StatsBase
# using LegendHDF5IO, LegendDSP, LegendSpecFits
# using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked

# ENV["JULIA_DEBUG"] = Main # enable debug

# gr()
# # plotlyjs()

# @info "Loading Legend MetaData"
# l200 = LegendData(:l200)

# period = DataPeriod(3)
# run    = DataRun(1)


function process_energy(l200::LegendData, period::DataPeriod, run::DataRun)

    @info "Energy calibration for period $period and run $run"

    filekeys = sort(search_disk(FileKey, l200.tier[:raw, :cal, period, run]), by = x-> x.time)
    filekey = filekeys[1]
    @info "Found filekey $filekey"

    chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable)

    sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)

    @debug "Create Hit folder"
    hit_folder = l200.tier[:hit, :cal, period, run]
    ifelse(isdir(hit_folder), @debug("Hit folder $hit_folder already exists"), mkpath(hit_folder))

    @debug "Create figures folder"
    figures_folder = joinpath(l200.tier[:plt, :cal, period, run], "energy")
    ifelse(isdir(figures_folder), @debug("Figure folder $figures_folder already exists"), mkpath(figures_folder))

    for str in unique(chinfo.string)
        figures_folder_string = joinpath(figures_folder, format("string{:02d}", str))
        ifelse(isdir(figures_folder_string), @debug("String Figure folder $figures_folder_string already exists"), mkpath(figures_folder_string))
    end

    @debug "Create pars folder"
    pars_folder = joinpath(l200.tier[:par, :cal, period, run], "energy")
    ifelse(isdir(pars_folder), @debug("Pars folder $pars_folder already exists"), mkpath(pars_folder))

    @debug "Create pars db"
    pars_db = PropDict()

    for (i, ch_short) in enumerate(chinfo.channel)

        # i = 2
        # ch_short = chinfo.channel[i]
        ch = format("ch{}", ch_short)
        string_number = chinfo.string[i]
        det = chinfo.detector[i]

        figures_folder_string = joinpath(figures_folder, format("string{:02d}", string_number))

        @debug "Processing channel $ch ($det)"

        filename = joinpath(l200.tier[:qc, :cal, period, run], format("{}-{}-{}-{}-{}-tier_qc.lh5", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch))
        
        if !isfile(filename)
            @warn "File $(basename(filename)) does not exist, skip"
            continue
        end

        data = LHDataStore(filename, "r")

        @debug "Loading data from $(basename(filename))"
        dsp_data = data["$ch/after_qc"][:]

        if length(dsp_data) < 50000
            @warn "Not enough data points for channel $ch, skip"
            continue
        end

        if haskey(l200.metadata.dataprod.config.cal.energy(sel), det)
            energy_config = l200.metadata.dataprod.config.cal.energy(sel)[det]
            @debug "Use config for detector $det"
        else
            energy_config = l200.metadata.dataprod.config.cal.energy(sel).default
            @debug "Use default config"
        end
        
        th228_lines = Vector{Float64}(energy_config.th228_lines)
        th228_names = Dict{Float64, Symbol}(th228_lines .=> Symbol.(energy_config.th228_names))
        window_sizes = Vector{Float64}(energy_config.window_sizes)
        n_bins = energy_config.n_bins
        quantile_perc = energy_config.quantile_perc

        # get detector pars
        pars_det  = pars_db[det]

        @debug "Get simple calibration"
        
        result, report = simple_calibration(dsp_data.e_trap, th228_lines, window_sizes, n_bins=n_bins, quantile_perc=quantile_perc, calib_type=:th228)
        plot(report, cal=true, title=format("{} Simple Calibration ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))

        m_cal_simple = result.c
        savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-simple_calibration.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

        @debug "Fit all peaks"
        result, report = fit_peaks(report.peakhists, report.peakstats, th228_lines)

        peak_fit_plot = plot.(values(report), titleloc=:right, titlefont=font(8), ticks=:native, label="")
        for (i, p) in enumerate(peak_fit_plot)
            xticks!(p, convert(Int, round(xlims(p)[1], digits=0)):20:convert(Int, round(xlims(p)[2], digits=0)))
            title!(p, string(round(th228_lines[i], digits=2)) * " keV")
        end
        plot(
            peak_fit_plot...,
            layout = @layout[grid(3, 3)], 
            figsize=(1000, 800), legend = false,
            framestyle=:box, label_margin=0,
            grid=true, gridalpha=0.2, gridcolor=:black, gridlinewidth=0.5,
            xlabelfontsize=8, xlabelmargin=0,
            ylabelfontsize=8, ylabelmargin=0,
            xlabel="Energy (keV)", ylabel="Counts",
            dpi = 900
        )
            
        savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-peak_fits.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

        for (peak, peak_result) in result
            pars_det_peak = pars_det[th228_names[peak]]
            for param in keys(peak_result)
                if param == :err
                    for param_err in keys(peak_result[:err])
                        pars_det_peak[:err][param_err] = peak_result[:err][param_err]
                    end
                    continue
                end
                pars_det_peak[param] = peak_result[param]
            end
        end

        @debug "Get calibration values"
        μ = [result[p].μ for p in th228_lines] ./ m_cal_simple
        μ_err = [result[p].err.μ for p in th228_lines] ./ m_cal_simple

        m_calib, n_calib = fit_calibration(μ, th228_lines)
        @debug format("Found calibration curve: E[keV] = {:.2f} + {:.2f}*E[ADC]", n_calib, m_calib)

        pars_det.m_calib = m_calib
        pars_det.n_calib = n_calib

        scatter(μ, th228_lines, yerror=μ_err, ms=5, color=:black, markershape= :x, layout = @layout[grid(2, 1, heights=[0.8, 0.2])], link=:x, label="Peak Positions", xlabel="Energy (ADC)", xlabelfontsize=10, ylabel="Energy (keV)", ylabelfontsize=10, legend=:topleft, legendfontsize=8, legendfont=font(8), legendtitlefontsize=8, legendtitlefont=font(8), xlims = (0, 21000), xticks = (convert(Int, 0):3000:convert(Int, round(21000, digits=0))))
        plot!(ylims = (0, 3000), yticks = (0:200:3000), subplot=1, xlabel="", xticks = :none)
        plot!(0:1:20000, x -> m_calib* x + n_calib, label="Best Fit: $(round(n_calib, digits=2)) + x*$(round(m_calib, digits=2)))", line_width=2, color=:red, subplot=1, xformatter=_->"")
        plot!(μ, ((m_calib .* μ .+ n_calib) .- th228_lines) ./ th228_lines .* 100 , label="Residuals", ylabel="Residuals (%)", line_width=2, color=:black, st=:scatter, ylims = (-0.1, 0.1), markershape=:x, subplot=2)
        plot!(legend = :topright, title=format("{} Calibration Curve ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)), subplot=1)

        savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-calibration_curve.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

        fwhm     = ([result[p].fwhm for p in th228_lines] ./ m_cal_simple) .* m_calib .+ n_calib
        fwhm_err = ([result[p].err.fwhm for p in th228_lines] ./ m_cal_simple) .* m_calib .+ n_calib

        result, report = fit_fwhm(th228_lines, fwhm)
        @debug "Found FWHM: $(result.qbb) +- $(result.err.qbb)keV"

        scatter(th228_lines, fwhm, yerror=fwhm_err, ms=5, color=:black, markershape= :x, layout = @layout[grid(2, 1, heights=[0.8, 0.2])], link=:x, label="Best Fits", xlabel="Energy (keV)", xlabelfontsize=10, ylabel="FWHM (keV)", ylabelfontsize=10, legend=:topleft, legendfontsize=8, legendfont=font(8), legendtitlefontsize=8, legendtitlefont=font(8), xlims = (0, 3000), xticks = (convert(Int, 0):300:convert(Int, round(3000, digits=0))))
        plot!(0:0.1:3000, x -> report.f_fit(x), label="Best Fit: Sqrt($(round(report.v[1], digits=2)) + x*$(round(report.v[2]*100, digits=2))e-3)", line_width=2, color=:red, subplot=1)
        hline!([result.qbb], label="Qbb/keV: $(round(result.qbb, digits=2))+-$(round(result.err.qbb, digits=2))", color=:green)
        hspan!([result.qbb - result.err.qbb, result.qbb + result.err.qbb], color=:green, alpha=0.2, label="")
        plot!(th228_lines, ((report.f_fit.(th228_lines) .- fwhm) ./ fwhm) .* 100 , label="Residuals", ylabel="Residuals (%)", line_width=2, color=:black, st=:scatter, ylims = (-10, 10), markershape=:x, legend=:none, subplot=2)

        savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-fwhm.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

        pars_det.fwhm_qbb     = result.qbb
        pars_det.fwhm_qbb_err = result.err.qbb
        pars_det.fwhm_pars    = result.v
    end

    # # save pars to disk
    @info "Save pars to disk"
    pars_filename       = format("{}-{}-{}-{}-energy.json", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category))
    pars_validTimeStamp = string(filekey.time)
    # write params
    writeprops(joinpath(pars_folder, pars_filename), pars_db, multiline=true)
    # write validity
    open(joinpath(pars_folder, "validity.jsonl"), "a") do io
        println(io, "{\"valid_from\":\"$pars_validTimeStamp\", \"category\":\"all\", \"apply\":[\"$pars_filename\"]}")
    end
end