function p_process_energy(processing_config::PropDict, l200::LegendData, period::DataPeriod,; reprocess::Bool=false, timeout::Int=0, only_first_period::Bool=true)
    
    @info "Energy calibration for for all partitions containing period $period"

    rinfo = runinfo(l200, period) |> filterby(@pf $cal.is_analysis_run)
    @info "Loaded run info with $(length(rinfo)) runs"

    filekey = first(rinfo).cal.startkey
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true)
    @info "Loaded channel info with $(length(chinfo)) channels"

    if reprocess @info "Reprocess all channels" else @info "Only process channels not in pars_db" end

    # create log line Tuple
    log_nt = NamedTuple{(:Channel, :Detector, :Partition, :Status, Symbol("Filter Type"), Symbol("FWHM Qbb"), Symbol("FWHM FEP"), Symbol("Cal. Constant"), :Error)}

    # get worker pool
    wpool = get_workerPool(processing_config, nameof(var"#self#"))

    # get unfolded channel info where each entry is a detector and its partition for all partitions that contain period
    chinfo_unfolded = get_partition_channelinfo(l200, chinfo, period; unfold_partitions=true)

    # flush stdout
    flush(stdout)    
    
    function ch_energy_calibration(chinfo_ch::NamedTuple)
        
        ch  = chinfo_ch.channel
        det = chinfo_ch.detector
        part = chinfo_ch.partition

        @debug "Processing channel $ch ($det)"

        mkpath(joinpath(data_path(l200.par.ppars.ecal), string(det)))
        pars_db_ch = if isfile(joinpath(data_path(l200.par.ppars.ecal), "$det", "$part.json")) && !reprocess
            PropDict(l200.par.ppars.ecal[det, part])
        else
            PropDict()
        end

        partinfo_ch = partitioninfo(l200, ch, part)
        @debug "Loaded channel partition info with $(length(partinfo_ch)) runs"
    
        filekey_ch = start_filekey(l200, (first(partinfo_ch.period), first(partinfo_ch.run), :cal))
        @debug "Found filekey $filekey_ch"

        validity_ch = get_partitionvalidity(l200, ch, det, part, :cal)

        energy_config = dataprod_config(l200).energy(filekey_ch)
        energy_config_ch = merge(energy_config.p_default, get(energy_config.p, det, PropDict()))
        @debug "Loaded energy config: $(energy_config_ch)"

        energy_types = Symbol.(energy_config_ch.energy_types)

        result_dict    = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        if (only_first_period && period != first(partinfo_ch.period))
            @info "Only first period in partition $part for $period in $ch ($det)"
            for e_type in energy_types
                log_info = log_nt((ch, det, part, ProcessStatus(1), e_type, fill("-", 3)..., "Only first periods --> skipped."))
                # add results to dict
                processed_dict[e_type] = false
                log_info_dict[e_type] = log_info
            end
            return (processed = processed_dict, log = log_info_dict, validity = validity_ch, skipped = true)
        end

        if !reprocess && haskey(pars_db_ch, det)
            @debug "Channel $(det) already processed, check missing energy types"
            for e_type in energy_types
                if haskey(pars_db_ch[det], e_type)
                    @debug "Filter $e_type already processed, skip"
                    log_info = log_nt((ch, det, part, ProcessStatus(1), e_type, pars_db_ch[det][e_type].fwhm.qbb, pars_db_ch[det][e_type].fit.Tl208FEP.fwhm, pars_db_ch[det][e_type].cal.par[2], "Already processed --> skipped."))
                    processed_dict[e_type] = false
                    log_info_dict[e_type] = log_info
                end
            end
        end

        th228_names = Symbol.(energy_config_ch.th228_names)
        th228_lines_dict = Dict(th228_names .=> energy_config_ch.th228_lines)

        for e_type in energy_types
            if haskey(processed_dict, e_type)
                continue
            end
            try
                @debug "Calibrate $e_type"

                energy = nothing
                try
                    energy = fast_flatten([begin 
                            @debug "Reading from $(pinfo.period)-$(pinfo.run)"
                            ljl_propfunc(l200.par.rpars.ecal[pinfo.period, pinfo.run][det][e_type].cal.func).(read_ldata(:dataQC, l200, :jlhit, :cal, pinfo.period, pinfo.run, ch)) end
                    for pinfo in partinfo_ch])
                catch e
                    @error "E data for $det from cannot be loaded"
                    throw(LoadError("E data", 154, "E data for $det from partition $(part) cannot be loaded"))
                end
                GC.gc()

                e_unit = u"keV"
                peakhists, peakstats = nothing, nothing
                try
                    @debug "Get $e_type peakhists and peakstats"
                    peakhists, peakstats, _, _ = get_peakhists_th228(collect(energy), energy_config_ch.th228_lines, energy_config_ch.left_window_sizes, energy_config_ch.right_window_sizes; e_unit=e_unit)
                catch e
                    @error "Error in $e_type simple calibration for channel $ch: $(truncate_error(e))"
                    throw(ErrorException("Error in $e_type simple calibration"))
                end
                GC.gc()

                p = LegendMakie.lplot(fit(Histogram, ustrip.(e_unit, energy), 0:0.5:3000), 
                    xlabel = "Energy ($e_unit)", ylabel = "Counts / 0.5 keV", yscale = Makie.log10, label = string(e_type),
                    title = get_plottitle(filekey_ch, part, det, "Energy Spectrum"; additiional_type="$e_type"),
                    legend_position = :lb, xticks = 0:500:3000)
                savelfig(LegendMakie.lsavefig, p, l200, part, filekey_ch, det, Symbol("partition_spectrum_$e_type"))

                yield()

                result_fit, report_fit = nothing, nothing
                try
                    @debug "Fit all $e_type peaks"
                    result_fit, report_fit = fit_peaks(peakhists, peakstats, th228_names; 
                                                e_unit=e_unit, fit_func=Symbol.(energy_config_ch.th228_fit_func), calib_type=:th228)
                catch e
                    @error "Error in $e_type peak fitting for channel $ch: $(truncate_error(e))"
                    throw(ErrorException("Error in $e_type peak fitting"))
                end
                GC.gc()

                p = LegendMakie.lplot(report_fit, figsize = (600, 400 * length(report_fit)), title = get_plottitle(filekey_ch, part, det, "Peak Fits"; additiional_type=string(e_type)))
                savelfig(LegendMakie.lsavefig, p, l200, part, filekey_ch, det, Symbol("peak_fits_$e_type"))

                yield()

                # fit QC peaks
                fit_qc = energy_config_ch.qc.fit
                
                # peak fitting QC
                fwhm_cut = [result_fit[th228_names[i]].fwhm > energy_config_ch.qc.min_fwhm && result_fit[th228_names[i]].fwhm .< energy_config_ch.qc.max_fwhm_per_window * (energy_config_ch.left_window_sizes[i] + energy_config_ch.right_window_sizes[i]) for i in eachindex(th228_names)]
                qc_cut = ljl_propfunc(fit_qc).([result_fit[k] for k in th228_names]) .&& fwhm_cut
        
                th228_names_qc = th228_names[qc_cut]
                th228_names_cut = th228_names[.!qc_cut]

                @debug "Get $e_type calibration values"

                th228_names_qc_cal_fit = [p for p in th228_names_qc if !(p in Symbol.(energy_config_ch.cal_fit_excluded_peaks))]

                result_calib, report_calib = nothing, nothing
                try
                    μ_fit =  [result_fit[p].centroid for p in th228_names_qc_cal_fit]
                    pp_fit = [th228_lines_dict[p] for p in th228_names_qc_cal_fit]
                    result_calib, report_calib = fit_calibration(energy_config_ch.cal_pol_order, μ_fit, pp_fit; uncertainty=true)
                    @debug "Found $e_type calibration curve: $(result_calib.func)"
                catch e
                    @error "Error in $e_type calibration curve fitting for channel $ch: $(truncate_error(e))"
                    throw(ErrorException("Error in $e_type calibration curve fitting"))
                end
                # add not-fitted peaks to plot 
                μ_notfit =  [result_fit[p].centroid for p in th228_names if !(p in th228_names_qc_cal_fit)]
                pp_notfit = [th228_lines_dict[p] for p in th228_names if !(p in th228_names_qc_cal_fit)]
        
                p = LegendMakie.lplot(report_calib, xerrscaling=1, additional_pts=(μ = μ_notfit, peaks = pp_notfit), 
                    title = get_plottitle(filekey_ch, part, det, "Calibration Curve"; additiional_type=string(e_type)),
                    xlims = (0,3000), ylims = (0,3000), figsize = (600,420), 
                    xlabel=L"\fontfamily{Roboto}\mathrm{Energy_{fit} (keV)}", ylabel=L"\fontfamily{Roboto}\mathrm{Energy_{true} (keV)}")
                savelfig(LegendMakie.lsavefig, p, l200, part, filekey_ch, det, Symbol("calibration_curve_$e_type"))

                yield()

                th228_names_qc_fwhm_fit = [p for p in th228_names_qc if !(p in Symbol.(energy_config_ch.fwhm_fit_excluded_peaks))]

                result_fwhm, report_fwhm = nothing, nothing
                try
                    fwhm_fit = [result_fit[p].fwhm for p in th228_names_qc_fwhm_fit]
                    pp_fit = [th228_lines_dict[p] for p in th228_names_qc_fwhm_fit]    
                    result_fwhm, report_fwhm = fit_fwhm(energy_config_ch.fwhm_pol_order, pp_fit, fwhm_fit; e_type_cal=Symbol("$(e_type)_cal"), uncertainty=true)
                    @debug "Found $e_type FWHM: $(round(u"keV", result_fwhm.qbb, digits=2))"
                catch e
                    @error "Error in $e_type FWHM fitting for channel $ch: $(truncate_error(e))"
                    throw(ErrorException("Error in $e_type FWHM fitting"))
                end
                fwhm_notfit =  [result_fit[p].fwhm for p in th228_names if !(p in th228_names_qc_fwhm_fit)]
                pp_notfit = [th228_lines_dict[p] for p in th228_names if !(p in th228_names_qc_fwhm_fit)]        

                p = LegendMakie.lplot(report_fwhm, additional_pts=(peaks = pp_notfit, fwhm = fwhm_notfit), figsize = (600,420),
                    title = get_plottitle(filekey_ch, part, det, "FWHM"; additiional_type=string(e_type)))
                savelfig(LegendMakie.lsavefig, p, l200, part, filekey_ch, det, Symbol("fwhm_$e_type"))

                yield()

                log_info = log_nt((ch, det, part, ProcessStatus(1), e_type, result_fwhm.qbb, result_fit[:Tl208FEP].fwhm, result_calib.par[2], "-"))

                result_energy = (
                    fwhm = result_fwhm,
                    cal = result_calib,
                    fit  = result_fit,
                )

                # add results to dict
                result_dict[e_type]   = result_energy
                log_info_dict[e_type] = log_info
                processed_dict[e_type] = true

                GC.gc()
            catch e
                @error "Error in $e_type: $(truncate_error(e))"
                log_info = log_nt((ch, det, part, ProcessStatus(0), e_type, "-", "-", "-", e))

                # add results to dict
                log_info_dict[e_type] = log_info
                processed_dict[e_type] = false
            end
        end

        result_ch = (result = result_dict, processed = processed_dict, log = log_info_dict, validity = validity_ch)
        result_energy_ch = Dict{NamedTuple, NamedTuple}(chinfo_ch => result_ch)

        pars_db_ch = create_pars(pars_db_ch, result_energy_ch)
        writelprops(l200.par.ppars.ecal[det], part, pars_db_ch)
        writevalidity(l200.par.ppars.ecal[det], filekey_ch, part)

        # return results
        return result_ch
    end

    # get start time
    start_time = now()

    result_energy = parallel(chinfo_unfolded, ch_energy_calibration, log_nt, wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished partition calibration"

    @info "Write $period validity"
    validity_all = create_validity(result_energy)
    writevalidity(l200.par.ppars.ecal, validity_all)

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, energy_part_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_energy))

    @info "Write log report"
    writelreport(get_preportfilename(l200, filekey, Symbol("$(last(split(string(nameof(var"#self#")), "process_")))")), report)
    @info report

    # flush stdout
    flush(stdout)

    return any(x -> get(last(x), :skipped, false), values(result_energy))
end

