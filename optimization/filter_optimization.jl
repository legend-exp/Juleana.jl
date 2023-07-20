# using LegendDataManagement, PropertyFunctions, TypedTables, PropDicts
# using Unitful, Formatting, LaTeXStrings
# using Plots
# using LegendHDF5IO, LegendDSP, LegendSpecFits

# ENV["JULIA_DEBUG"] = Main # enable debug

# gr()
# # plotlyjs()

# @info "Loading Legend MetaData"
# l200 = LegendData(:l200)

# search_disk(DataCategory, l200.tier[:raw])
# search_disk(DataPeriod, l200.tier[:raw, :cal])
# search_disk(DataRun, l200.tier[:raw, :cal, period])
# search_disk(DataRun, l200.tier[:raw, :cal, string(period)])

# period = DataPeriod(3)
# run    = DataRun(1)

function process_filter_optimization(l200::LegendData, period::DataPeriod, run::DataRun)
    @info "Optimize filter for period $period and run $run"

    filekey = sort(search_disk(FileKey, l200.tier[:raw, :cal, period, run]), by = x-> x.time)[1]
    @info "Found filekey $filekey"

    chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable)

    sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)
    dsp_meta = l200.metadata.dataprod.config.dsp(sel).default
    dsp_config = create_dsp_config(dsp_meta)
    @debug "Loaded DSP config: $(dsp_config)"

    pars_tau_folder     = joinpath(l200.tier[:par, :cal, period, run], "decay_time")
    pars_filename       = format("{}-{}-{}-{}-decay_time.json", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category))
    pars_tau            = readprops(joinpath(pars_tau_folder, pars_filename))


    @debug "Create figures folder"
    figures_folder = joinpath(l200.tier[:plt, :cal, period, run], "optimization")
    ifelse(isdir(figures_folder), @debug("Figure folder $figures_folder already exists"), mkpath(figures_folder))

    @debug "Create pars folder"
    pars_folder = joinpath(l200.tier[:par, :cal, period, run], "optimization")
    ifelse(isdir(pars_folder), @debug("Pars folder $pars_folder already exists"), mkpath(pars_folder))

    @debug "Create pars db"
    pars_db = PropDict()


    for (i, ch_short) in enumerate(chinfo.channel)
        ch_short = chinfo.channel[i]
        ch = format("ch{}", ch_short)
        det = chinfo.detector[i]
        @debug "Processing channel $ch ($det)"

        if haskey(l200.metadata.dataprod.config.dsp.optimization(sel), det)
            optimization_config = l200.metadata.dataprod.config.dsp.optimization(sel)[det]
            @debug "Use config for detector $det"
        else
            optimization_config = l200.metadata.dataprod.config.dsp.optimization(sel).default
            @debug "Use default config"
        end

        # unpack config
        min_enc, max_enc = optimization_config.min_enc, optimization_config.max_enc
        nbins = optimization_config.nbins
        rel_cut_fit = optimization_config.rel_cut_fit


        filename = joinpath(l200.tier[DataTier(:peaks), :cal, period, run], format("{}-{}-{}-{}-{}-tier_peaks.lh5", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch))
        if !isfile(filename)
            @warn "File $filename does not exist, Skip channel $ch"
            continue
        end

        data = LHDataStore(filename, "r")

        @debug "Loading Tl208 FEP data from $(filename)"
        wvfs_ch_fep = data[ch].Tl208a.waveform[:]

        # optimize RT
        @debug "Generate trap ENC filter grid"
        enc_trap_grid = dsp_trap_rt_optimization(wvfs_ch_fep, dsp_config, pars_tau[det].tau.val*u"µs")

        result, report = fit_enc_sigmas(enc_trap_grid, dsp_config.e_grid_rt_trap, min_enc, max_enc, nbins, rel_cut_fit)
        @debug format("Found optimal RT at $(result.rt) with ENC {:.2f} ADC", result.min_enc)

        plot(report, title=format("{} Noise Sweep ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))

        savefig(joinpath(figures_folder, format("{}-{}-{}-{}-{}-noise_sweep.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

        # save pars to db
        pars_det         = pars_db[det]
        pars_det.trap_rt      = result.rt
        pars_det.trap_rt_err  = step(dsp_config.e_grid_rt_trap)
        pars_det.trap_min_enc = result.min_enc

        # optimize FT
        @debug "Generate trap FT energy grid"
        e_trap_grid = dsp_trap_ft_optimization(wvfs_ch_fep, dsp_config, pars_tau[det].tau.val*u"µs", result.rt)

        result, report = fit_fwhm_ft_fep(e_trap_grid, dsp_config.e_grid_ft_trap)
        @debug format("Found optimal FT at $(result.ft) with FWHM {:.2f} keV", result.min_fwhm)

        plot(report, title=format("{} FWHM FEP FT Scan ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))

        savefig(joinpath(figures_folder, format("{}-{}-{}-{}-{}-fwhm_ft_scan.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

        # save pars to db
        pars_det.trap_ft       = result.ft
        pars_det._trap_ft_err   = step(dsp_config.e_grid_ft_trap)
        pars_det.trap_min_fwhm = result.min_fwhm
    end

    # # save pars to disk
    @info "Save pars to disk"
    pars_filename       = format("{}-{}-{}-{}-filter_optimization.json", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category))
    pars_validTimeStamp = string(filekey.time)
    # write params
    writeprops(joinpath(pars_folder, pars_filename), pars_db, multiline=true)
    # write validity
    open(joinpath(pars_folder, "validity.jsonl"), "a") do io
        println(io, "{\"valid_from\":\"$pars_validTimeStamp\", \"category\":\"all\", \"apply\":[\"$pars_filename\"]}")
    end
end

