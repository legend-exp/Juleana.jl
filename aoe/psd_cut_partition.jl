# using LegendDataManagement, PropertyFunctions, TypedTables, PropDicts
# using Unitful, Formatting, LaTeXStrings, Measures
# using Plots, StatsBase
# using LegendHDF5IO, LegendDSP, LegendSpecFits
# using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked

# ENV["JULIA_DEBUG"] = Main # enable debug

# gr(size=(1500, 800))
# # plotlyjs(size=(800, 500))
# # plotlyjs(size=(600, 500))
# @info "Loading Legend MetaData"
# l200 = LegendData(:l200)

# partition_n = 1

function process_psd_partition(l200::LegendData, partition_n::Int,; reprocess::Bool=false, timeout::Int=300)
    @info "PSD calibration for partition $partition_n"

    partition = data_partitions(l200)[partition_n]
    period = filter(row -> row.period == minimum(partition.period), partition).period[1]
    partition_period = partition[[p == period for p in partition.period]]
    run = filter(row -> row.run == minimum(partition_period.run), partition_period).run[1]

    filekey = first(sort(search_disk(FileKey, l200.tier[:dsp, :cal, period, run]), by = x-> x.time))
    @info "Found filekey $filekey"

    chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable && $usability == :on)

    sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)

    hit_folder = l200.tier[:hit_ch, :cal, period, run]

    @debug "Create figures folder"
    figures_folder = joinpath(l200.tier[:plt, :cal], format("partition{:02d}/psd", partition_n))
    if isdir(figures_folder)
        @debug("Figure folder $figures_folder already exists")
    else
        mkpath(figures_folder)
    end

    @debug "Create logs folder"
    log_folder = joinpath(l200.tier[:log, :cal], format("partition{:02d}/psd", partition_n))
    if isdir(log_folder)
        @debug("Log folder $figures_folder already exists")
    else
        mkpath(log_folder)
    end

    @debug "Create pars db"
    pars_db = PropDict()
    # read params if exist
    if !(isfile(joinpath(l200.tier[:par, :cal], format("p_psd/partition{:02d}.json", partition_n))))
        # path folder for current period seems not to exist, will create it first to avoid errors
        mkpath(joinpath(l200.tier[:par, :cal], format("p_psd")))
    else
        @info "Pars file already exists."
        pars_db = l200.par[:cal, :p_psd](filekey)
    end

    if reprocess
        @info "Reprocess all channels"
        for det in keys(pars_db)
            pars_db[det].aoecut = nothing
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
        partition_n = $partition_n
        partition = $partition
        chinfo = $chinfo
        figures_folder = $figures_folder
        hit_folder = $hit_folder
        pars_db = $pars_db
        reprocess = $reprocess
    end
    
    @everywhere function ch_psd_cut(i::Int64)

        ch_short = chinfo.channel[i]
        ch = format("ch{}", ch_short)
        string_number = chinfo.string[i]
        det = chinfo.detector[i]

        if !reprocess && haskey(pars_db, det) && haskey(pars_db[det], :aoecut)
            @debug "Channel $(chinfo.detector[i]) already processed, skip"
            # log = "| $ch | $det | Success | $(pars_db[det].sg.wl.val*u"ns") | $(round(pars_db[det].sg.min_sep_sf, digits=2)) | $(round(pars_db[det].sg.min_sep_sf_err, digits=2)) | Already processed --> skipped. |"
            result_peaks = pars_db[det].aoesf
            result_cut = pars_db[det].aoecut
            log_info = "| $ch | $det | Success | $(round(result_cut.lo, digits=2))±$(round(result_cut.err.lo, digits=2)) | $(round(result_peaks[:Tl208SEP].sf*100, digits=2))±$(round(result_peaks[:Tl208SEP].err.sf*100, digits=2))% | $(round(result_peaks[:Tl208FEP].sf*100, digits=2))±$(round(result_peaks[:Tl208FEP].err.sf*100, digits=2))% | Already processed --> skipped. |"
            return (result = NamedTuple(), log = log_info)
        end


        # load config
        if haskey(l200.metadata.dataprod.config.psd(sel), det)
            psd_config = merge(l200.metadata.dataprod.config.psd(sel).default, l200.metadata.dataprod.config.psd(sel)[det])
            @debug "Use config for detector $det"
        else
            psd_config = l200.metadata.dataprod.config.psd(sel).default
            @debug "Use default config"
        end

        psd_peaks = Float64.(psd_config.psd_peaks)
        psd_peaks_window_sizes = Vector{Tuple{Float64, Float64}}([(l,r) for (l,r) in zip(Vector{Float64}(psd_config.psd_peaks_windows_left), Vector{Float64}(psd_config.psd_peaks_windows_right))])
        psd_peak_names = Symbol.(psd_config.psd_peaks_names)
        psd_peak_dict = Dict(zip(psd_peak_names, psd_peaks))
        qbb =  psd_config.qbb
        qbb_window = psd_config.qbb_window
        sigma_high_sided = 5.0
        e_type = Symbol(psd_config.energy_type)

        e, aoe = nothing, nothing
        try
            aoe = fast_flatten([LHDataStore(
                ds -> begin
                    @debug "Reading from \"$(ds.data_store.filename)\""
                    a = ds["$(ch)/dataQC/a"][:]
                    e = calibrate_energy!(ds["$(ch)/dataQC/$(e_type)"][:], l200.par[:cal, :energy, period, run][det][e_type].energy)
                    correct_aoe!(a ./ e, e, l200.par[:cal, :psd, period, run][det].calibration)
                end,
                joinpath(l200.tier[:hit_ch, :cal, period, run], format("{}-{}-{}-{}-{}-tier_hit.lh5", string(filekey.setup), string(period), string(run), string(filekey.category), ch))
            ) for (period, run) in partition ])

            e = fast_flatten([ LHDataStore(
                ds -> begin
                    @debug "Reading from \"$(ds.data_store.filename)\""
                    calibrate_energy!(ds["$(ch)/dataQC/$(e_type)"][:], l200.par[:cal, :energy, period, run][det][e_type].energy)
                end,
                joinpath(l200.tier[:hit_ch, :cal, period, run], format("{}-{}-{}-{}-{}-tier_hit.lh5", string(filekey.setup), string(period), string(run), string(filekey.category), ch))
            ) for (period, run) in partition ])
        catch e
            @error "AoE and E data for $det from cannot be loaded"
            throw(LoadError("AoE - E data", 154, "AoE and E data for $det from partition $(partition_n) cannot be loaded"))
        end

        # histogram2d(e, aoe, nbins=(0:0.5:3000, -15:0.02:10), xlims=(0, 3000), ylims=(-15, 10), size=(1000, 600), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy (keV)", ylabel="A/E ( σ)")
        # plot!(margin=1mm, thickness_scaling=1.6, dpi=600, size=(1000, 600), xticks=(0:250:3000), yticks=(-16:2:10), fontfamily=:sansserif)
        # plot!(title=format("{} A/E Classifier ({}-Partition{:02d}-{})", string(det), string(filekey.setup), partition_n, string(filekey.category)))

        result_cut = nothing
        try
            @debug "Generate PSD cut"
            result_cut = get_psd_cut(aoe, e,; cut_search_interval=(-25.0, 0.0), window=[20.0, 20.0], rtol=1e-5, bin_width_window=5.0, fixed_position=false)            
        catch e
            @error "PSD cut for $det cannot be generated"
            throw(ErrorException("PSD cut for $det from partition $(partition_n) cannot be generated"))
        end

        result_peaks, report_peaks = nothing, nothing
        try
            @debug "Generate PSD Surrival Fractions"
            result_peaks, report_peaks = get_peaks_surrival_fractions(aoe, e, psd_peaks, psd_peak_names, psd_peaks_window_sizes, result_cut.cut,; bin_width_window=3.0, low_e_tail=false, sigma_high_sided=sigma_high_sided)
        catch e
            @error "PSD peaks SF for $det cannot be generated"
            throw(ErrorException("PSD peaks SF for $det from partition $(partition_n) cannot be generated"))
        end

        qbb_result = nothing
        try
            qbb_result = get_continuum_surrival_fraction(aoe, e, qbb, qbb_window, result_cut.cut,; sigma_high_sided=sigma_high_sided)
        catch e
            @error "Qbb SF for $det cannot be generated"
            throw(ErrorException("Qbb SF for $det from partition $(partition_n) cannot be generated"))
        end

        stephist(e, nbins=2039-35:0.5:2039+35, label="Before", xlabel="Energy (keV)", ylabel="Counts / 0.5 keV", yscale=:log10)
        stephist!(e[aoe .> result_cut.cut], nbins=2039-35:0.5:2039+35, label="After", xlabel="Energy (keV)", ylabel="Counts / 0.5 keV", yscale=:log10)
        plot!(margin=1mm, thickness_scaling=1.5, dpi=600, size=(1000, 700))
        title!(format("Qbb CC ({} ± {}keV) - SF: {:.2f} ± {:.2f}%", qbb, qbb_window, qbb_result.sf*100, qbb_result.err.sf*100), titlefontisze=8)
        plot!(plot_title=format("{} ({}-Partition{:02d}-{})", string(det), string(filekey.setup), partition_n, string(filekey.category)), subplot=1)
        savefig(joinpath(figures_folder, format("{}-partition{:02d}-{}-{}_QbbSF_afterPSD_{}.png", string(filekey.setup), partition_n, string(filekey.category), ch, string(e_type))))
        

        peak_sf_plot = plot.([rep.after for rep in values(report_peaks)], titleloc=:left, titlefont=font(8), ticks=:native, legend=:bottomright; show_label=true, show_fit=false)
        for (p, rep_before) in zip(peak_sf_plot, [rep.before for rep in values(report_peaks)])
            plot!(p, rep_before,; show_label=true, show_fit=false)
            p.series_list[1][:label] = "After"
            p.series_list[2][:label] = "Before"
        end
        for (p, peak_name, res) in zip(peak_sf_plot, keys(result_peaks), values(result_peaks))
            xticks!(p, convert(Int, round(xlims(p)[1], digits=0)):10:convert(Int, round(xlims(p)[2], digits=0)))
            title!(p, format("{} ({} keV) - SF: {:.2f} ± {:.2f}%", string(peak_name), psd_peak_dict[peak_name], res.sf*100, res.err.sf*100))
        end
        plot(
            peak_sf_plot...,
            layout = @layout[grid(2, 2)], 
            size=(2000, 1200), legend=:bottomright,
            framestyle=:box,
            grid=true, minor=true, gridalpha=0.2, gridcolor=:black, gridlinewidth=0.5,
            xlabel="Energy (keV)", ylabel="Counts",
            dpi = 300, thickness_scaling = 2,
            yformatter=:plain, titlefont=12,
            fontfamily=:sansserif
        )
        plot!(margin=1mm, thickness_scaling=1.2, dpi=600, size=(1200, 900))
        plot!(plot_title=format("{} Peak SF ({}-Partition{:02d}-{})", string(det), string(filekey.setup), partition_n, string(filekey.category)), subplot=1)
        savefig(joinpath(figures_folder, format("{}-partition{:02d}-{}-{}_peaksSF_afterPSD_{}.png", string(filekey.setup), partition_n, string(filekey.category), ch, string(e_type))))

        stephist(e, nbins=0:0.5:3000, yscale=:log10, xlabel="Energy (keV)", label="Trap Energy", ylabel="Counts / 0.2 keV")
        stephist!(e[result_cut.cut .< aoe .< sigma_high_sided], nbins=0:0.5:3000, yscale=:log10, xlabel="Energy (keV)", label="Trap Energy after PSD", ylabel="Counts / 0.2 keV")
        plot!(title=format("{} Energy ({}-Partition{:02d}-{})", string(det), string(filekey.setup), partition_n, string(filekey.category)), subplot=1)
        plot!(margin=1mm, thickness_scaling=1.2, dpi=600, size=(1000, 600), fontfamily=:sansserif)
        savefig(joinpath(figures_folder, format("{}-partition{:02d}-{}-{}_energy_afterPSD_{}.png", string(filekey.setup), partition_n, string(filekey.category), ch, string(e_type))))


        stephist(e, nbins=0:0.5:3000, yscale=:log10, xlabel="Energy (keV)", label="Trap Energy", ylabel="Counts / 0.5 keV")
        stephist!(e[result_cut.cut .< aoe .< sigma_high_sided], nbins=0:0.5:3000, yscale=:log10, label="Trap Energy after PSD")
        stephist!(e, nbins=1550:0.5:1700, inset = (1, bbox(0.2, 0.72, 0.4, 0.2, :top)), subplot = 2,)
        stephist!(e[result_cut.cut .< aoe .< sigma_high_sided], nbins=1550:0.5:1700, subplot = 2, legend=:none, ylabel="Counts / 0.5 keV")
        xticks!(0:250:3000, subplot = 1)
        xticks!(1500:20:1700, subplot = 2)
        plot!(title=format("{} Energy ({}-Partition{:02d}-{})", string(det), string(filekey.setup), partition_n, string(filekey.category)), subplot=1)
        plot!(margin=1mm, thickness_scaling=1.2, dpi=600, size=(1000, 600), fontfamily=:sansserif)
        savefig(joinpath(figures_folder, format("{}-partition{:02d}-{}-{}_energy_afterPSD_withZoom_{}.png", string(filekey.setup), partition_n, string(filekey.category), ch, string(e_type))))

        histogram2d(e, aoe, nbins=(0:0.5:3000, -15:0.02:10), xlims=(0, 3000), ylims=(-7, 7), size=(1000, 600), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy (keV)", ylabel="A/E ( σ)")
        plot!(margin=1mm, thickness_scaling=1.6, dpi=600, size=(1000, 600), xticks=(0:250:3000), yticks=(-16:1:10), fontfamily=:sansserif)
        plot!(title=format("{} A/E Classifier ({}-Partition{:02d}-{})", string(det), string(filekey.setup), partition_n, string(filekey.category)))
        hline!([result_cut.cut, 5.0], color=:red, label="Cut", lw=2.5)
        savefig(joinpath(figures_folder, format("{}-partition{:02d}-{}-{}_aoe_withCuts_{}.png", string(filekey.setup), partition_n, string(filekey.category), ch, string(e_type))))

        # save results
        result = (
            cut = result_cut,
            peaks = result_peaks,
            qbb = qbb_result,
            e_type = e_type,
            sigma_high_sided = sigma_high_sided,
        )

        log_info = "| $ch | $det | Success | $(round(result_cut.cut, digits=2))±$(round(result_cut.err.cut, digits=2)) | $(round(result_peaks[:Tl208SEP].sf*100, digits=2))±$(round(result_peaks[:Tl208SEP].err.sf*100, digits=2))% | $(round(result_peaks[:Tl208FEP].sf*100, digits=2))±$(round(result_peaks[:Tl208FEP].err.sf*100, digits=2))% | - |"
        return (result = result, log = log_info)

    end


    Base.exit_on_sigint(false)
    result_psd =  @showprogress pmap(eachindex(chinfo.channel); batch_size = 1, retry_check=retry_check, retry_delays=ExponentialBackOff(n=3)) do idx
        try
            t_end = time() + timeout
            task = Threads.@spawn ch_psd_cut(idx)
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
            log_info = "| ch$(chinfo.channel[idx]) | $(chinfo.detector[idx]) | Failed | - | - | - | $(e) |"
            chinfo.detector[idx] => (result = NamedTuple(), log = log_info)
        end
    end

    @info "Finished PSD calibration"
    @info "Remove all workers"
    rmprocs(workers()...)

    main_log = """
    # Main log 
    Time of processing: $(now())
    ## PSD CUT
    This is the log for the PSD CUT generation for the AoE PSD analysis. The processing involves 
    generating a cut that let's 90% of the events in the Tl-208 DEP pass. The cut is generated by
    sweeping through different values of the cut and finding the root with 90% of the original peak counts.

    # MetaData
    | Setup | Partition | Category |
    |-------|-----------|----------|
    | $(filekey.setup) | $(partition_n) | $(filekey.category) |

    # Results
    | Channel | Detector | Status | Cut value | SEP SF | FEP SF | Error |
    |---------|----------|--------|-----------|--------|--------|-------|
    """
    # extract results into pars_db and append to main log
    for (det, res) in result_psd
        # save pars to db
        if !isempty(res.result)
            pars_det                    = pars_db[det].aoecut
            pars_det.lo                 = res.result.cut.cut
            pars_det.err.lo             = res.result.cut.err.cut
            pars_det.hi                 = res.result.sigma_high_sided
            pars_det.err.hig            = 0.0
            pars_det.e_type             = string(res.result.e_type)
            pars_det.n0                 = res.result.cut.n0
            pars_det.err.n0             = res.result.cut.err.n0
            pars_det.nsf                = res.result.cut.nsf
            pars_det.err.nsf            = res.result.cut.err.nsf
            # save surrival fractions
            pars_det                    = pars_db[det].aoesf
            for (peak_name, peak_res) in res.result.peaks
                pars_det[peak_name]     = peak_res
            end
            pars_det.qbb                = res.result.qbb
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
    writeprops(joinpath(l200.tier[:par, :cal], "p_psd", format("partition{:02d}.json", partition_n)), pars_db, multiline=true)

    # write validity
    pars_validTimeStamp = string(filekey.time)
    add_validity = true
    for ln in eachline(open(joinpath(l200.tier[:par, :cal], "p_psd", "validity.jsonl"), "r"))
        if (contains(ln, "$pars_validTimeStamp"))
            add_validity = false
        end
    end
    if add_validity
        open(joinpath(l200.tier[:par, :cal], "p_psd", "validity.jsonl"), "a") do io
            pars_filename = format("partition{:02d}.json", partition_n)
            println(io, "{\"valid_from\":\"$pars_validTimeStamp\", \"category\":\"all\", \"apply\":[\"$pars_filename\"]}")
        end
    end

    @info "Write main log to disk"
    @info main_log

    log_filename = joinpath(log_folder, format("{}-partition{:02d}-{}-psd_cut.md", string(filekey.setup), partition_n, string(filekey.category)))
    open(log_filename, "w+") do file
        write(file, replace(main_log, "Success" => raw"$${\color{green}Success}$$", "Failed" => raw"$${\color{red}Failed}$$"))
    end

end

