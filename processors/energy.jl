function process_energy_calibration(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=300)
    
    @info "Energy calibration for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = Table(channelinfo(l200, filekey; system=:geds, only_processable=true))
    @info "Loaded channel info with $(length(chinfo)) channels"

    energy_config = dataprod_config(l200).energy(filekey)
    @debug "Loaded energy config: $(energy_config)"

    pars_ctc = get_values(l200.par.rpars.ctc[period, run])
    @debug "Loaded CTC parameters"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.ecal), string(period)))
    pars_db = ifelse(l200.par.rpars.ecal[period, run] isa LegendDataManagement.NoSuchPropsDBEntry, PropDict(), l200.par.rpars.ecal[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" end

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Status, Symbol("Filter Type"), Symbol("FWHM Qbb"), Symbol("FWHM FEP"), Symbol("Cal. Constant"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # move all variables to workers
    @everywhere begin
        l200 = $l200
        filekey = $filekey
        chinfo = $chinfo
        pars_db = $pars_db
        reprocess = $reprocess
        energy_config = $energy_config
        log_nt = $log_nt
        pars_ctc = $pars_ctc
    end

    @everywhere function ch_energy_calibration(chinfo_ch::NamedTuple)
        
        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        @debug "Processing channel $ch ($det)"

        hitchfilename = get_hitchfilename(l200, filekey, ch)
        # load data file
        if !isfile(hitchfilename)
            @error "Hit file $hitchfilename not found"
            throw(ErrorException("Hit file not found"))
        end

        result_dict    = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()


        energy_config_ch = merge(energy_config.default, get(energy_config, det, PropDict()))

        energy_types = Symbol.(energy_config_ch.energy_types)

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(det) already processed, check missing energy types"
            for e_type in energy_types
                if haskey(pars_db[det], e_type)
                    @debug "Filter $e_type already processed, skip"
                    log_info = log_nt((ch, det, ProcessStatus(1), e_type, pars_db[det][e_type].fwhm.qbb, pars_db[det][e_type].fit.Tl208FEP.fwhm, pars_db[det][e_type].m_calib, "Already processed --> skipped."))
                    processed_dict[e_type] = false
                    log_info_dict[e_type] = log_info
                end
            end
        end

        # load data file
        if !isfile(hitchfilename)
            @error "Hit file $hitchfilename not found"
            throw(ErrorException("Hit file not found"))
        end
        # get data
        data_ch_after_qc = nothing
        try
            @debug "Load hit file"
            data_hit = LHDataStore(hitchfilename, "r");
            data_ch_after_qc = data_hit["$(ch)/dataQC"][:];
            close(data_hit)
        catch e
            @error "Error in loading data for channel $ch: $e"
            throw(ErrorException("Error data loader"))
        end

        quantile_perc = if energy_config_ch.quantile_perc isa String parse(Float64, energy_config_ch.quantile_perc) else energy_config_ch.quantile_perc end
        th228_names = Symbol.(energy_config_ch.th228_names)
        th228_lines = energy_config_ch.th228_lines
        th228_lines_dict = Dict(th228_names .=> energy_config_ch.th228_lines)

        @showprogress desc="Detector: $det" for e_type in energy_types
            if haskey(processed_dict, e_type)
                continue
            end
            try
                @debug "Calibrate $e_type"

                # get data
                e_ctc = nothing
                try
                    @debug "Get $e_type data"
                    # open hit data file
                    e_type_name = Symbol(split(string(e_type), "_ctc")[1])
                    e_ctc = getproperty(data_ch_after_qc, e_type_name)
                    if endswith(string(e_type), "_ctc")
                        @debug "Apply CT correction for $e_type"
                        fct = pars_ctc[det][e_type_name].fct
                        e_ctc = e_ctc .+ fct .* getproperty(data_ch_after_qc, :qdrift)
                    end
                catch e
                    @error "Error in $e_type data extraction for channel $ch: $e"
                    throw(ErrorException("Error in $e_type data extraction"))
                end
                GC.gc()

                result_simple, report_simple = nothing, nothing
                try
                    @debug "Get $e_type simple calibration"
                    result_simple, report_simple = simple_calibration(e_ctc, energy_config_ch.th228_lines, energy_config_ch.left_window_sizes, energy_config_ch.right_window_sizes,; calib_type=:th228, n_bins=energy_config_ch.n_bins, quantile_perc=quantile_perc)
                catch e
                    @error "Error in $e_type simple calibration for channel $ch: $e"
                    throw(ErrorException("Error in $e_type simple calibration"))
                end
                GC.gc()

                # get simple calibration constant
                m_cal_simple = result_simple.c
                # save plots for simple calibration for control
                p = plot(report_simple, margin=5mm, yformatter=:plain, thickness_scaling=1.5, cal=true)
                title!(p, get_plottitle(filekey, det, "Simple Calibration"; additiional_type=string(e_type)))
                savelfig(p, l200, filekey, ch, Symbol("simple_calibration_$(e_type)"))
                yield()

                result_fit, report_fit = nothing, nothing
                try
                    @debug "Fit all $e_type peaks"
                    result_fit, report_fit = fit_peaks(result_simple.peakhists, result_simple.peakstats, th228_names; e_unit=result_simple.unit, calib_type=:th228)
                catch e
                    @error "Error in $e_type peak fitting for channel $ch: $e"
                    throw(ErrorException("Error in $e_type peak fitting"))
                end
                GC.gc()

                peak_fit_plot = plot.(values(report_fit), titleloc=:center, titlefont=font(family="monospace",halign=:center, pointsize=20), ticks=:native, right_margin=10mm, top_margin=5mm, legend=false; show_label=true)
                for (i, p) in enumerate(peak_fit_plot)
                    xticks!(p, convert(Int, round(xlims(p)[1], digits=0)):5:convert(Int, round(xlims(p)[2], digits=0)))
                    title!(p, string.(keys(report_fit))[i])
                    if i != 1
                        plot!(showlegend=false)
                    end
                end
                p = plot(
                    peak_fit_plot...,
                    framestyle=:box,
                    legend=:outerright,
                    layout=(3, 3),
                    thickness_scaling=1.5,
                    grid=true, gridalpha=0.2, gridcolor=:black, gridlinewidth=0.5,
                    xguidefont=font(family="monospace",halign=:center, pointsize=18),
                    yguidefont=font(family="monospace",halign=:center, pointsize=18),
                    xtickfontsize=10,
                    ytickfontsize=10,
                    size=(5000, 3000),
                    margins=15mm,
                    dpi=300
                )
                savelfig(p, l200, filekey, ch, Symbol("peak_fits_$(e_type)"))

                yield()

                @debug "Get $e_type calibration values"
                μ =  [result_fit[p].μ for p in th228_names] ./ m_cal_simple

                m_calib, n_calib = nothing, nothing
                try
                    μ_fit =  get_values([result_fit[p].μ for p in th228_names if p != :Tl208SEP && p != :Tl208DEP] ./ m_cal_simple)
                    pp_fit = [th228_lines_dict[p] for p in th228_names if p != :Tl208SEP && p != :Tl208DEP]    
                    m_calib, n_calib = fit_calibration(μ_fit, pp_fit)
                    @debug "Found $e_type calibration curve: E[keV] = $(round(u"keV", n_calib, digits=2)) + $(round(u"keV", m_calib, digits=2))*E[ADC]"
                catch e
                    @error "Error in $e_type calibration curve fitting for channel $ch: $e"
                    throw(ErrorException("Error in $e_type calibration curve fitting"))
                end

                p = scatter(μ, th228_lines, ms=5, color=:black, framestyle=:box, markershape= :x, layout = @layout[grid(2, 1, heights=[0.8, 0.2])], label="Peak Positions", xlabel="Energy (ADC)", xlabelfontsize=10, ylabel="Energy (keV)", ylabelfontsize=10, legend=:topleft, legendfontsize=8, legendfont=font(8), legendtitlefontsize=8, legendtitlefont=font(8), xlims = (0, 21000), xticks = (0:2000:22000), margin=5mm, thickness_scaling=1.5, xformatter=:plain)
                plot!(ylims = (0, 3000), yticks = (200:200:3000), subplot=1, xlabel="", xticks = :none, bottom_margin=-4mm)
                plot!(0:1:20000, m_calib .* collect(0:1:20000) .+ n_calib, label="Best Fit: $(round(u"keV", n_calib, digits=2)) + x*$(round(u"keV", m_calib, digits=2))", line_width=2, color=:red, subplot=1, xformatter=_->"")
                plot!(μ, ((m_calib .* ustrip.(μ) .+ n_calib) .- th228_lines) ./ th228_lines .* 100 , label="Residuals", ylabel="Residuals (%)", line_width=2, color=:black, st=:scatter, ylims = (-0.1, 0.1), markershape=:x, subplot=2, legend=:topleft, top_margin=0mm, framestyle=:box)
                plot!(legend = :topleft, title=get_plottitle(filekey, det, "Calibration Curve"; additiional_type=string(e_type)), subplot=1)
                
                savelfig(p, l200, filekey, ch, Symbol("calibration_curve_$(e_type)"))

                yield()

                fwhm     = ([result_fit[p].fwhm for p in th228_names] ./ m_cal_simple) .* m_calib

                result_fwhm, report_fwhm = nothing, nothing
                try
                    fwhm_fit = get_values([result_fit[p].fwhm for p in th228_names if p != :Tl208SEP && p != :Tl208DEP] ./ m_cal_simple) .* m_calib
                    pp_fit = [th228_lines_dict[p] for p in th228_names if p != :Tl208SEP && p != :Tl208DEP]    
                    result_fwhm, report_fwhm = fit_fwhm(pp_fit, fwhm_fit)
                    @debug "Found $e_type FWHM: $(round(u"keV", result_fwhm.qbb, digits=2))"
                catch e
                    @error "Error in $e_type FWHM fitting for channel $ch: $e"
                    throw(ErrorException("Error in $e_type FWHM fitting"))
                end

                p = plot(layout = @layout[grid(2, 1, heights=[0.8, 0.2])], label="Peak FWHMs", xlabel="Energy (keV)", xlabelfontsize=10, ylabel="FWHM", ylabelfontsize=10, legend=:topleft, legendfontsize=8, legendfont=font(8), legendtitlefontsize=8, legendtitlefont=font(8), xlims = (0, 3000), xticks = (convert(Int, 0):300:convert(Int, round(3000, digits=0))), margin=5mm, thickness_scaling=1.5)
                scatter!(th228_lines, fwhm, ms=5, color=:black, framestyle=:box, markershape= :x, ylabel="FWHM (keV)", subplot=1)
                plot!((0:0.1:3000)*u"keV", x -> report_fwhm.f_fit(x), label="Best Fit -  ENC: $(round(u"keV^2", result_fwhm.enc, digits=2))| Fano: $(round(u"keV", result_fwhm.fano*100, digits=2))e-3 | CT: $(round(result_fwhm.ct*1000, digits=2))e-4)", line_width=2, color=:red, subplot=1, xlabel="", xticks=:none, bottom_margin=-4mm)
                hline!([result_fwhm.qbb], label="Qbb: $(round(u"keV", result_fwhm.qbb, digits=2))", color=:green)
                hspan!([mvalue(result_fwhm.qbb) - muncert(result_fwhm.qbb), mvalue(result_fwhm.qbb) + muncert(result_fwhm.qbb)], color=:green, alpha=0.2, label="")
                plot!(ustrip.(u"keV", th228_lines), ((report_fwhm.f_fit.(th228_lines) .- fwhm) ./ fwhm) .* 100 , label="Residuals", ylabel="Residuals (%)", line_width=2, color=:black, st=:scatter, ylims = (-10, 10), markershape=:x, legend=:topleft, subplot=2, framestyle=:box, top_margin=0mm)
                plot!(legend = :topleft, title=get_plottitle(filekey, det, "FWHM"; additiional_type=string(e_type)), subplot=1)

                savelfig(p, l200, filekey, ch, Symbol("fwhm_$(e_type)"))
                
                yield()

                log_info = log_nt((ch, det, ProcessStatus(1), e_type, result_fwhm.qbb, result_fit[:Tl208FEP].fwhm, m_calib, "-"))

                result_energy = (
                    m_calib = m_calib,
                    n_calib = n_calib,
                    m_cal_simple = m_cal_simple,
                    fwhm = result_fwhm,
                    fit  = result_fit,
                )

                # add results to dict
                result_dict[e_type]   = result_energy
                log_info_dict[e_type] = log_info
                processed_dict[e_type] = true

                GC.gc()
            catch e
                @error "Error in $e_type CT correction: $e"
                log_info = log_nt((ch, det, ProcessStatus(0), e_type, "-", "-", "-", e))
                # add results to dict
                log_info_dict[e_type] = log_info
                processed_dict[e_type] = false
            end
        end


        return (result = result_dict, log = log_info_dict, processed = processed_dict)
    end

    # get start time
    start_time = now()

    result_energy = parallel(chinfo, ch_energy_calibration, log_nt, wpool; timeout=timeout)

    @info "Finished energy calibration"

    pars_db = create_pars(pars_db, result_energy)
    writelprops(l200.par.rpars.ecal[period], run, pars_db)
    writevalidity(l200.par.rpars.ecal, filekey)
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, energy_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_energy))

    @info "Write log report"
    writelreport(get_logfilename(l200, filekey, :energy_calibration), report)
    @info report
end