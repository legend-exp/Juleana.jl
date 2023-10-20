# using LegendDataManagement, PropertyFunctions, TypedTables, PropDicts
# using Unitful, Formatting, LaTeXStrings
# using Plots, StatsBase
# using LegendHDF5IO, LegendDSP, LegendSpecFits
# using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked

# ENV["JULIA_DEBUG"] = Main # enable debug

# gr()
# plotlyjs()

# @info "Loading Legend MetaData"
# l200 = LegendData(:l200)

# period = DataPeriod(3)
# run    = DataRun(1)


function process_qc(l200::LegendData, period::DataPeriod, run::DataRun)
    @info "Generate QC cuts for period $period and run $run"

    filekeys = sort(search_disk(FileKey, l200.tier[:raw, :cal, period, run]), by = x-> x.time)
    filekey = filekeys[1]
    @info "Found filekey $filekey"

    chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable)

    sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)

    @debug "Create QC folder"
    qc_folder = l200.tier[:qc, :cal, period, run]
    ifelse(isdir(qc_folder), @debug("QC folder $qc_folder already exists"), mkpath(qc_folder))

    @debug "Create figures folder"
    figures_folder = joinpath(l200.tier[:plt, :cal, period, run], "qc")
    ifelse(isdir(figures_folder), @debug("Figure folder $figures_folder already exists"), mkpath(figures_folder))

    for str in unique(chinfo.string)
        figures_folder_string = joinpath(figures_folder, format("string{:02d}", str))
        ifelse(isdir(figures_folder_string), @debug("String Figure folder $figures_folder_string already exists"), mkpath(figures_folder_string))
    end

    @debug "Create pars folder"
    pars_folder = joinpath(l200.tier[:par, :cal, period, run], "qc")
    ifelse(isdir(pars_folder), @debug("Pars folder $pars_folder already exists"), mkpath(pars_folder))

    @debug "Create pars db"
    pars_db = PropDict()

    for (i, ch_short) in enumerate(chinfo.channel)
        # ch_short = chinfo.channel[i]
        string_number = chinfo.string[i]
        ch = format("ch{}", ch_short)
        det = chinfo.detector[i]

        figures_folder_string = joinpath(figures_folder, format("string{:02d}", string_number))

        if haskey(l200.metadata.dataprod.config.cal.qc(sel), det)
            qc_config = l200.metadata.dataprod.config.cal.qc(sel)[det]
            @debug "Use config for detector $det"
        else
            qc_config = l200.metadata.dataprod.config.cal.qc(sel).default
            @debug "Use default config"
        end

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
            @warn "No files found for channel $ch, skip"
            continue
        end

        data_ch = fast_flatten([
            LHDataStore(
                ds -> begin
                    @debug "Reading from \"$(ds.data_store.filename)\""
                    ds[ch][:]
                end,
                l200.tier[:dsp, fk]
            ) for fk in ch_filekeys
        ])

        @debug "Number of events: $(length(data_ch))"
        @debug "Median of baseline mean : $(median(data_ch.blmean))"
        @debug "Median of baseline std  : $(median(data_ch.blsigma))"
        @debug "Median of baseline slope: $(median(data_ch.blslope))"

        min_blmean, max_blmean = qc_config.blmean.min, qc_config.blmean.max
        n_bins_blmean = convert(Int64, round(length(data_ch)/100))
        rel_cut_blmean = qc_config.blmean.rel_cut
        blmean_cut = cut_single_peak(data_ch.blmean, min_blmean, max_blmean, n_bins_blmean, rel_cut_blmean)

        blmean_qc = data_ch.blmean .> blmean_cut.low .&& data_ch.blmean .< blmean_cut.high
        blmean_cut_sf = count(blmean_qc)/length(data_ch.blmean)
        @debug format("Baseline mean surrival fraction: {:.2f}%", blmean_cut_sf*100)

        plot(data_ch.blmean, blmean_cut, nbins = n_bins_blmean, xlabel="Baseline Mean (ADC)", title=format("{} Baseline Mean ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
        savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-baseline_mean.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

        min_blslope, max_blslope = qc_config.blslope.min*u"ns^-1", qc_config.blslope.max*u"ns^-1"
        n_bins_blslope = convert(Int64, round(length(data_ch)/20))
        rel_cut_blslope = qc_config.blslope.rel_cut
        blslope_cut = cut_single_peak(data_ch.blslope, min_blslope, max_blslope, n_bins_blslope, rel_cut_blslope)

        blsope_qc = data_ch.blslope .> blslope_cut.low .&& data_ch.blslope .< blslope_cut.high
        blsope_cut_sf = count(blsope_qc)/length(data_ch.blslope)
        @debug format("Baseline slope surrival fraction: {:.2f}%", blsope_cut_sf*100)

        plot(data_ch.blslope, blslope_cut, nbins = n_bins_blslope, xlabel="Baseline Slope", title=format("{} Baseline Slope ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
        xlims!(ustrip(median(data_ch.blslope) - 0.1*std(data_ch.blslope)), ustrip(median(data_ch.blslope) + 0.1*std(data_ch.blslope)))
        savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-baseline_slope.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

        min_blstd, max_blstd = qc_config.blstd.min, qc_config.blstd.max
        n_bins_blstd = convert(Int64, round(length(data_ch)/20))
        rel_cut_blstd = qc_config.blstd.rel_cut
        blstd_cut = cut_single_peak(data_ch.blsigma, min_blstd, max_blstd, n_bins_blstd, rel_cut_blstd)

        blstd_qc = data_ch.blsigma .> blstd_cut.low .&& data_ch.blsigma .< blstd_cut.high
        blstd_cut_sf = count(blstd_qc)/length(data_ch.blsigma)
        @debug format("Baseline std surrival fraction: {:.2f}%", blstd_cut_sf*100)

        plot(data_ch.blsigma, blstd_cut, nbins = n_bins_blstd, xlabel="Baseline Std (ADC)", title=format("{} Baseline Std ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
        xlims!(0, blstd_cut.max + blstd_cut.high)
        savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-baseline_std.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

        min_t0, max_t0 = qc_config.t0.min*u"µs", qc_config.t0.max*u"µs"
        n_bins_t0 = convert(Int64, round(length(data_ch)/500))
        rel_cut_t0 = qc_config.t0.rel_cut
        t0_cut = cut_single_peak(data_ch.t0, min_t0, max_t0, n_bins_t0, rel_cut_t0)

        t0_qc = data_ch.t0 .> t0_cut.low .&& data_ch.t0 .< t0_cut.high
        t0_cut_sf = count(t0_qc)/length(data_ch.t0)
        @debug format("t0 surrival fraction: {:.2f}%", t0_cut_sf*100)

        plot(data_ch.t0, t0_cut, nbins = n_bins_t0, xlabel="t0 (µs)", title=format("{} t0 ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
        savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-t0.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

        # TODO: remove len_wf to dsp processing
        inTrace_qc = .!(data_ch.inTrace_intersect .< data_ch.t0 .- 2 .* data_ch.drift_time .&& data_ch.inTrace_n .> 1)
        inTrace_cut_sf = count(inTrace_qc)/length(data_ch.inTrace_intersect)
        @debug format("In-Trace surrival fraction: {:.2f}%", inTrace_cut_sf*100)
        plot(data_ch.inTrace_n, st=:barhist, bins=0.5:1:maximum(data_ch.inTrace_n)+0.5, xlabel="In-Trace Pile-Up", title=format("{} In-Trace Pile-Up ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)), fillcolor=:blue)
        savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-inTrace_pileUp.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

        qc = TypedTables.Table(
            blmean = blmean_qc,
            blslope = blsope_qc,
            blstd = blstd_qc,
            t0 = t0_qc,
            inTrace = inTrace_qc,
            qc = blmean_qc .&& blsope_qc .&& blstd_qc .&& t0_qc .&& inTrace_qc
        )

        #save pars to db
        pars_det  = pars_db[det]
        pars_det.blmean_cut_sf  = blmean_cut_sf
        pars_det.blsope_cut_sf  = blsope_cut_sf
        pars_det.blstd_cut_sf   = blstd_cut_sf
        pars_det.t0_cut_sf      = t0_cut_sf
        pars_det.inTrace_cut_sf = inTrace_cut_sf
        pars_det.qc             = count(qc.qc)/length(qc.qc)    


        outfilename = joinpath(l200.tier[:qc, :cal, period, run], format("{}-{}-{}-{}-{}-tier_qc.lh5", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch))
        @info "Save data to $(outfilename)"

        outdata = LHDataStore(outfilename, "w")

        outdata["$ch/qc"] = qc
        outdata["$ch/after_qc"] = data_ch[qc.qc]
        outdata["$ch/before_qc"] = data_ch

        close(outdata)
    end
    # # save pars to disk
    @info "Save pars to disk"
    pars_filename       = format("{}-{}-{}-{}-qc.json", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category))
    pars_validTimeStamp = string(filekey.time)
    # write params
    writeprops(joinpath(pars_folder, pars_filename), pars_db, multiline=true)
    # write validity
    open(joinpath(pars_folder, "validity.jsonl"), "a") do io
        println(io, "{\"valid_from\":\"$pars_validTimeStamp\", \"category\":\"all\", \"apply\":[\"$pars_filename\"]}")
    end
end