# using LegendDataManagement, PropertyFunctions, TypedTables, PropDicts
# using Unitful, Formatting, LaTeXStrings, Measures
# using Plots, StatsBase
# using LegendHDF5IO, LegendDSP, LegendSpecFits
# using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked

# ENV["JULIA_DEBUG"] = Main # enable debug

# gr()
# # plotlyjs(size=(800, 500))
# # plotlyjs(size=(1200, 800))

# @info "Loading Legend MetaData"
# l200 = LegendData(:l200)

# period = DataPeriod(3)
# run    = DataRun(1)
# reprocess = true


function process_energy_calibration(l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=300)
    @info "Energy calibration for period $period and run $run"

    filekeys = sort(search_disk(FileKey, l200.tier[:raw, :cal, period, run]), by = x-> x.time)
    filekey = filekeys[1]
    @info "Found filekey $filekey"

    chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable && $usability)

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

    @debug "Create logs folder"
    log_folder = joinpath(l200.tier[:log, :cal, period, run])
    ifelse(isdir(log_folder), @debug("Log folder $log_folder already exists"), mkpath(log_folder))

    @debug "Create pars db"
    pars_db = PropDict()
    # read params if exist
    if !(haskey(l200.par[:cal, :energy], Symbol(period)))
        # path folder for current period seems not to exist, will create it first to avoid errors
        mkpath(joinpath(l200.tier[:par, :cal], "energy", "$period"))
        # write validity
        pars_validTimeStamp = string(filekey.time)
        open(joinpath(l200.tier[:par, :cal], "energy", "validity.jsonl"), "a") do io
            println(io, "{\"valid_from\":\"$pars_validTimeStamp\", \"category\":\"all\", \"apply\":[\"$period/$run.json\"]}")
        end
    elseif haskey(l200.par[:cal, :energy, period], Symbol(run))
        @info "Pars file already exists."
        pars_db = l200.par[:cal, :energy, period, run]
    else
        # write validity
        pars_validTimeStamp = string(filekey.time)
        open(joinpath(l200.tier[:par, :cal], "energy", "validity.jsonl"), "a") do io
            println(io, "{\"valid_from\":\"$pars_validTimeStamp\", \"category\":\"all\", \"apply\":[\"$period/$run.json\"]}")
        end
    end

    if reprocess
        @info "Reprocess all channels"
        for det in keys(pars_db)
            pars_db[det].energy = nothing
        end
        PropDicts.trim_null!(pars_db)
    else
        @info "Only reprocess channels that are not in pars_db"
    end

    # move all variables to workers
    @everywhere begin
        l200 = $l200
        sel = $sel
        filekey = $filekey
        filekeys = $filekeys
        chinfo = $chinfo
        figures_folder = $figures_folder
        hit_folder = $hit_folder
        pars_db = $pars_db
        reprocess = $reprocess
    end
    # for (i, ch_short) in enumerate(chinfo.channel)

    @everywhere function ch_energy_calibration(i::Int64)
        
        ch_short = chinfo.channel[i]
        ch = format("ch{}", ch_short)
        string_number = chinfo.string[i]
        det = chinfo.detector[i]

        if !reprocess && haskey(pars_db, det) && haskey(pars_db[det], :energy)
            @debug "Channel $(chinfo.detector[i]) already processed, skip"
            log_info = "| $ch | $det | Success | $(round(pars_db[det].energy.fwhm_qbb, digits=2))±$(round(pars_db[det].energy.fwhm_qbb_err, digits=2)) | $(round(pars_db[det].energy[:Tl208FEP].fwhm, digits=2))±$(round(pars_db[det].energy[:Tl208FEP].err.fwhm, digits=2)) | $(round(pars_db[det].energy.m_calib, digits=2)) | Already processed --> skipped. |"
            return (result = (m_calib = NaN, ), log = log_info)
        end

        figures_folder_string = joinpath(figures_folder, format("string{:02d}", string_number))

        @debug "Processing channel $ch ($det)"

        ch_filekeys = Vector{FileKey}()
        for fk in filekeys
            if !isfile(l200.tier[:dsp, fk])
                @warn "File $(basename(l200.tier[:dsp, fk])) does not exist, skip"
                continue
            end
            if !haskey(LHDataStore(l200.tier[:dsp, fk], "r"), ch)
                @warn "Channel $ch not found in $(basename(l200.tier[:dsp, fk])), skip"
                continue
            end
            push!(ch_filekeys, fk)
        end

        if isempty(ch_filekeys)
            @error "No valid filekeys found for channel $ch ($det), skip"
            throw(LoadError("$det", 154,"No filekeys found for channel $ch ($det)"))
        end
        yield()

        data_ch = fast_flatten([
            LHDataStore(
                ds -> begin
                    # @debug "Reading from \"$(ds.data_store.filename)\""
                    ds[ch][:]
                end,
                l200.tier[:dsp, fk]
            ) for fk in ch_filekeys
        ])
        yield()
        
        if length(data_ch) < 50000
            @error "Not enough data points for channel $ch ($det), skip"
            throw(ErrorException("Not enough data points for channel $ch ($det)"))
        end

        if haskey(l200.metadata.dataprod.config.cal.energy(sel), det)
            energy_config = merge(l200.metadata.dataprod.config.cal.energy(sel).default, l200.metadata.dataprod.config.cal.energy(sel)[det])
            @debug "Use config for detector $det"
        else
            energy_config = l200.metadata.dataprod.config.cal.energy(sel).default
            @debug "Use default config"
        end

        if haskey(l200.metadata.dataprod.config.cal.qc(sel), det)
            qc_config = merge(l200.metadata.dataprod.config.cal.qc(sel).default, l200.metadata.dataprod.config.cal.qc(sel)[det])
            @debug "Use config for detector $det"
        else
            qc_config = l200.metadata.dataprod.config.cal.qc(sel).default
            @debug "Use default config"
        end
        yield()

        th228_lines = Vector{Float64}(energy_config.th228_lines)
        th228_names = Symbol.(energy_config.th228_names)
        th228_names_dict  = Dict{Float64, Symbol}(th228_lines .=> Symbol.(energy_config.th228_names))
        window_sizes = Vector{Tuple{Float64, Float64}}([(l,r) for (l,r) in zip(Vector{Float64}(energy_config.left_window_sizes), Vector{Float64}(energy_config.right_window_sizes))])
        n_bins = energy_config.n_bins
        quantile_perc = Float64(NaN)
        if haskey(energy_config, :quantile_perc)
            quantile_perc = energy_config.quantile_perc
        end

        # generate qc cuts
        qc, data_ch_after_qc = nothing, nothing
        try
            @debug "Get QC cuts"
            qc = qc_cal_energy(data_ch, qc_config)
            @debug "Total surrival fraction: $(round(count(qc) / length(data_ch) * 100, digits=2))%"
            data_ch_after_qc =  data_ch[qc]
        catch e
            @error "Error in QC for channel $ch: $e"
            throw(ErrorException("Error in QC cut generation: $e"))
        end
        yield()

        result_simple, report_simple = nothing, nothing
        try
            @debug "Get simple calibration"
            result_simple, report_simple = simple_calibration(data_ch_after_qc.e_trap, th228_lines, window_sizes,; n_bins=n_bins, quantile_perc=quantile_perc)
        catch e
            @error "Error in simple calibration for channel $ch: $e"
            throw(ErrorException("Error in simple calibration"))
        end

        # get simple calibration constant
        m_cal_simple = result_simple.c
        # save plots for simple calibration for control
        plot(report_simple, margin=5mm, yformatter=:plain, thickness_scaling=1.5, cal=true, title=format("{} Simple Calibration ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
        savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-simple_calibration.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

        yield()

        result_fit, report_fit = nothing, nothing
        try
            @debug "Fit all peaks"
            result_fit, report_fit = fit_peaks(result_simple.peakhists, result_simple.peakstats, th228_names)
        catch e
            @error "Error in peak fitting for channel $ch: $e"
            throw(ErrorException("Error in peak fitting"))
        end

        peak_fit_plot = plot.(values(report_fit), titleloc=:center, titlefont=font(family="monospace",halign=:center, pointsize=20), ticks=:native, right_margin=10mm, top_margin=5mm, legend=false; show_label=true)
        for (i, p) in enumerate(peak_fit_plot)
            xticks!(p, convert(Int, round(xlims(p)[1], digits=0)):5:convert(Int, round(xlims(p)[2], digits=0)))
            title!(p, string(round(th228_lines[i], digits=2)) * " keV")
            if i != 1
                plot!(showlegend=false)
            end
        end
        plot(
            peak_fit_plot...,
            framestyle=:box,
            legend=:outerright,
            layout=(2, 4),
            thickness_scaling=2,
            grid=true, gridalpha=0.2, gridcolor=:black, gridlinewidth=0.5,
            xguidefont=font(family="monospace",halign=:center, pointsize=18),
            yguidefont=font(family="monospace",halign=:center, pointsize=18),
            xtickfontsize=10,
            ytickfontsize=10,
            size=(9000, 2000),
            margins=25mm
        )
        savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-peak_fits.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

        yield()

        @debug "Get calibration values"
        μ = [result_fit[p].μ for p in th228_names] ./ m_cal_simple
        μ_err = [result_fit[p].err.μ for p in th228_names] ./ m_cal_simple

        m_calib, n_calib = nothing, nothing
        try
            m_calib, n_calib = fit_calibration(μ, th228_lines)
            @debug format("Found calibration curve: E[keV] = {:.2f} + {:.2f}*E[ADC]", n_calib, m_calib)
        catch e
            @error "Error in calibration curve fitting for channel $ch: $e"
            throw(ErrorException("Error in calibration curve fitting"))
        end

        scatter(μ, th228_lines, yerror=μ_err, ms=5, color=:black, framestyle=:box, markershape= :x, layout = @layout[grid(2, 1, heights=[0.8, 0.2])], link=:x, label="Peak Positions", xlabel="Energy (ADC)", xlabelfontsize=10, ylabel="Energy (keV)", ylabelfontsize=10, legend=:topleft, legendfontsize=8, legendfont=font(8), legendtitlefontsize=8, legendtitlefont=font(8), xlims = (0, 21000), xticks = (0:2000:22000), margin=5mm, thickness_scaling=1.5, xformatter=:plain)
        plot!(ylims = (0, 3000), yticks = (200:200:3000), subplot=1, xlabel="", xticks = :none, bottom_margin=-4mm)
        plot!(0:1:20000, x -> m_calib* x + n_calib, label="Best Fit: $(round(n_calib, digits=2)) + x*$(round(m_calib, digits=2)))", line_width=2, color=:red, subplot=1, xformatter=_->"")
        plot!(μ, ((m_calib .* μ .+ n_calib) .- th228_lines) ./ th228_lines .* 100 , label="Residuals", ylabel="Residuals (%)", line_width=2, color=:black, st=:scatter, ylims = (-0.1, 0.1), markershape=:x, subplot=2, legend=:topleft, top_margin=0mm, framestyle=:box)
        plot!(legend = :topleft, title=format("{} Calibration Curve ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)), subplot=1)

        savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-calibration_curve.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

        yield()

        fwhm     = ([result_fit[p].fwhm for p in th228_names] ./ m_cal_simple) .* m_calib
        fwhm_err = ([result_fit[p].err.fwhm for p in th228_names] ./ m_cal_simple) .* m_calib

        result_fwhm, report_fwhm = nothing, nothing
        try
            result_fwhm, report_fwhm = fit_fwhm(th228_lines, fwhm)
            @debug "Found FWHM: $(round(result_fwhm.qbb, digits=2)) +- $(round(result_fwhm.err.qbb, digits=2))keV"
        catch e
            @error "Error in FWHM fitting for channel $ch: $e"
            throw(ErrorException("Error in FWHM fitting"))
        end

        scatter(th228_lines, fwhm, yerror=fwhm_err, ms=5, color=:black, framestyle=:box, markershape= :x, layout = @layout[grid(2, 1, heights=[0.8, 0.2])], link=:x, label="Peak FWHMs", xlabel="Energy (keV)", xlabelfontsize=10, ylabel="FWHM (keV)", ylabelfontsize=10, legend=:topleft, legendfontsize=8, legendfont=font(8), legendtitlefontsize=8, legendtitlefont=font(8), xlims = (0, 3000), xticks = (convert(Int, 0):300:convert(Int, round(3000, digits=0))), margin=5mm, thickness_scaling=1.5)
        plot!(0:0.1:3000, x -> report_fwhm.f_fit(x), label="Best Fit: Sqrt($(round(report_fwhm.v[1], digits=2)) + x*$(round(report_fwhm.v[2]*100, digits=2))e-3)", line_width=2, color=:red, subplot=1, xlabel="", xticks=:none, bottom_margin=-4mm)
        hline!([result_fwhm.qbb], label="Qbb/keV: $(round(result_fwhm.qbb, digits=2))+-$(round(result_fwhm.err.qbb, digits=2))", color=:green)
        hspan!([result_fwhm.qbb - result_fwhm.err.qbb, result_fwhm.qbb + result_fwhm.err.qbb], color=:green, alpha=0.2, label="")
        plot!(th228_lines, ((report_fwhm.f_fit.(th228_lines) .- fwhm) ./ fwhm) .* 100 , label="Residuals", ylabel="Residuals (%)", line_width=2, color=:black, st=:scatter, ylims = (-10, 10), markershape=:x, legend=:topleft, subplot=2, framestyle=:box, top_margin=0mm)
        plot!(legend = :topleft, title=format("{} FWHM ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)), subplot=1)

        savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-fwhm.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))
        
        yield()

        log_info = "| $ch | $det | Success | $(round(result_fwhm.qbb, digits=2))±$(round(result_fwhm.err.qbb, digits=2)) | $(round(result_fit[:Tl208FEP].fwhm, digits=2))±$(round(result_fit[:Tl208FEP].err.fwhm, digits=2)) | $(round(m_calib, digits=2)) | - |"

        result_energy = (
            m_calib = m_calib,
            n_calib = n_calib,
            m_cal_simple = m_cal_simple,
            fwhm = result_fwhm,
            fit  = result_fit,
        )
        return (result = result_energy, log = log_info)
    end

    result_energy = pmap(eachindex(chinfo.channel); on_error = e->(isa(e, ProcessExitedException) ? NaN : rethrow())) do idx
        try
            t_end = time() + timeout
            task = Threads.@spawn ch_energy_calibration(idx)
            while !istaskdone(task) && time() <= t_end
                sleep(0.1)
            end
            if !istaskdone(task)
                @debug "Timeout for $(chinfo.detector[idx])"
                throw(ErrorException("Timeout for $(chinfo.detector[idx])"))
            end
            chinfo.detector[idx] => fetch(task)
        catch e
            if e isa TaskFailedException
                e = e.task.exception
            end
            @debug "Write Error log for $(chinfo.detector[idx]): $e"
            log_info = "| ch$(chinfo.channel[idx]) | $(chinfo.detector[idx]) | Failed | - | - | - | $(e) |"
            chinfo.detector[idx] => (result = (m_calib = NaN, ), log = log_info)
        end
    end

    @info "Finished energy calibration"
    @info "Remove all workers"
    rmprocs(workers()...)


    main_log = """# Main log
    Time of processing: $(now())
    ## Energy Calibration
    This is the log for the energy calibration. The algorithm loads all data for a channel and performs a energy calibration while fitting peaks identified in the spectrum and returning 
    calibration constant and resolution.
    Before the parameters are extracted, QC cuts are applied to increase the quality of the data.
    # MetaData
    | Setup | Period | Run | Category |
    |-------|--------|-----|----------|
    | $(filekey.setup) | $(filekey.period) | $(filekey.run) | $(filekey.category) |

    # Results
    | Channel | Detector | Status | FWHM Qbb (keV) | FWHM FEP (keV) | Cal.Constant | Error |
    |---------|----------|--------|----------------|----------------|--------------|-------|
    """
    # extract results into pars_db and append to main log
    for (det, res) in result_energy
        # save pars to db
        if !isnan(res.result.m_calib)
            pars_det = pars_db[det].energy
            # save calibration results
            pars_det.m_calib = res.result.m_calib
            pars_det.n_calib = res.result.n_calib
            pars_det.m_cal_simple = res.result.m_cal_simple
            # save peak fit results
            result_fit = res.result.fit
            for (peak, peak_result) in result_fit
                pars_det_peak = pars_det[peak]
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
            # save fwhm results
            result_fwhm = res.result.fwhm
            pars_det.fwhm_qbb     = result_fwhm.qbb
            pars_det.fwhm_qbb_err = result_fwhm.err.qbb
            pars_det.fwhm_pars    = result_fwhm.v
        end
        # add log to main log
        main_log = """
        $main_log$(res.log)
        """
        # main_log *= res.log
    end

    # save pars to disk
    @info "Save pars to disk"

    # write pars
    writeprops(joinpath(l200.tier[:par, :cal], "energy", "$period/$run.json"), pars_db, multiline=true)

    @info "Write main log to disk"
    @info main_log

    log_filename = joinpath(log_folder, format("{}-{}-{}-{}-energy_calibration.md", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
    open(log_filename, "w+") do file
        write(file, replace(main_log, "Success" => raw"$${\color{green}Success}$$", "Failed" => raw"$${\color{red}Failed}$$"))
    end
end