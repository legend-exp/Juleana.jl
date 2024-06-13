function process_lq_calibration_cut(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=0)

    @info "LQ for period $period and run $run"

    filekey = start_filekey(l200, (period, run, :cal))
    @info "Found filekey $filekey"

    chinfo = channelinfo(l200, filekey; system=:geds, only_processable=true) 
    @info "Loaded channel info with $(length(chinfo)) channels"

    lq_config = dataprod_config(l200).psd(filekey).lq
    @debug "Loaded lq config: $(lq_config)"

    #fill config with:


    @debug "Create pars db"
    mkpath(joinpath(data_path(l200.par.rpars.lq), string(period)))
    pars_db = PropDict(l200.par.rpars.lq[period, run])

    pars_db = ifelse(reprocess, PropDict(), pars_db)
    if reprocess @info "Reprocess all channels" end

    # create log line Tuple
    log_nt_cal = NamedTuple{(:Channel, :Detector, :Status, Symbol("Drift Correction Type"), Symbol("Lq classifier function") :CalError)}
    log_nt_cut = NamedTuple{(:Channel, :Detector, :Status, Symbol("Classifier Type"), Symbol("LQ cut Value"), Symbol("Continuum SF"), Symbol("DEP SF"), :CutError)}

    # get worker pool
    #wpool = get_workerPool(processing_config, nameof(var"#self#"))
    
    # flush stdout
    flush(stdout)

    function ch_lq_cut(chinfo_ch::NamedTuple)
        ch  = chinfo_ch.channel
        det = chinfo_ch.detector

        @info "Processing channel $ch ($det)"

        pars_db_ch = get(pars_db, det, PropDict())

        result_dict    = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, NamedTuple}()
        processed_dict = Dict{Symbol, Bool}()

        lq_modes = [Symbol("gaussian"), Symbol("percentile")] # In ein config file auslagern

        #=
        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(det) already processed, check missing energy types"
            for lq_mode in lq_modes
                if !haskey(pars_db[det], lq_mode)
                    pars_db_det_lq_mode = pars_db[det][lq_mode]
                    log_ch = log_nt_cal(ch, det, ProcessStatus(1), lq_mode, length(pars_db_det_lq_mode.μ_compton.μ), mean(pars_db_det_lq_mode.µ_compton.gof.residuals_norm), mean(pars_db_det_lq_mode.σ_compton.gof.residuals_norm), "Already processed --> skipped.")
                    processed_dict[lq_mode] = false
                    log_info_dict[lq_mode] = log_ch
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
        DEP_σ, DEP_µ = nothing, nothing

        try #!! get das laden hier schlauer oder gut so? !!
            #load data of one detector for all in one period + estimate mean of raw lq in DEP
            data_path = l200.tier[:jlhitch, filekey, ch]
            data = LHDataStore(data_path)
            table = data[ch].dataQC[:]
            
            #load data from one run
            pd = l200.par.rpars.ecal(filekey)     ##Das Laden hier dauert ewig
            f_cal = ljl_propfunc(pd[det].e_cusp_ctc.cal.func)
            #ctc energy
            e_cal = Vector(f_cal.(table))

            #qdrift
            qdrift = table.qdrift ./ (e_cal)
            #lq adter energy correction
            lq_e_corr = ustrip.(table.lq ./ e_cal)

            DEP_σ = pd[det].e_cusp_ctc.fit.Tl208DEP.σ
            DEP_µ = pd[det].e_cusp_ctc.fit.Tl208DEP.μ

            
            println("Data loaded")
        catch e
            @error "Error in loading data: $e"
            throw(ErrorException("Error in loading data: $e"))
        end

        @showprogress desc="Detector: $det" for lq_mode in lq_modes
            if haskey(processed_dict, lq_mode)
                println("Already processed")
                continue
            end
            try
                @debug "Calibrate $lq_mode"

                drift_result, drift_report = nothing, nothing
                try 
                    drift_result, drift_report = lq_drift_time_correction(lq_e_corr, qdrift, e_cal, DEP_µ, DEP_σ;e_expression="e_cusp", mode=lq_mode)
                catch e
                    @error "Error in drift time correction: $e"
                    throw(ErrorException("Error in drift time correction: $e"))
                end

                #plot: dirft time vs lq plot mit box und fit

                #Für den plot brauch ich die daten auf den DEP gecutted, bin mir unsicher wo genau ich das hinpacken soll. Also die daten zuschneiden hier im processor, oder das plotten in der function? Beider doof...
                DEP_edgesigma = 2.0
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
                savefig(p, joinpath("/mnt/artemis02/users/gieb/MPP_Code/Documents/Plots/LQ_Processor_Test", "drift_time_vs_lq_plot.png"))

                log_info = log_nt_cal(ch, det, ProcessStatus(1), lq_mode, result.func, "-")

                # add results to dict
                result_dict[lq_mode]   = drift_result
                log_info_dict[lq_mode] = log_info
                processed_dict[lq_mode] = true

                # free memory
                GC.gc()
            catch e
                @error "Error in $lq_mode calibration: $(truncate_string(string(e)))"
                log_info = log_nt_cal((ch, det, ProcessStatus(0), lq_mode, "-", truncate_string(string(e))))

                # add results to dict
                log_info_dict[lq_mode] = log_info
                processed_dict[lq_mode] = false
            end
        end
        @info "LQ constructor construction for channel $ch ($det) finished"

        # continue with lq cut
        lq_mode = lq_modes[1]

        @showprogress desc="Detector: $det" for lq_mode in lq_modes
            if haskey(processed_dict, lq_mode)
                continue
            end
            try
                @debug "Generate lq cut"
                
                #calculate lq classifier
                lq_class = nothing
                try
                    datapath = l200.tier[:jlhitch, filekey, ch]
                    data = LHDataStore(datapath)
                    table = data[ch].dataQC[:]
                    f_lq = ljl_propfunc(result_dict[lq_mode].func)
                
                    lq_class = Vector(f_lq.(table))
                catch
                    @error "Error in lq class calculation: $e"
                    throw(ErrorException("Error in lq class calculation"))
                end
                histogram2d(e_cal, lq_class , xlabel="Energy", ylabel="LQ (A.U.)")

                
                #calculate LQ cut parameter value
                result, report = nothing, nothing
                try
                    result, report = LQ_cut(DEP_µ, DEP_σ, e_cal, lq_class)
                catch e
                    @error "Error in LQ cut calculation: $e"
                    throw(ErrorException("Error in LQ cut calculation: $e"))
                end

                #plot LQ cut: LQ verteilung mit cut wert als rote linie
                histogram2d(e_cal, lq_class , xlabel="Energy", ylabel="LQ (A.U.)", title="LQ Cut for Detector: $det",
                nbins=(0:2:3000, -2.3:0.001:-2),
                colorbar_scale=:log10, c=:viridis, framestyle=:box, fontfamily="Computer Modern", formatter=:plain, thickness_scaling=1.6, size=(1200,800),
                left_margin = -5Plots.mm, bottom_margin = -Plots.mm)
                hline!([mvalue(result.cut)], label = "3σ exclusion", linewidth = 2, color = :red, legend=:topright)

                #Energy histogram before/after LQ
                stephist(e_cal, xlabel="Energy", ylabel="Counts", title="Energy Spectrum of Detector:$det", nbins=(0:1:3500), framestyle=:box, fontfamily="Computer Modern", formatter=:plain,
                dpi=300, thickness_scaling=1.6, size=(1200,900), yscale=:log10, label="Data before LQ Cut")
                stephist!(e_cal[lq_class .< result.cut], nbins=0:1:3500, label="Surviving LQ Cut", framestyle=:box, fontfamily="Computer Modern", formatter=:plain, 
                dpi=300, thickness_scaling=1.6, size=(1200,900), yscale=:log10)
                stephist!(e_cal[lq_class .> result.cut], nbins=0:1:3500, label="Cut by LQ Cut", framestyle=:box, fontfamily="Computer Modern", formatter=:plain, dpi=300, thickness_scaling=1.6, size=(1200,900), yscale=:log10)
                #savefig("/mnt/artemis02/users/gieb/MPP_Code/Documents/Plots/LQ_Processor_Test/$(det)_Energy_hist.png")

                #percentual cut plot
                h1 = fit(Histogram, ustrip.(e_cal), 0:1:3500)
                h2 = fit(Histogram, ustrip.(e_cal[lq_class .> result.cut]), 0:1:3500)
                h_diff = h2.weights ./ h1.weights

                plot(h_diff, xlabel="Energy", ylabel="Counts", title="Energy of", framestyle=:box, fontfamily="Computer Modern", formatter=:plain, dpi=300, thickness_scaling=1.6, size=(1200,900),
                label="Survival Fraction", legend=:bottomleft)
                savefig("/mnt/artemis02/users/gieb/MPP_Code/Documents/Plots/LQ_Processor_Test/$(det)_Energy_diff.png")


                #In ein config file auslagern
                window = [10.0u"keV", 10.0u"keV"]
                #peaknames = ["Tl208DEP", "Bi212FEP", "Tl208SEP", "Tl208FEP"]
                #peak_values = [1592.53, 1620.50, 2103.53, 2614.51] * u"keV"
                peaknames = ["Tl208DEP", "Tl208FEP"]
                peak_values = [1592.53, 2614.51] * u"keV"
                

                @info("starting to calculate SF values")
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
                final_result = (lq_cut_result = result, sf = sf_values)

                log_info = log_nt_cut((ch, det, ProcessStatus(1), lq_mode, final_result.lq_cut_result.cut, final_result.sf["Continuum"], final_result.sf["Tl208DEP"], "-"))

                # add results to dict
                result_dict[Symbol("lq_cut_of_$lq_mode")] = final_result
                log_info_dict[Symbol("lq_cut_of_$lq_mode")] = log_info
                processed_dict[Symbol("lq_cut_of_$lq_mode")] = true

                GC.gc()
            catch e
                @error "Error in lq cut generation: $(truncate_string(string(e)))"
                log_info = log_nt_cut((ch, det, ProcessStatus(0), lq_class, "-", "-", "-", truncate_string(string(e))))
                
                # add results to dict
                log_info_dict[Symbol("lq_cut_of_$lq_mode")] = log_info
                processed_dict[Symbol("lq_cut_of_$lq_mode")] = false
            end
        end

        # cleanup log and combine
        log_info_dict_cleaned = Dict{Symbol, NamedTuple}()
        for lq_mode in lq_modes
            log_info_dict_cleaned[lq_mode] = merge(log_info_dict[lq_mode], log_info_dict[Symbol("$(string(lq_mode))_classifier")])
        end

        return (result = result_dict, log = log_info_dict_cleaned, processed = processed_dict)
    end

    # get start time
    start_time = now()

    # execute in parallel
    result_lq = parallel(chinfo, ch_lq_cut, merge(log_nt_cal, log_nt_cut), wpool; timeout=timeout, retry=false, process_name="$(ifelse(startswith(string(nameof(var"#self#")), "p_"), "$period", "$period-$run"))-$(nameof(var"#self#"))")

    @info "Finished LQ Cut calculation"

    pars_db = create_pars(pars_db, result_lq)
    writelprops(l200.par.rpars.lq[period], run, pars_db)
    writevalidity(l200.par.rpars.lq, filekey, (period, run))
    @info "Saved pars to disk"

    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, lq_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(filekey))
    lreport!(report, "# Results")
    lreport!(report, create_logtbl(result_lq))

    @info "Write log report"
    writelreport(get_rreportfilename(l200, filekey, :lq), report)
    @info report

    # flush stdout
    flush(stdout)
end
