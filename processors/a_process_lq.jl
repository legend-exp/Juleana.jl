function process_lq_calibration_cut(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)

    l200 = LegendData(:l200)
    period = :p03
    run = :r000

    @info "LQ for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true) 
    @info "Loaded channel info with $(length(chinfo)) channels"

    lq_config = dataprod_config(l200).psd(filekey).lq
    @debug "Loaded lq config: $(lq_config)"

    #fill config with:



    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.aoe), string(period)))
    pars_db = PropDict(l200.par.rpars.aoe[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" end

    # create log line Tuple
    #log_nt_cal = NamedTuple{(:Channel, :Detector, :Status, Symbol("Filter Type"), Symbol("Number of fitted Bands"), Symbol("μ Correction Mean normalized Residuals"), Symbol("σ Correction Mean normalized Residuals"), :CalError)}
    #log_nt_cut = NamedTuple{(:Channel, :Detector, :Status, Symbol("Classifier Type"), Symbol("Cut Value"), Symbol("SEP SF"), Symbol("FEP SF"), :CutError)}

    # get worker pool
    #wpool = get_workerPool(processing_config, nameof(var"#self#"))
    
    # flush stdout
    flush(stdout)

    function ch_lq_cut(chinfo_ch::NamedTuple)
        chinfo_ch = chinfo[1]
        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        @info "Processing channel $ch ($det)"

        pars_db_ch = get(pars_db, det, PropDict())

        result_dict    = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()


        lq_types = [Symbol("lq")]

        #=
        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(det) already processed, check missing energy types"
            for lq_type in lq_types
                if !haskey(pars_db[det], lq_type)
                    pars_db_det_lq_type = pars_db[det][lq_type]
                    log_ch = log_nt_cal(ch, det, ProcessStatus(1), lq_type, length(pars_db_det_lq_type.μ_compton.μ), mean(pars_db_det_lq_type.µ_compton.gof.residuals_norm), mean(pars_db_det_lq_type.σ_compton.gof.residuals_norm), "Already processed --> skipped.")
                    processed_dict[lq_type] = false
                    log_info_dict[lq_type] = log_ch
                end
            end
            for aoe_classifier in aoe_classifiers
                if haskey(pars_db[det], aoe_classifier)
                    log_info = log_nt_cut((ch, det, ProcessStatus(1), aoe_classifier, pars_db[det][aoe_classifier].lowcut, pars_db[det][aoe_classifier].peaks[:Tl208SEP].sf, pars_db[det][aoe_classifier].peaks[:Tl208FEP].sf, "Already processed --> skipped."))
                    # add results to dict
                    log_info_dict[aoe_classifier] = log_info
                    processed_dict[aoe_classifier] = false
                end
            end
        end
        =#

        e_cal, lq_e_corr, qdrift = nothing, nothing, nothing

        try
            #load data of one detector for all in one period + estimate mean of raw lq in DEP
            data_path = l200.tier[:jlhitch, filekey, ch]
            data = LHDataStore(data_path)
            table = data[ch].dataQC[:]
            
            #load data from one run
            pd = l200.par.rpars.ecal(filekey)     ##Das Laden hier dauert ewig
            f_cal = ljl_propfunc(pd[dets[i]].e_cusp_ctc.cal.func)
            
            #energy
            e_cal = Vector(f_cal.(table))
            #qdrift
            qdrift = table.qdrift ./ (e_cal)
            #lq adter energy correction
            lq_e_corr = ustrip.(table.lq ./ e_cal)

            
            println("Data loaded")
        catch e
            @error "Error in loading data: $e"
            throw(ErrorException("Error in loading data: $e"))
        end
        DEP_σ = 10.77u"keV"
        @showprogress desc="Detector: $det" for lq_type in lq_types
            if haskey(processed_dict, lq_type)
                continue
            end
            try
                @debug "Calibrate $lq_type"

                drift_result, drift_report = nothing, nothing
                try 
                    drift_result, drift_report = lq_drift_time_correction(lq_e_corr, qdrift, e_cal, DEP_µ, DEP_σ)
                catch e
                    @error "Error in drift time correction: $e"
                    throw(ErrorException("Error in drift time correction: $e"))
                end

                #plot: dirft time vs lq plot mit box und fit

                #Für den plot brauch ich die DEP daten, bin mir unsicher wo genau ich das hinpacken soll. Also die daten zuschneiden hier im processor, oder das plotten in doe function? Beider doof...
                
                DEP_left = DEP_µ - DEP_edgesigma * DEP_σ
                DEP_right = DEP_µ + DEP_edgesigma * DEP_σ

                box = drift_report.lq_box
                p = histogram2d(qdrift[DEP_left .< e_cal .< DEP_right], lq_e_corr[DEP_left .< e_cal .< DEP_right], 
                xlabel="Drift Time", ylabel="LQ (A.U.)", framestyle=:box, nbins=(0:6:600,2.0:0.02:4.4), 
                left_margin = -15Plots.mm, bottom_margin = -13Plots.mm, c=:viridis, fontfamily="Computer Modern", formatter=:plain, thickness_scaling=3, size=(1200,900))
                vline!([box.t_lower, box.t_upper], label = "", linewidth = 1.5, color = :red)
                hline!([box.lq_lower, box.lq_upper], label = "", linewidth = 1.5, color = :red)
                plot!(drift_report.drift_time_func, label = "Linear Fit", linewidth = 1.5, color = :blue,
                legend=:topright)
                #save plot


                # add results to dict
                result_dict[lq_type]   = drift_result
                log_info_dict[lq_type] = log_info
                processed_dict[lq_type] = true

                # free memory
                GC.gc()
            catch e
                #@error "Error in $lq_type calibration: $(truncate_string(string(e)))"
                #log_info = log_nt_cal((ch, det, ProcessStatus(0), lq_type, "-", "-", "-", truncate_string(string(e))))
                # add results to dict
                #log_info_dict[lq_type] = log_info
                #processed_dict[lq_type] = false
            end
        end
        @info "AoE calibration for channel $ch ($det) finished"


        # continue with lq cut
        lq_classifiers = [Symbol("lq")]

        #calculate lq classifier
        lq_class = nothing
        try
            f_lq = ljl_propfunc(lq_class_func)
            lq_class = Vector(f_lq.(table))
        catch
            @error "Error in lq class calculation: $e"
            throw(ErrorException("Error in lq class calculation"))
        end


        @showprogress desc="Detector: $det" for lq_classifier in lq_classifiers
            if haskey(processed_dict, aoe_classifier)
                continue
            end
            try
                @debug "Generate $lq_classifier cut"

                

                #calculate LQ cut parameter value
                result, report = nothing, nothing
                try
                    result, report = LQ_cut(DEP_µ, DEP_σ, e_cal, lq_class)
                catch e
                    @error "Error in LQ cut calculation: $e"
                    throw(ErrorException("Error in LQ cut calculation: $e"))
                end

                #plot LQ cut: LQ verteilung mit cut wert als rote linie



                
                #In ein config file auslagern, oder mit fall unterscheidung coden

                window = [10.0u"keV", 10.0u"keV"]
                #peaknames = ["Tl208DEP", "Bi212FEP", "Tl208SEP", "Tl208FEP"]
                #peak_values = [1592.53, 1620.50, 2103.53, 2614.51] * u"keV"
                peaknames = ["Tl208DEP", "Tl208FEP"]
                peak_values = [1592.53, 2614.51] * u"keV"
                
                println("starting to calculate SF values")
                sf_values = Dict{String, Any}()
                try    
                    for (i,name) in enumerate(peaknames)
                        sf_result, sf_report = get_peak_surrival_fraction(lq_class, e_cal, peak_values[i], window, result.cut; inverted_mode=true)
                        sf_values[name] = sf_result.sf
                    end
                catch e
                    @error "Error in peak surrival fraction calculation: $e"
                    throw(ErrorException("Error in peak surrival fraction calculation: $e"))
                end

                try
                    sf_values["Continuum"] = get_continuum_surrival_fraction(lq_class, e_cal, 2029.0u"keV", 10.0u"keV", result.cut, inverted_mode=true).sf
                catch e
                    @error "Error in continuum surrival fraction calculation: $e"
                    throw(ErrorException("Error in continuum surrival fraction calculation: $e"))
                end



                # save results
                result = merge(result_cut, sf_values)

                log_info = log_nt_cut((ch, det, ProcessStatus(1), aoe_classifier, result_cut.lowcut, result.peaks[:Tl208SEP].sf, result.peaks[:Tl208FEP].sf, "-"))

                # add results to dict
                result_dict[aoe_classifier]   = result
                log_info_dict[aoe_classifier] = log_info
                processed_dict[aoe_classifier] = true

                GC.gc()
            catch e
                @error "Error in $aoe_classifier cut generation: $(truncate_string(string(e)))"
                log_info = log_nt_cut((ch, det, ProcessStatus(0), aoe_classifier, "-", "-", "-", truncate_string(string(e))))
                
                # add results to dict
                log_info_dict[aoe_classifier] = log_info
                processed_dict[aoe_classifier] = false
            end
        end

        # cleanup log and combine
        log_info_dict_cleaned = Dict{Symbol, NamedTuple}()
        for lq_type in lq_types
            log_info_dict_cleaned[lq_type] = merge(log_info_dict[lq_type], log_info_dict[Symbol("$(string(lq_type))_classifier")])
        end

        return (result = result_dict, log = log_info_dict_cleaned, processed = processed_dict)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_aoe = parallel(chinfo, ch_lq_cut, merge(log_nt_cal, log_nt_cut), wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished AoE calibration"

    pars_db = create_pars(pars_db, result_aoe)
    writelprops(l200.par.rpars.aoe[period], run, pars_db)
    writevalidity(l200.par.rpars.aoe, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, aoe_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_aoe))

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, :aoe), report)
    @info report

    # flush stdout
    flush(stdout)
end
