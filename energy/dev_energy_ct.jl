# using LegendDataManagement, PropertyFunctions, TypedTables, PropDicts
# using Unitful, Formatting, LaTeXStrings, Measures
# using Plots, StatsBase
# using LegendHDF5IO, LegendDSP, LegendSpecFits
# using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked

# ENV["JULIA_DEBUG"] = Main # enable debug

# gr()
# plotlyjs(size=(800, 500))
# # plotlyjs(size=(1200, 800))

# @info "Loading Legend MetaData"
# l200 = LegendData(:l200)

# period = DataPeriod(3)
# run    = DataRun(1)
# reprocess = true


function process_ct_correction(l200::LegendData, period::DataPeriod, run::DataRun,; reprocess::Bool=false, timeout::Int=300)

    @info "CT correction for period $period and run $run"

    filekeys = sort(search_disk(FileKey, l200.tier[:raw, :cal, period, run]), by = x-> x.time)
    filekey = filekeys[1]
    @info "Found filekey $filekey"

    chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable && $usability)

    sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)

    @debug "Create Hit folder"
    hit_folder = l200.tier[:hit, :cal, period, run]
    ifelse(isdir(hit_folder), @debug("Hit folder $hit_folder already exists"), mkpath(hit_folder))

    @debug "Create figures folder"
    figures_folder = joinpath(l200.tier[:plt, :cal, period, run], "energy")
    ifelse(isdir(figures_folder), @debug("Figure folder $figures_folder already exists"), mkpath(figures_folder))

    for str in unique(chinfo.string)
        figures_folder_string = joinpath(figures_folder, format("string{:02d}", str))
        ifelse(isdir(figures_folder_string), @debug("String Figure folder $figures_folder_string already exists"), mkpath(figures_folder_string))
    end

    @debug "Create logs folder"
    log_folder = joinpath(l200.tier[:log, :cal, period, run])
    ifelse(isdir(log_folder), @debug("Log folder $log_folder already exists"), mkpath(log_folder))


    @debug "Create pars db"
    pars_db = PropDict()
    # read params if exist
    if !(haskey(l200.par[:cal, :energy], Symbol(period)))
        # path folder for current period seems not to exist, will create it first to avoid errors
        mkpath(joinpath(l200.tier[:par, :cal], "energy", "$period"))
        # write validity
        pars_validTimeStamp = string(filekey.time)
        open(joinpath(l200.tier[:par, :cal], "energy", "validity.jsonl"), "a") do io
            println(io, "{\"valid_from\":\"$pars_validTimeStamp\", \"category\":\"all\", \"apply\":[\"$period/$run.json\"]}")
        end
    elseif haskey(l200.par[:cal, :energy, period], Symbol(run))
        @info "Pars file already exists."
        pars_db = l200.par[:cal, :energy, period, run]
    else
        # write validity
        pars_validTimeStamp = string(filekey.time)
        open(joinpath(l200.tier[:par, :cal], "energy", "validity.jsonl"), "a") do io
            println(io, "{\"valid_from\":\"$pars_validTimeStamp\", \"category\":\"all\", \"apply\":[\"$period/$run.json\"]}")
        end
    end

    if reprocess
        @info "Reprocess all channels"
        for det in keys(pars_db)
            pars_db[det].ctc = nothing
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
        reprocess = $reprocess
    end

    # for (i, ch_short) in enumerate(chinfo.channel)
    @everywhere function ch_ct_correction(i::Int64)

        ch_short = chinfo.channel[i]
        ch = format("ch{}", ch_short)
        string_number = chinfo.string[i]
        det = chinfo.detector[i]

        if !reprocess && haskey(pars_db, det) && haskey(pars_db[det], :ctc)
            @debug "Channel $(chinfo.detector[i]) already processed, skip"
            log_info = "| $ch | $det | Success | $(round(pars_db[det].fwhm_qbb, digits=2))±$(round(pars_db[det].fwhm_qbb_err, digits=2)) | $(round(pars_db[det][:Tl208FEP].fwhm, digits=2))±$(round(pars_db[det][:Tl208FEP].err.fwhm, digits=2)) | $(round(pars_db[det].m_calib, digits=2)) | Already processed --> skipped. |"
            return (result = (fct = NaN, ), log = log_info)
        end

        figures_folder_string = joinpath(figures_folder, format("string{:02d}", string_number))

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
            @error "No valid filekeys found for channel $ch ($det), skip"
            throw(LoadError("$det", 154,"No filekeys found for channel $ch ($det)"))
        end
        yield()

        data_ch = fast_flatten([
            LHDataStore(
                ds -> begin
                    # @debug "Reading from \"$(ds.data_store.filename)\""
                    ds[ch][:]
                end,
                l200.tier[:dsp, fk]
            ) for fk in ch_filekeys
        ])
        yield()

        if length(data_ch) < 50000
            @error "Not enough data points for channel $ch ($det), skip"
            throw(ErrorException("Not enough data points for channel $ch ($det)"))
        end

        if haskey(l200.metadata.dataprod.config.cal.energy(sel), det)
            energy_config = l200.metadata.dataprod.config.cal.energy(sel)[det]
            @debug "Use config for detector $det"
        else
            energy_config = l200.metadata.dataprod.config.cal.energy(sel).default
            @debug "Use default config"
        end

        if haskey(l200.metadata.dataprod.config.cal.qc(sel), det)
            qc_config = l200.metadata.dataprod.config.cal.qc(sel)[det]
            @debug "Use config for detector $det"
        else
            qc_config = l200.metadata.dataprod.config.cal.qc(sel).default
            @debug "Use default config"
        end
        yield()

        th228_lines = Vector{Float64}(energy_config.th228_lines)
        th228_names = Symbol.(energy_config.th228_names)
        th228_names_dict  = Dict{Float64, Symbol}(th228_lines .=> Symbol.(energy_config.th228_names))
        window_sizes = Vector{Tuple{Float64, Float64}}([(l,r) for (l,r) in zip(Vector{Float64}(energy_config.left_window_sizes), Vector{Float64}(energy_config.right_window_sizes))])
        n_bins = energy_config.n_bins
        quantile_perc = Float64(NaN)
        if haskey(energy_config, :quantile_perc)
            quantile_perc = energy_config.quantile_perc
        end
        # get special config for CTC
        ctc_cal_peak = Float64(energy_config.ctc.peak)
        ctc_cal_window = (Float64(energy_config.ctc.left_window_size),Float64(energy_config.ctc.right_window_size))

        # generate qc cuts
        qc, data_ch_after_qc = nothing, nothing
        try
            @debug "Get QC cuts"
            qc = qc_cal_energy(data_ch, qc_config)
            @debug "Total surrival fraction: $(round(count(qc) / length(data_ch) * 100, digits=2))%"
            data_ch_after_qc =  data_ch[qc]
        catch e
            @error "Error in QC for channel $ch: $e"
            throw(ErrorException("Error in QC cut generation: $e"))
        end
        yield()

        result_simple, report_simple = nothing, nothing
        try
            @debug "Get simple calibration"
            result_simple, report_simple = simple_calibration(data_ch_after_qc.e_trap, th228_lines, window_sizes,; n_bins=n_bins, quantile_perc=quantile_perc)
        catch e
            @error "Error in simple calibration for channel $ch: $e"
            throw(ErrorException("Error in simple calibration"))
        end

        # get simple calibration constant
        m_cal_simple = result_simple.c
        # save plots for simple calibration for control
        plot(report_simple, margin=5mm, yformatter=:plain, thickness_scaling=1.5, cal=true, title=format("{} Simple Calibration ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
        savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-simple_calibration.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

        yield()

        result_ctc, report_ctc = nothing, nothing
        try
            @debug "Get Charge Trapping Alpha"
            result_ctc, report_ctc = ctc_energy(data_ch_after_qc.e_trap .* m_cal_simple, data_ch_after_qc.qdrift, ctc_cal_peak, ctc_cal_window)
        catch e
            @error "Error in alpha generation $ch: $e"
            throw(ErrorException("Error in alpha generation"))
        end
        @debug "Found Best FWHM: $(round(result_ctc.fwhm_after, digits=2)) +- $(round(result_ctc.err.fwhm_after, digits=2))keV"
        @debug "Found FCT: $(round(result_ctc.fct*1e6, digits=2))E-6"
        
        plot(report_ctc, plot_title=format("{} {}keV Charge Trapping Correction ({}-{}-{}-{})", string(det), string(ctc_cal_peak), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
        savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-ctc.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

        yield()

        result = (
            fct = result_ctc.fct,
            fwhm_before = result_ctc.fwhm_before,
            fwhm_after = result_ctc.fwhm_after,
            peak = ctc_cal_peak,
            err = (fwhm_before = result_ctc.err.fwhm_before, fwhm_after = result_ctc.err.fwhm_after)
        )
        log_info = "| $ch | $det | Success | $(round(ustrip(result.fct*1e6), digits=2))E-6 | $(round(ustrip(result.fwhm_before), digits=2))±$(round(ustrip(result.err.fwhm_before), digits=2)) | $(round(ustrip(result.fwhm_after), digits=2))±$(round(ustrip(result.err.fwhm_after), digits=2)) | - |"

        return (result = result, log = log_info)
    end

    result_ctc = pmap(eachindex(chinfo.channel); on_error = e->(isa(e, ProcessExitedException) ? NaN : rethrow())) do idx
        try
            t_end = time() + timeout
            c = Channel(0)
            task = Threads.@spawn ch_ct_correction(idx)
            bind(c, task)
            # result = nothing
            while !istaskdone(task) && time() <= t_end
                sleep(0.1)
            end
            if !istaskdone(task)
                # schedule(task, InterruptException(), error=true)
                @debug "Timeout for $(chinfo.detector[idx])"
                throw(ErrorException("Timeout for $(chinfo.detector[idx])"))
            end
            chinfo.detector[idx] => fetch(task)
        catch e
            @debug "Write Error log for $(chinfo.detector[idx]): $(e)"
            log_info = "| ch$(chinfo.channel[idx]) | $(chinfo.detector[idx]) | Failed | - | - | - | $(e) |"
            chinfo.detector[idx] => (result = (fct = NaN, ), log = log_info)
        end
    end

    @info "Finished CT correction"
    @info "Remove all workers"
    rmprocs(workers()...)

    main_log = """# Main log
    Time of processing: $(now())
    ## CT Correction
    This is the log for the charge trapping correction. The algorithm loads all data for a channel and performs the correction while optimizing maximum height and FWHM of a defined peak in the energy spectrum.
    Before the parameters are extracted, QC cuts are applied to increase the quality of the data.
    # MetaData
    | Setup | Period | Run | Category |
    |-------|--------|-----|----------|
    | $(filekey.setup) | $(filekey.period) | $(filekey.run) | $(filekey.category) |

    # Results
    | Channel | Detector | Status | FCT | FWHM Before (keV) | FWHM After (keV) | Error |
    |---------|----------|--------|-----|-------------------|------------------|-------|
    """
    # extract results into pars_db and append to main log
    for (det, res) in result_ctc
        # save pars to db
        if !isnan(res.result.fct)
            pars_det = pars_db[det].ctc
            # save calibration results
            pars_det.fct = res.result.fct
            pars_det.fwhm_before = res.result.fwhm_before
            pars_det.fwhm_after = res.result.fwhm_after
            pars_det.peak = res.result.peak
            pars_det.err.fwhm_before = res.result.err.fwhm_before
            pars_det.err.fwhm_after = res.result.err.fwhm_after
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
    writeprops(joinpath(l200.tier[:par, :cal], "energy", "$period/$run.json"), pars_db, multiline=true)

    @info "Write main log to disk"
    @info main_log

    log_filename = joinpath(log_folder, format("{}-{}-{}-{}-ct_correction.md", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
    open(log_filename, "w+") do file
        write(file, replace(main_log, "Success" => raw"$${\color{green}Success}$$", "Failed" => raw"$${\color{red}Failed}$$"))
    end
end