function process_energy_partition(l200::LegendData, partition_n::Int,; reprocess::Bool=false, timeout::Int=300)
    @info "Energy calibration for partition $partition_n"

    partition = data_partitions(l200)[partition_n]
    period = filter(row -> row.period == minimum(partition.period), partition).period[1]
    partition_period = partition[[p == period for p in partition.period]]
    run = filter(row -> row.run == minimum(partition_period.run), partition_period).run[1]

    filekey = first(sort(search_disk(FileKey, l200.tier[:dsp, :cal, period, run]), by = x-> x.time))
    @info "Found filekey $filekey"

    chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable && $usability != :off)

    sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)

    hit_folder = l200.tier[:hit_ch, :cal, period, run]

    @debug "Create figures folder"
    figures_folder = joinpath(l200.tier[:plt, :cal], format("partition{:02d}/energy", partition_n))
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
    log_folder = joinpath(l200.tier[:log, :cal], format("partition{:02d}/energy", partition_n))
    if isdir(log_folder)
        @debug("Log folder $figures_folder already exists")
    else
        mkpath(log_folder)
    end

    @debug "Create pars db"
    pars_db = PropDict()
    # read params if exist
    if !(isfile(joinpath(l200.tier[:par, :cal], format("p_energy/partition{:02d}.json", partition_n))))
        # path folder for current period seems not to exist, will create it first to avoid errors
        mkpath(joinpath(l200.tier[:par, :cal], format("p_energy")))
    else
        @info "Pars file already exists."
        pars_db = l200.par[:cal, :p_energy](filekey)
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
    
    @everywhere function ch_energy_calibration(i::Int64)
        ch_short = chinfo.channel[i]
        ch = format("ch{}", ch_short)
        string_number = chinfo.string[i]
        det = chinfo.detector[i]

        figures_folder_string = joinpath(figures_folder, format("string{:02d}", string_number))


        @debug "Processing channel $ch ($det)"

        result_dict    = Dict{Symbol, NamedTuple}()
        log_info_dict  = Dict{Symbol, String}()

        if haskey(l200.metadata.dataprod.config.energy(sel), det) && haskey(l200.metadata.dataprod.config.energy(sel)[det], :p)
            energy_config = merge(l200.metadata.dataprod.config.energy(sel).p_default, l200.metadata.dataprod.config.energy(sel)[det].p)
            @debug "Use config for detector $det"
        else
            energy_config = l200.metadata.dataprod.config.energy(sel).p_default
            @debug "Use default config"
        end

        energy_types = Symbol.(energy_config.energy_types)

        if !reprocess && haskey(pars_db, det)
            @debug "Channel $(chinfo.detector[i]) already processed, check missing energy types"
            for e_type in energy_types
                if haskey(pars_db[det], e_type) && haskey(pars_db[det][e_type], :energy)
                    log_info = "| $ch | $det | Success | $e_type | $(round(pars_db[det][e_type].energy.fwhm_qbb, digits=2))±$(round(pars_db[det][e_type].energy.fwhm_qbb_err, digits=2)) | $(round(pars_db[det][e_type].energy[:Tl208FEP].fwhm, digits=2))±$(round(pars_db[det][e_type].energy[:Tl208FEP].err.fwhm, digits=2)) | $(round(pars_db[det][e_type].energy.m_calib, digits=2)) | Already processed --> skipped. |"
                    result_dict[e_type] = NamedTuple()
                    log_info_dict[e_type] = log_info
                end
                if haskey(pars_db[det], Symbol("$(e_type)_ctc")) && haskey(pars_db[det][Symbol("$(e_type)_ctc")], :energy)
                    log_info = "| $ch | $det | Success | $(e_type)_ctc | $(round(pars_db[det][Symbol("$(e_type)_ctc")].energy.fwhm_qbb, digits=2))±$(round(pars_db[det][Symbol("$(e_type)_ctc")].energy.fwhm_qbb_err, digits=2)) | $(round(pars_db[det][Symbol("$(e_type)_ctc")].energy[:Tl208FEP].fwhm, digits=2))±$(round(pars_db[det][Symbol("$(e_type)_ctc")].energy[:Tl208FEP].err.fwhm, digits=2)) | $(round(pars_db[det][Symbol("$(e_type)_ctc")].energy.m_calib, digits=2)) | Already processed --> skipped. |"
                    result_dict[Symbol("$(e_type)_ctc")] = NamedTuple()
                    log_info_dict[Symbol("$(e_type)_ctc")] = log_info
                end
            end
        end

        th228_lines = Vector{Float64}(energy_config.th228_lines)
        th228_names = Symbol.(energy_config.th228_names)
        th228_names_dict  = Dict{Symbol, Float64}(Symbol.(energy_config.th228_names) .=> th228_lines)
        window_sizes = Vector{Tuple{Float64, Float64}}([(l,r) for (l,r) in zip(Vector{Float64}(energy_config.left_window_sizes), Vector{Float64}(energy_config.right_window_sizes))])
        n_bins = energy_config.n_bins
        quantile_perc = nothing
        if !(energy_config.quantile_perc isa Number)
            quantile_perc = parse(Float64, energy_config.quantile_perc)
        else
            quantile_perc = energy_config.quantile_perc
        end


        for e_type_name in energy_types
            for e_type in [e_type_name, Symbol("$(e_type_name)_ctc")]
                if haskey(result_dict, e_type)
                    continue
                end
                try
                    @debug "Calibrate $e_type"

                    energy = nothing
                    try
                        energy = fast_flatten([ LHDataStore(
                            ds -> begin
                                @debug "Reading from \"$(ds.data_store.filename)\""
                                e_uncal = ds["$(ch)/dataQC/$(e_type_name)"][:]
                                if endswith(string(e_type), "_ctc")
                                    fct = l200.par[:cal, :energy, period, run][det][e_type_name].ctc.fct
                                    e_uncal = e_uncal .+ fct .* ds["$(ch)/dataQC/qdrift"][:]
                                end
                                calibrate_energy!(e_uncal, l200.par[:cal, :energy, period, run][det][e_type].energy)
                            end,
                            joinpath(l200.tier[:hit_ch, :cal, period, run], format("{}-{}-{}-{}-{}-tier_hit.lh5", string(filekey.setup), string(period), string(run), string(filekey.category), ch))
                        ) for (period, run) in partition ])
                    catch e
                        @error "E data for $det from cannot be loaded"
                        throw(LoadError("E data", 154, "E data for $det from partition $(partition_n) cannot be loaded"))
                    end
                    GC.gc()

                    result_simple, report_simple = nothing, nothing
                    try
                        @debug "Get $e_type simple calibration"
                        result_simple, report_simple = simple_calibration(energy, th228_lines, window_sizes,; n_bins=n_bins, quantile_perc=quantile_perc)
                    catch e
                        @error "Error in $e_type simple calibration for channel $ch: $e"
                        throw(ErrorException("Error in $e_type simple calibration"))
                    end
                    GC.gc()

                    m_cal_simple = result_simple.c
                    # save plots for simple calibration for control
                    plot(report_simple, margin=5mm, yformatter=:plain, thickness_scaling=1.5, cal=true, title=format("{} Simple Calibration ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
                    savefig(joinpath(figures_folder_string, format("{}-partition{:02d}-{}-{}-simple_calibration_{}.png", string(filekey.setup), partition_n, string(filekey.category), ch, string(e_type))))

                    yield()

                    result_fit, report_fit = nothing, nothing
                    try
                        @debug "Fit all $e_type peaks"
                        result_fit, report_fit = fit_peaks(result_simple.peakhists, result_simple.peakstats, th228_names)
                    catch e
                        @error "Error in $e_type peak fitting for channel $ch: $e"
                        throw(ErrorException("Error in $e_type peak fitting"))
                    end
                    GC.gc()

                    peak_fit_plot = plot.(values(report_fit), titleloc=:center, titlefont=font(family="monospace",halign=:center, pointsize=20), ticks=:native, right_margin=10mm, top_margin=5mm, legend=false; show_label=true)
                    for (peak_name, p) in zip(keys(report_fit), peak_fit_plot)
                        xticks!(p, convert(Int, round(xlims(p)[1], digits=0)):8:convert(Int, round(xlims(p)[2], digits=0)))
                        title!(p, "$peak_name ($(th228_names_dict[peak_name])keV)")
                        if i != 1
                            plot!(showlegend=false)
                        end
                    end
                    plot(
                        peak_fit_plot...,
                        framestyle=:box,
                        legend=:outerright,
                        # layout=(3, 3),
                        thickness_scaling=1.5,
                        grid=true, gridalpha=0.2, gridcolor=:black, gridlinewidth=0.5,
                        xguidefont=font(family="monospace",halign=:center, pointsize=18),
                        yguidefont=font(family="monospace",halign=:center, pointsize=18),
                        xtickfontsize=10,
                        ytickfontsize=10,
                        size=(3000, 1500),
                        margins=10mm
                    )
                    savefig(joinpath(figures_folder_string, format("{}-partition{:02d}-{}-{}-peak_fits_{}.png", string(filekey.setup), partition_n, string(filekey.category), ch, string(e_type))))

                    yield()

                    @debug "Get $e_type calibration values"
                    μ = [result_fit[p].μ for p in th228_names]
                    μ_err = [result_fit[p].err.μ for p in th228_names]

                    m_calib, n_calib = nothing, nothing
                    try
                        m_calib, n_calib = fit_calibration(μ, th228_lines)
                        @debug format("Found $e_type calibration curve: E[keV] = {:.2f} + {:.2f}*E[ADC]", n_calib, m_calib)
                    catch e
                        @error "Error in $e_type calibration curve fitting for channel $ch: $e"
                        throw(ErrorException("Error in $e_type calibration curve fitting"))
                    end

                    scatter(μ, th228_lines, yerror=μ_err, ms=5, color=:black, framestyle=:box, markershape= :x, layout = @layout[grid(2, 1, heights=[0.8, 0.2])], link=:x, label="Peak Positions", xlabel="Fit Energy (keV)", xlabelfontsize=10, ylabel="True Energy (keV)", ylabelfontsize=10, legend=:topleft, legendfontsize=8, legendfont=font(8), legendtitlefontsize=8, legendtitlefont=font(8), xlims = (0, 3000), xticks = (200:200:3000), margin=5mm, thickness_scaling=1.5, xformatter=:plain)
                    plot!(ylims = (0, 3000), yticks = (200:200:3000), subplot=1, xlabel="", xticks = :none, bottom_margin=-4mm)
                    plot!(0:1:20000, x -> m_calib* x + n_calib, label="Best Fit: $(round(n_calib, digits=2)) + x*$(round(m_calib, digits=2)))", line_width=2, color=:red, subplot=1, xformatter=_->"")
                    plot!(μ, ((m_calib .* μ .+ n_calib) .- th228_lines) ./ th228_lines .* 100 , label="Residuals", ylabel="Residuals (%)", line_width=2, color=:black, st=:scatter, ylims = (-0.11, 0.1), markershape=:x, subplot=2, legend=:topleft, top_margin=0mm, framestyle=:box)
                    plot!(legend = :topleft, title=format("{} Calibration Curve ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)), subplot=1)
                    savefig(joinpath(figures_folder_string, format("{}-partition{:02d}-{}-{}-calibration_curve_{}.png", string(filekey.setup), partition_n, string(filekey.category), ch, string(e_type))))

                    yield()

                    fwhm     = ([result_fit[p].fwhm for p in th228_names])
                    fwhm_err = ([result_fit[p].err.fwhm for p in th228_names])

                    result_fwhm, report_fwhm = nothing, nothing
                    try
                        result_fwhm, report_fwhm = fit_fwhm(th228_lines, fwhm)
                        @debug "Found $e_type FWHM: $(round(result_fwhm.qbb, digits=2)) +- $(round(result_fwhm.err.qbb, digits=2))keV"
                    catch e
                        @error "Error in $e_type FWHM fitting for channel $ch: $e"
                        throw(ErrorException("Error in $e_type FWHM fitting"))
                    end

                    scatter(th228_lines, fwhm, yerror=fwhm_err, ms=5, color=:black, framestyle=:box, markershape= :x, layout = @layout[grid(2, 1, heights=[0.8, 0.2])], link=:x, label="Peak FWHMs", xlabel="Energy (keV)", xlabelfontsize=10, ylabel="FWHM (keV)", ylabelfontsize=10, legend=:topleft, legendfontsize=8, legendfont=font(8), legendtitlefontsize=8, legendtitlefont=font(8), xlims = (0, 3000), xticks = (convert(Int, 0):300:convert(Int, round(3000, digits=0))), margin=5mm, thickness_scaling=1.5)
                    plot!(0:0.1:3000, x -> report_fwhm.f_fit(x), label="Best Fit: Sqrt($(round(report_fwhm.v[1], digits=2)) + x*$(round(report_fwhm.v[2]*100, digits=2))e-3)", line_width=2, color=:red, subplot=1, xlabel="", xticks=:none, bottom_margin=-4mm, ylims=(0.8, 6.0))
                    hline!([result_fwhm.qbb], label="Qbb/keV: $(round(result_fwhm.qbb, digits=2))+-$(round(result_fwhm.err.qbb, digits=2))", color=:green)
                    hspan!([result_fwhm.qbb - result_fwhm.err.qbb, result_fwhm.qbb + result_fwhm.err.qbb], color=:green, alpha=0.2, label="")
                    plot!(th228_lines, ((report_fwhm.f_fit.(th228_lines) .- fwhm) ./ fwhm) .* 100 , label="Residuals", ylabel="Residuals (%)", line_width=2, color=:black, st=:scatter, ylims = (-10, 12), markershape=:x, legend=:topleft, subplot=2, framestyle=:box, top_margin=0mm)
                    plot!(legend = :topleft, title=format("{} FWHM ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)), subplot=1)
                    savefig(joinpath(figures_folder_string, format("{}-partition{:02d}-{}-{}-fwhm_{}.png", string(filekey.setup), partition_n, string(filekey.category), ch, string(e_type))))
                    
                    yield()

                    log_info = "| $ch | $det | Success | $e_type | $(round(result_fwhm.qbb, digits=2))±$(round(result_fwhm.err.qbb, digits=2)) | $(round(result_fit[:Tl208FEP].fwhm, digits=2))±$(round(result_fit[:Tl208FEP].err.fwhm, digits=2)) | $(round(m_calib, digits=2)) | - |"

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

                    GC.gc()
                catch e
                    @error "Error in $e_type CT correction: $e"
                    log_info = "| ch$(chinfo.channel[i]) | $(chinfo.detector[i]) | Failed | $e_type | - | - | - | $(e) |"
                    # add results to dict
                    result_dict[e_type] = NamedTuple()
                    log_info_dict[e_type] = log_info
                end
            end
        end


        return (result = result_dict, log = log_info_dict)

    end


    Base.exit_on_sigint(false)
    result_energy =  @showprogress pmap(eachindex(chinfo.channel); batch_size = 1, retry_check=retry_check, retry_delays=ExponentialBackOff(n=3)) do idx
        try
            t_end = time() + timeout
            task = Threads.@spawn ch_energy_calibration(idx)
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
            log_info = "| ch$(chinfo.channel[idx]) | $(chinfo.detector[idx]) | Failed | ? | - | - | - | $(e) |"
            chinfo.detector[idx] => (result = Dict{Symbol, NamedTuple}(), log = log_info)
        end
    end

    @info "Finished Energy calibration"
    @info "Remove all workers"
    rmprocs(workers()...)

    main_log = """
    # Main log 
    Time of processing: $(now())
    ## Energy Calibration
    This is the log for the energy calibration. The algorithm loads all data for a channel and performs a energy calibration while fitting peaks identified in the spectrum and returning 
    calibration constant and resolution.

    # MetaData
    | Setup | Partition | Category |
    |-------|-----------|----------|
    | $(filekey.setup) | $(partition_n) | $(filekey.category) |

    # Results
    | Channel | Detector | Status | Energy | FWHM Qbb (keV) | FWHM FEP (keV) | Cal.Constant | Error |
    |---------|----------|--------|--------|----------------|----------------|--------------|-------|
    """
    # extract results into pars_db and append to main log
    for (det, res) in result_energy
        # save pars to db
        if !isempty(res.result)
            pars_det = pars_db[det]
            for (e_type, res_e_type) in res.result
                if isempty(res_e_type)
                    continue
                end
                pars_det_e_type = pars_det[e_type].energy
                # save calibration results
                pars_det_e_type.m_calib      = res_e_type.m_calib
                pars_det_e_type.n_calib      = res_e_type.n_calib
                pars_det_e_type.m_cal_simple = res_e_type.m_cal_simple
                # save peak fit results
                result_fit = res_e_type.fit
                for (peak, peak_result) in result_fit
                    pars_det_peak = pars_det_e_type[peak]
                    for param in keys(peak_result)
                        if param == :err
                            for param_err in keys(peak_result[:err])
                                pars_det_peak[:err][param_err] = peak_result[:err][param_err]
                            end
                            continue
                        end
                        pars_det_peak[param] = peak_result[param]
                    end
                end
                # save fwhm results
                result_fwhm                  = res_e_type.fwhm
                pars_det_e_type.fwhm_qbb     = result_fwhm.qbb
                pars_det_e_type.fwhm_qbb_err = result_fwhm.err.qbb
                pars_det_e_type.fwhm_pars    = result_fwhm.v
            end
            for (e_type, log_info) in res.log
                # add log to main log
                main_log = """
                $main_log$(log_info)
                """
            end
        else
            # add log to main log
            main_log = """
            $main_log$(res.log)
            """
            # main_log *= res.log
        end
    end

    # save pars to disk
    @info "Save pars to disk"
    # write pars
    writeprops(joinpath(l200.tier[:par, :cal], "p_energy", format("partition{:02d}.json", partition_n)), pars_db, multiline=true)

    # write validity
    pars_validTimeStamp = string(filekey.time)
    add_validity = true
    for ln in eachline(open(joinpath(l200.tier[:par, :cal], "p_energy", "validity.jsonl"), "r"))
        if (contains(ln, "$pars_validTimeStamp"))
            add_validity = false
        end
    end
    if add_validity
        open(joinpath(l200.tier[:par, :cal], "p_energy", "validity.jsonl"), "a") do io
            pars_filename = format("partition{:02d}.json", partition_n)
            println(io, "{\"valid_from\":\"$pars_validTimeStamp\", \"category\":\"all\", \"apply\":[\"$pars_filename\"]}")
        end
    end

    @info "Write main log to disk"
    @info main_log

    log_filename = joinpath(log_folder, format("{}-partition{:02d}-{}-energy.md", string(filekey.setup), partition_n, string(filekey.category)))
    open(log_filename, "w+") do file
        write(file, replace(main_log, "Success" => raw"$${\color{green}Success}$$", "Failed" => raw"$${\color{red}Failed}$$"))
    end

end

