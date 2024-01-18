function process_psd_calibration(l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=300)

    @info "PSD calibration for period $period and run $run"

    filekeys = sort(search_disk(FileKey, l200.tier[:dsp, :cal, period, run]), by = x-> x.time)
    filekey = filekeys[1]
    @info "Found filekey $filekey"

    chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable && $usability == :on)

    sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)

    hit_folder = l200.tier[:hit_ch, :cal, period, run]

    pars_energy = l200.par[:cal, :energy, period, run]

    @debug "Create figures folder"
    figures_folder = joinpath(l200.tier[:plt, :cal, period, run], "psd")
    if isdir(figures_folder)
        @debug("Figure folder $figures_folder already exists")
    else
        mkpath(figures_folder)
    end

    for str in unique(chinfo.string)
        figures_folder_string = joinpath(figures_folder, format("string{:02d}", str))
        if isdir(figures_folder_string)
            @debug("String Figure folder $figures_folder_string already exists")
        else
            mkpath(figures_folder_string)
        end
    end

    @debug "Create logs folder"
    log_folder = joinpath(l200.tier[:log, :cal, period, run])
    if isdir(log_folder)
        @debug("Log folder $figures_folder already exists")
    else
        mkpath(log_folder)
    end

    @debug "Create pars db"
    pars_db = PropDict()
    # read params if exist
    if !(haskey(l200.par[:cal, :psd], Symbol(period)))
        # path folder for current period seems not to exist, will create it first to avoid errors
        mkpath(joinpath(l200.tier[:par, :cal], "psd", "$period"))
    elseif haskey(l200.par[:cal, :psd, period], Symbol(run))
        @info "Pars file already exists."
        pars_db = l200.par[:cal, :psd, period, run]
    end

    if reprocess
        @info "Reprocess all channels"
        for det in keys(pars_db)
            pars_db[det].calibration = nothing
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
        pars_energy = $pars_energy
        reprocess = $reprocess
    end

    @everywhere function ch_psd_calibration(i::Int64)

        ch_short = chinfo.channel[i]
        ch = format("ch{}", ch_short)
        string_number = chinfo.string[i]
        det = chinfo.detector[i]

        if !reprocess && haskey(pars_db, det) && haskey(pars_db[det], :calibration)
            @debug "Channel $(chinfo.detector[i]) already processed, skip"
            # log = "| $ch | $det | Success | $(pars_db[det].sg.wl.val*u"ns") | $(round(pars_db[det].sg.min_sep_sf, digits=2)) | $(round(pars_db[det].sg.min_sep_sf_err, digits=2)) | Already processed --> skipped. |"
            pars_det = pars_db[det].calibration
            log = "| $ch | $det | Success | $(pars_det.n_compton) | $(round(pars_det.μ_scs[2]*1e6, digits=2))E6 * x ± $(round(pars_det.μ_scs[1], digits=2)) | Already processed --> skipped. |"
            return (result = NamedTuple(), log = log)
        end

        @info "Processing channel $ch ($det)"

        figures_folder_string = joinpath(figures_folder, format("string{:02d}", string_number))

        hitchfilename = joinpath(hit_folder, format("{}-{}-{}-{}-{}-tier_hit.lh5", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch))

        # load config
        if haskey(l200.metadata.dataprod.config.psd(sel), det)
            psd_config = merge(l200.metadata.dataprod.config.psd(sel).default, l200.metadata.dataprod.config.psd(sel)[det])
            @debug "Use config for detector $det"
        else
            psd_config = l200.metadata.dataprod.config.psd(sel).default
            @debug "Use default config"
        end

        compton_bands  = Vector{Float64}(psd_config.compton_bands)
        compton_window = psd_config.compton_window
        p_value        = psd_config.p_value
        e_type         = Symbol(psd_config.energy_type)

        if !haskey(pars_energy, det) || !haskey(pars_energy[det], e_type) || !haskey(pars_energy[det][e_type], :energy)
            @error "Energy calibration for $(det) not found"
            throw(ErrorException("Energy calibration for $(det) not found"))
        end

        e, aoe = nothing, nothing
        try
            data_hit = LHDataStore(hitchfilename, "r");
            # get a
            a = data_hit["$(ch)/dataQC/a"][:];
            # get energy for best resolution
            e = data_hit["$(ch)/dataQC/$(e_type)"][:];
            calibrate_energy!(e, pars_energy[det][e_type].energy)
            # get aoe
            aoe = a ./ e;
            close(data_hit)
        catch e
            @error "AoE and E data from $(basename(hitchfilename)) cannot be loaded: $e"
            throw(LoadError(string(basename(hitchfilename)), 154, "AoE and E data from $(basename(hitchfilename)) cannot be loaded"))
        end

        histogram2d(e, aoe, nbins=(0:0.5:3000, 0.2:5e-4:0.8), xlims=(0, 3000), ylims=(0.1, 0.9), size=(1000, 600), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy (keV)", ylabel="A/E (a.u.)", margin=5mm)
        xticks!(0:250:3000)
        plot!(title=format("{} A/E Uncalibrated ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
        savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-aoe_uncalibrated_{}.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch, string(e_type))))

        result_fit, report_fit, compton_band_peakhists = nothing, nothing, nothing
        try
            # get compton band peak histograms with generated peakstats
            compton_band_peakhists = generate_aoe_compton_bands(aoe, e, compton_bands, compton_window)

            result_fit, report_fit = fit_aoe_compton(compton_band_peakhists.peakhists, compton_band_peakhists.peakstats, compton_bands,; uncertainty=true)
        catch e
            @error "AoE compton bands cannot be fitted: $e"
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

        compton_bands = [band for band in compton_bands if result_fit[band].p_value >= p_value]
        μ = [result_fit[band].μ for band in compton_bands]
        μ_err = [result_fit[band].err.μ for band in compton_bands]
        σ = [result_fit[band].σ for band in compton_bands]
        σ_err = [result_fit[band].err.σ for band in compton_bands]

        # fit μ and σ with correction functions
        aoe_corrections = nothing
        try
            aoe_corrections = fit_aoe_corrections(compton_bands, μ, σ)
        catch e
            @error "AoE corrections cannot be fitted: $e"
            throw(ErrorException("AoE corrections cannot be fitted"))
        end        
        
        # plot μ and σ with correction functions
        scatter(aoe_corrections.e, aoe_corrections.μ, yerr=μ_err, ms=5, color=:black, layout = @layout[grid(2, 1, heights=[0.8, 0.2])], xlabel=L"Energy\ (keV)", ylabel=L"\mu_{A/E} (a.u.)", label=L"\mu_{SCS}", xticks = (minimum(compton_bands):200:maximum(compton_bands)), xlims=(minimum(compton_bands)-50, maximum(compton_bands)+50))
        plot!(ylims=(0.95*median(aoe_corrections.μ), 1.05*median(aoe_corrections.μ)), subplot=1, xlabel="", xticks = :none)
        plot!(0.0:1500:3000, x -> aoe_corrections.f_μ_scs(x), label="Best Fit: $(round(aoe_corrections.μ_scs[1], digits=2)) + x*$(round(aoe_corrections.μ_scs[1]*1000, digits=2))e-3", line_width=3.5, color=:red, subplot=1, xformatter=_->"")
        plot!(aoe_corrections.e, (aoe_corrections.f_μ_scs.(aoe_corrections.e) .- aoe_corrections.μ) ./ aoe_corrections.μ .* 100 , label="Residuals", ylabel="Residuals (%)", line_width=2, color=:black, st=:scatter, ylims = (-5.0, 5.0), markershape=:x, subplot=2)
        plot!(legend = :topright, title=format(L"{}\ A/E\ \mu \ ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)), subplot=1)
        savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-compton_bands_mu_{}.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch, string(e_type))))


        scatter(aoe_corrections.e, aoe_corrections.σ, yerr=σ_err, ms=5, color=:black, layout = @layout[grid(2, 1, heights=[0.8, 0.2])], xlabel=L"Energy\ (keV)", ylabel=L"\mu_{A/E} (a.u.)", label=L"\sigma_{SCS}", xticks = (minimum(compton_bands):200:maximum(compton_bands)), xlims = (minimum(compton_bands)-50, maximum(compton_bands)+50))
        plot!(ylims=(0.1*aoe_corrections.f_σ_scs(maximum(compton_bands)), 2*aoe_corrections.f_σ_scs(minimum(compton_bands))), subplot=1, xlabel="", xticks = :none)
        plot!(minimum(compton_bands)-50:0.1:maximum(compton_bands)+50, x -> aoe_corrections.f_σ_scs(x), label=format("Best Fit: sqrt({:.2E}+({:.2E}/x^2)", aoe_corrections.σ_scs...), line_width=3.5, color=:red, subplot=1, xformatter=_->"")
        plot!(aoe_corrections.e, (aoe_corrections.f_σ_scs.(aoe_corrections.e) .- aoe_corrections.σ) ./ aoe_corrections.σ .* 100 , label="Residuals", ylabel="Residuals (%)", line_width=2, color=:black, st=:scatter, ylims = (-50.0, 50.0), markershape=:x, subplot=2)
        plot!(legend = :topright, title=format(L"{}\ A/E\ \sigma \ ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)), subplot=1)
        savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-compton_bands_sigma_{}.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch, string(e_type))))

        # correct aoe
        correct_aoe!(aoe, e, aoe_corrections)


        histogram2d(e, aoe, nbins=(0:0.5:3000, -20:0.1:10), xlims=(0, 3000), ylims=(-20, 10), size=(1000, 600), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel=L"Energy\ (keV)", ylabel=L"A/E\ (\sigma_{A/E})")
        plot!(margin=1mm, thickness_scaling=1.6, dpi=600, size=(1000, 600))
        xticks!(0:250:3000)
        plot!(title=format("{} normalized A/E ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
        savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-aoe_normalized_{}.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch, string(e_type))))

        @info "AoE calibration for channel $ch ($det) finished"

        log_info = "| $ch | $det | Success | $(length(compton_bands)) | $(round(aoe_corrections.μ_scs[2]*1e6, digits=2))E6 * x ± $(round(aoe_corrections.μ_scs[1], digits=2)) | - |"

        # free memory
        GC.gc()

        return (result = aoe_corrections, log = log_info)
    end

    Base.exit_on_sigint(false)
    result_psd =  @showprogress pmap(eachindex(chinfo.channel); batch_size = 1, retry_check=retry_check, retry_delays=ExponentialBackOff(n=3)) do idx
        try
            t_end = time() + timeout
            task = Threads.@spawn ch_psd_calibration(idx)
            while !istaskdone(task) && time() <= t_end
                sleep(0.1)
            end
            if !istaskdone(task)
                @debug "Timeout for $(chinfo.detector[idx])"
                try
                    Base.throwto(task, InterruptException())
                catch e
                    throw(ErrorException("Timeout for $(chinfo.detector[idx])"))
                end
                throw(ErrorException("Timeout for $(chinfo.detector[idx])"))
            end
            chinfo.detector[idx] => fetch(task)
        catch e
            if e isa TaskFailedException
                e = e.task.exception
            end
            @debug "Write Error log for $(chinfo.detector[idx]): $e"
            log_info = "| ch$(chinfo.channel[idx]) | $(chinfo.detector[idx]) | Failed | - | - | $(e) |"
            chinfo.detector[idx] => (result = NamedTuple(), log = log_info)
        end
    end

    @info "Finished PSD calibration"
    @info "Remove all workers"
    rmprocs(workers()...)

    main_log = """
    # Main log 
    Time of processing: $(now())
    ## PSD calibration
    This is the log for the PSD calibration for the AoE PSD analysis. The processing involves fitting the Compton bands of the AoE spectrum and fitting the resulting parameters with correction functions. The correction functions are then applied to the AoE spectrum. The resulting AoE spectrum is then saved to the hit file.

    # MetaData
    | Setup | Period | Run | Category |
    |-------|--------|-----|----------|
    | $(filekey.setup) | $(filekey.period) | $(filekey.run) | $(filekey.category) |

    # Results
    | Channel | Detector | Status | Number of fitted Bands | μ Correction | Error |
    |---------|----------|--------|------------------------|--------------|-------|
    """
    # extract results into pars_db and append to main log
    for (det, res) in result_psd
        # save pars to db
        if !isempty(res.result)
            pars_det                    = pars_db[det].calibration
            pars_det.n_compton          = length(res.result.e)
            pars_det.μ_scs              = res.result.μ_scs
            pars_det.err.μ_scs          = res.result.err.μ_scs
            pars_det.σ_scs              = res.result.σ_scs
            pars_det.err.σ_scs          = res.result.err.σ_scs
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
    writeprops(joinpath(l200.tier[:par, :cal], "psd", "$period/$run.json"), pars_db, multiline=true)

    # write validity
    pars_validTimeStamp = string(filekey.time)
    add_validity = true
    for ln in eachline(open(joinpath(l200.tier[:par, :cal], "psd", "validity.jsonl"), "r"))
        if (contains(ln, "$pars_validTimeStamp"))
            add_validity = false
        end
    end
    if add_validity
        open(joinpath(l200.tier[:par, :cal], "psd", "validity.jsonl"), "a") do io
            println(io, "{\"valid_from\":\"$pars_validTimeStamp\", \"category\":\"all\", \"apply\":[\"$period/$run.json\"]}")
        end
    end

    @info "Write main log to disk"
    @info main_log

    log_filename = joinpath(log_folder, format("{}-{}-{}-{}-psd_calibration.md", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
    open(log_filename, "w+") do file
        write(file, replace(main_log, "Success" => raw"$${\color{green}Success}$$", "Failed" => raw"$${\color{red}Failed}$$"))
    end
end