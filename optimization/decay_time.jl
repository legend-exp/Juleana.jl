using LegendDataManagement, PropertyFunctions, TypedTables, PropDicts
using Unitful, Formatting, LaTeXStrings
using Plots
using LegendHDF5IO, LegendDSP, LegendSpecFits

ENV["JULIA_DEBUG"] = Main # enable debug

plotlyjs()

# @info "Loading Legend MetaData"
# l200 = LegendData(:l200)

# period = DataPeriod(3)
# run    = DataRun(1)

function process_decay_time(l200, period, run)

    @info "Process decay time for period $period and run $run"

    # search_disk(DataCategory, l200.tier[:raw])
    # search_disk(DataPeriod, l200.tier[:raw, :cal])
    # search_disk(DataRun, l200.tier[:raw, :cal, period])
    # search_disk(DataRun, l200.tier[:raw, :cal, string(period)])

    filekey = sort(search_disk(FileKey, l200.tier[:raw, :cal, period, run]), by = x-> x.time)[1]
    @info "Found filekey $filekey"

    chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable)

    sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)
    dsp_meta = l200.metadata.dataprod.config.dsp(sel).default
    dsp_config = create_dsp_config(dsp_meta)
    @debug "Loaded DSP config: $(dsp_config)"

    @debug "Create figures folder"
    figures_folder = joinpath(l200.tier[:plt, :cal, period, run], "decay_time")
    ifelse(isdir(figures_folder), @debug("Figure folder $figures_folder already exists"), mkpath(figures_folder))

    @debug "Create pars folder"
    pars_folder = joinpath(l200.tier[:par, :cal, period, run], "decay_time")
    ifelse(isdir(pars_folder), @debug("Pars folder $pars_folder already exists"), mkpath(pars_folder))

    @debug "Create pars db"
    pars_db = PropDict()

    for (i, ch_short) in enumerate(chinfo.channel)
        ch = format("ch{}", ch_short)
        det = chinfo.detector[i]
        @debug "Processing channel $ch ($det)"

        if haskey(l200.metadata.dataprod.config.dsp.decay_time(sel), det)
            decay_time_config = l200.metadata.dataprod.config.dsp.decay_time(sel)[det]
            @debug "Use config for detector $det"
        else
            decay_time_config = l200.metadata.dataprod.config.dsp.decay_time(sel).default
            @debug "Use default config"
        end

        # unpack config
        min_τ, max_τ = decay_time_config.min_tau*u"µs", decay_time_config.max_tau*u"µs"
        nbins = decay_time_config.nbins
        rel_cut_fit = decay_time_config.rel_cut_fit


        filename = joinpath(l200.tier[DataTier(:peaks), :cal, period, run], format("{}-{}-{}-{}-{}-tier_peaks.lh5", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch))
        if !isfile(filename)
            @warn "File $filename does not exist, Skip channel $ch"
            continue
        end
        data = LHDataStore(filename, "r")
        @debug "Loading Tl208 FEP data from $(filename)"
        wvfs_ch_fep = data[ch].Tl208a.waveform[:]
        decay_times = dsp_decay_times(wvfs_ch_fep, dsp_config)

        cuts_τ = cut_single_peak(decay_times, min_τ, max_τ, nbins, rel_cut_fit)

        result, report = fit_single_trunc_gauss(decay_times, cuts_τ)

        plot(report, decay_times, cuts_τ)
        xlabel!("Decay Time [µs]")
        title!(format("{} Decay Time Distribution ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))

        savefig(joinpath(figures_folder, format("{}-{}-{}-{}-{}-decay_time.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

        # save pars to db
        pars_det = pars_db[det]
        pars_det.tau       = result.μ
        pars_det.tau_err   = result.μ_err
        pars_det.sigma     = result.σ
        pars_det.sigma_err = result.σ_err
        pars_det.n_tau     = result.n
    end

    # save pars to disk
    @info "Save pars to disk"
    pars_filename       = format("{}-{}-{}-{}-decay_time.json", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category))
    pars_validTimeStamp = string(filekey.time)
    # write params
    writeprops(joinpath(pars_folder, pars_filename), pars_db, multiline=true)
    # write validity
    open(joinpath(pars_folder, "validity.jsonl"), "a") do io
        println(io, "{\"valid_from\":\"$pars_validTimeStamp\", \"category\":\"all\", \"apply\":[\"$pars_filename\"]}")
    end
end