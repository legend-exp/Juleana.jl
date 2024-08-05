function process_aoe_calibration(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)

    @info "Calibrate AoE for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true) |> filterby(@pf $low_aoe_status .== :valid)
    @info "Loaded channel info with $(length(chinfo)) channels"

    aoe_config = dataprod_config(l200).psd(filekey).aoe
    @debug "Loaded aoe config: $(aoe_config)"

    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.aoecal), string(period)))
    pars_db = PropDict(l200.par.rpars.aoecal[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" end

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Status, Symbol("Filter Type"), Symbol("Number of fitted Bands"), Symbol("μ Correction Mean normalized Residuals"), Symbol("σ Correction Mean normalized Residuals"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))
    
    # flush stdout
    flush(stdout)

    function ch_aoe_calibration(chinfo_ch::NamedTuple)

        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        @info "Processing channel $ch ($det)"

        hitchfilename = l200.tier[:jlhit, filekey, ch]
        # load data file
        if !isfile(hitchfilename)
            @error "Hit file $hitchfilename not found"
            throw(ErrorException("Hit file not found"))
        end

        result_dict    = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        aoe_config_ch = merge(aoe_config.default, get(aoe_config, det, PropDict()))

        compton_bands  = aoe_config_ch.compton_bands
        compton_window = aoe_config_ch.compton_window
        p_value_cut    = aoe_config_ch.p_value # what is this? p values threshold 
        e_type         = Symbol(aoe_config_ch.e_type)
        aoe_types      = collect(keys(aoe_config_ch.aoe_funcs))
        aoe_funcs      = aoe_config_ch.aoe_funcs

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(det) already processed, check missing energy types"
            for aoe_type in aoe_types
                if !haskey(pars_db[det], aoe_type)
                    pars_db_det_aoe_type = pars_db[det][aoe_type]
                    log_ch = log_nt(ch, det, ProcessStatus(1), aoe_type, length(pars_db_det_aoe_type.μ_compton.μ), mean(pars_db_det_aoe_type.µ_compton.gof.residuals_norm), mean(pars_db_det_aoe_type.σ_compton.gof.residuals_norm), "Already processed --> skipped.")
                    processed_dict[aoe_type] = false
                    log_info_dict[aoe_type] = log_ch
                end
            end
        end

        data_hit, e_cal, aoe_data = nothing, nothing, nothing
        try
            data_hit = lh5open(hitchfilename)[ch, :jlhit, :dataQC][:]
            data_hit = Table(merge(columns(data_hit), columns(calibrate_ged_channel_data(l200, filekey, det, data_hit))))
            e_cal = getproperty(data_hit, e_type)
            aoe_data = Table(ljl_propfunc(aoe_funcs).(data_hit))
        catch e
            @error "AoE and E data from $(basename(hitchfilename)) cannot be loaded: $(truncate_string(string(e)))"
            throw(LoadError(string(basename(hitchfilename)), 154, "AoE and E data from $(basename(hitchfilename)) cannot be loaded"))
        end

        @showprogress desc="Detector: $det" for aoe_type in aoe_types
            if haskey(processed_dict, aoe_type)
                continue
            end
            try
                @debug "Calibrate $aoe_type"

                # get data
                aoe, aoe_expression = nothing, nothing
                try
                    aoe = getproperty(aoe_data, aoe_type)
                    cuts_aoe = cut_single_peak(aoe, 0.0, quantile(aoe, 0.99); n_bins=-1)
                    aoe ./= cuts_aoe.max
                    aoe_expression = "$(aoe_funcs[aoe_type]) / $(cuts_aoe.max)"
                catch e
                    @error "Error in $aoe_type simple normalization for channel $ch: $(truncate_string(string(e)))"
                    throw(ErrorException("Error in $aoe_type simple normalization"))
                end
                GC.gc()

                p = histogram2d(e_cal, aoe, nbins=(0:0.5:3000, 0.1:5e-3:1.8), xlims=(0, 3000), ylims=(0.1, 1.8), size=(1200, 800), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy", ylabel="A/E (a.u.)", margin=5mm)
                plot!(p, guidefontsize=18, xguidefontsize=18,yguidefontsize = 18,xtickfontsize = 12,ytickfontsize=12)
                xticks!(p, 0:250:3000)
                title!(p, get_plottitle(filekey, det, "AoE uncalibrated"; additiional_type=string(aoe_type)))
                savelfig(savefig, p, l200, filekey, det, Symbol("aoe_uncalibrated_$aoe_type"))

                result_fit, report_fit, compton_band_peakhists = nothing, nothing, nothing
                try
                    # get compton band peak histograms with generated peakstats
                    compton_band_peakhists = generate_aoe_compton_bands(aoe, e_cal, compton_bands, compton_window)

                    result_fit, report_fit = fit_aoe_compton(compton_band_peakhists.peakhists, compton_band_peakhists.peakstats, compton_bands,; uncertainty=true)
                catch e
                    @error "AoE compton bands cannot be fitted: $(truncate_string(string(e)))"
                    throw(ErrorException("AoE compton bands cannot be fitted"))
                end
                GC.gc()

                # generate plots of compton bands as gif
                # p = @animate for band in compton_bands fps=0.5
                #     report_band = report_fit[band]
                #     plot(report_band, title=format("{} A/E CC at $band keV ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)), legend=:topleft)
                #     xlims!(minimum(compton_band_peakhists.min_aoe), maximum(compton_band_peakhists.max_aoe))
                # end
                # gif(p, fps=0.5, joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-aoe_compton-bands_{}.gif", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch, string(e_type))))

                compton_bands = [band for band in keys(result_fit) if result_fit[band].gof.pvalue >= p_value_cut] # end here 
                μ = [result_fit[band].μ for band in compton_bands]
                σ = [result_fit[band].σ for band in compton_bands]

                # fit μ and σ with correction functions
                result, report = nothing, nothing
                try
                    result, report = fit_aoe_corrections(compton_bands, μ, σ,; aoe_expression = aoe_expression, e_expression = e_type)
                catch e
                    @error "AoE corrections cannot be fitted: $(truncate_string(string(e)))"
                    throw(ErrorException("AoE corrections cannot be fitted"))
                end
                
                p = plot(report.report_µ)
                title!(p, get_plottitle(filekey, det, "A/E μ"; additiional_type=string(aoe_type)), subplot=1)
                savelfig(savefig, p, l200, filekey, det, Symbol("compton_bands_mu_$aoe_type"))

                p = plot(report.report_σ)
                title!(p, get_plottitle(filekey, det, "A/E σ"; additiional_type=string(aoe_type)), subplot=1)
                savelfig(savefig, p, l200, filekey, det, Symbol("compton_bands_sigma_$aoe_type"))

                # correct aoe
                aoe_corr = ljl_propfunc(result.func).(data_hit)
                p = histogram2d(e_cal, aoe_corr, nbins=(0:0.5:3000, -30:0.1:10), xlims=(0, 3000), ylims=(-30, 10), size=(1300, 700), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel=L"Energy\ (keV)", ylabel=L"A/E\ (\sigma_{A/E})")
                plot!(margin=1mm, thickness_scaling=1.6, dpi=600)
                xticks!(0:250:3000)
                title!(p, get_plottitle(filekey, det, "normalized A/E"; additiional_type=string(aoe_type)))
                savelfig(savefig, p, l200, filekey, det, Symbol("aoe_normalized_$aoe_type"))

                log_info = log_nt(ch, det, ProcessStatus(1), aoe_type, length(compton_bands), mean(result.µ_compton.gof.residuals_norm), mean(result.σ_compton.gof.residuals_norm), "-")

                # add results to dict
                result_dict[aoe_type]   = result
                log_info_dict[aoe_type] = log_info
                processed_dict[aoe_type] = true

                # free memory
                GC.gc()
            catch e
                @error "Error in $aoe_type calibration: $(truncate_string(string(e)))"
                log_info = log_nt((ch, det, ProcessStatus(0), aoe_type, "-", "-", "-", truncate_string(string(e))))
                # add results to dict
                log_info_dict[aoe_type] = log_info
                processed_dict[aoe_type] = false
            end
        end
        @info "AoE calibration for channel $ch ($det) finished"

        return (result = result_dict, log = log_info_dict, processed = processed_dict)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_aoecal = parallel(chinfo, ch_aoe_calibration, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished AoE calibration"

    pars_db = create_pars(pars_db, result_aoecal)
    writelprops(l200.par.rpars.aoecal[period], run, pars_db)
    writevalidity(l200.par.rpars.aoecal, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, aoe_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_aoecal))

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, :aoe_cal), report)
    @info report

    # flush stdout
    flush(stdout)
end
