# PMT single-PE (LED diffuser-ball / MVC) calibration.
#
# A run can have MORE THAN ONE MVC file (e.g. a second LED run taken right after a
# PMT high-voltage change). Each file is calibrated separately:
#   * the first (earliest) file  -> pars key  "rNNN"
#   * every later file           -> "rNNN_after_voltage_change[_k]"
# and each gets its own `validity.yaml` entry keyed on that file's timestamp, so the
# temporally latest MVC calibration is the one applied to the following physics runs.
#
# 1 p.e. fit: LegendSpecFits.pmts_calibration (port of mvcal.py `fit_spe`/`classify`).
# PMTs with status bad_fit / fit_failed keep the calibration of the latest EARLIER run
# (as mvcal.py `write_overrides`); `fit.cal_source` says where it came from. So runs
# have to be (re)processed in chronological order.

# validity.yaml writer that tolerates pre-existing mode-less entries and replaces any
# entry with the same timestamp or the same target file.
function _pmtcal_writevalidity(props_db, filekey::FileKey, apply::String;
                               category::AbstractString = "all", mode::AbstractString = "reset")
    YAML = LegendDataManagement.YAML
    dst  = joinpath(data_path(props_db), "validity.yaml")
    mkpath(dirname(dst))
    loaded  = isfile(dst) ? YAML.load_file(dst) : nothing
    entries = Vector{Any}(loaded isa AbstractVector ? loaded : Any[])
    ts = string(filekey.time)
    filter!(entries) do e
        e isa AbstractDict || return false
        ap = get(e, "apply", String[])
        ap = ap isa AbstractVector ? ap : [ap]
        get(e, "valid_from", "") != ts && !(apply in ap)
    end
    push!(entries, Dict("valid_from" => ts, "apply" => [apply],
                        "category" => category, "mode" => mode))
    sort!(entries; by = e -> get(e, "valid_from", ""))
    open(dst, "w") do io
        YAML.write(io, entries)
    end
    @info "validity: valid_from $ts  ->  $apply  (mode $mode)"
    return nothing
end

# Latest non-NaN calibration per PMT from pars files valid BEFORE `before` (a filekey time
# string, e.g. the run's first MVC file): Dict(det => (cal func, source "pXX/rYYY[...]")).
# A value that was itself inherited keeps its original source.
function _pmtcal_previous_cal(props_db, before::AbstractString, e_type::Symbol)
    YAML  = LegendDataManagement.YAML
    base  = data_path(props_db)
    vfile = joinpath(base, "validity.yaml")
    prev  = Dict{Symbol, Tuple{String, String}}()
    isfile(vfile) || return prev
    loaded  = YAML.load_file(vfile)
    entries = [e for e in (loaded isa AbstractVector ? loaded : []) if e isa AbstractDict && haskey(e, "valid_from")]
    sort!(entries; by = e -> string(e["valid_from"]), rev = true)   # yyyymmddTHHMMSSZ sorts chronologically
    for e in entries
        string(e["valid_from"]) < before || continue
        ap = get(e, "apply", String[])
        for f in (ap isa AbstractVector ? ap : [ap])
            path = joinpath(base, f)
            isfile(path) || continue
            pars = YAML.load_file(path)
            pars isa AbstractDict || continue
            for (det, d) in pars
                k = Symbol(det)
                haskey(prev, k) && continue
                func = try string(d[string(e_type)]["cal"]["func"]) catch; continue end
                occursin("NaN", func) && continue
                src = try string(d[string(e_type)]["fit"]["cal_source"]) catch; "fit" end
                prev[k] = (func, src == "fit" ? splitext(f)[1] : src)
            end
        end
    end
    return prev
end

# Only the p03 channelmap carries the PMT location and `daq.fc_channel`; PMTs and the
# muon-veto FlashCam wiring do not change (checked on 2026-10-20 data: exactly the PMTs
# that are "on" in the statuses show LED light).
function _pmt_p03_channelmap(l200::LegendData)
    try
        l200.metadata.hardware.configuration.channelmaps(start_filekey(l200, (DataPeriod(3), DataRun(0), :cal)))
    catch e
        @warn "p03 channelmap not available: $(truncate_error(e))"
        PropDict()
    end
end

# PMT location (Floor / Pillbox / Wall)
_pmt_places(l200::LegendData, dets) = let cm = _pmt_p03_channelmap(l200)
    Dict(Symbol(d) => titlecase(string(get(get(cm, Symbol(d), PropDict()), :location, "?"))) for d in dets)
end

# FCEvent channel of each PMT: channelmap fc_channel j <-> FCEvent channel j + 1
# (FC 0 = pulser/aux, FC 1..53 = PMTs, FC 54 unused; see convert_mvc_to_pmt_ids.jl)
_pmt_fcevent_channels(l200::LegendData, dets) = let cm = _pmt_p03_channelmap(l200)
    Dict(Symbol(d) => Int(cm[Symbol(d)].daq.fc_channel) + 1 for d in dets
         if haskey(cm, Symbol(d)) && haskey(cm[Symbol(d)], :daq) && haskey(cm[Symbol(d)].daq, :fc_channel))
end

# Number of FlashCam channels (traces per event) of the muon-veto crate
const _MVC_N_FC_CHANNELS = 55


function process_pmts_calibration_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool=false, timeout::Int=0)

    @info "Process PMT calibration for period $period and run $run"

    # MVC (LED) runs are taken shortly BEFORE the physics run, so their timestamps
    # predate the run's first metadata validity date. Use the run's `cal` filekey for
    # all metadata/config lookups; the LED data itself is read per MVC filekey.
    filekey = start_filekey(l200, (period, run, :cal))

    data_filekeys = sort(collect(search_disk(FileKey,
        l200.tier[DataTier(:raw), DataCategory(:mvc), period, run])); by = fk -> fk.time)
    isempty(data_filekeys) && error("No MVC (LED) raw files found for $period/$run")
    @info "Metadata filekey $filekey — $(length(data_filekeys)) MVC file(s): $(join(string.(data_filekeys), ", "))"

    # only PMTs that are switched on in the metadata statuses (dead PMTs are usability
    # "off" / processable false from the run they died in, legend-datasets#190)
    chinfo_all = channelinfo(l200, filekey; system=:pmts)
    chinfo = chinfo_all[findall(c -> c.processable && c.usability == :on, chinfo_all)]
    @info "Loaded channel info: $(length(chinfo)) of $(length(chinfo_all)) PMTs are on and processable"

    calibration_config = dataprod_config(l200).pmt(filekey).calibration
    dsp_config         = dataprod_config(l200).pmt(filekey).default

    mkpath(joinpath(data_path(l200.par.rpars.pmtcal), string(period)))
    pmtcal_period_dir = data_path(l200.par.rpars.pmtcal[period])

    # PMT energy type: pulse_height (wSG-filtered) — matches the evt-tier muon_cut, which
    # runs on pulse_height_cal (config/evt/p0%_r0%%_evt_phy.yaml). Calibrating on
    # raw_pulse_height instead gives a pulse_height_cal off by the wSG/raw ratio (~0.53x),
    # silently breaking pe_sum_threshold downstream. SPP peak sits at ~16 LSB here
    # (vs. ~30 LSB unfiltered) — matches Maya's thesis convention.
    e_type = :pulse_height

    places      = _pmt_places(l200, [c.detector for c in chinfo])
    fc_channels = _pmt_fcevent_channels(l200, [c.detector for c in chinfo])
    n_fc        = _MVC_N_FC_CHANNELS

    # fallback calibration for bad fits: latest pars from runs BEFORE this one (never the
    # 'before HV change' file of the same run -- other voltages)
    prev_cal = _pmtcal_previous_cal(l200.par.rpars.pmtcal, string(first(data_filekeys).time), e_type)
    @info "Fallback calibrations from earlier runs available for $(length(prev_cal)) PMTs"

    log_nt = NamedTuple{(:Detector, :Channel, :Status, Symbol("µ1 (LSB)"), Symbol("χ²/ndf"), Symbol("Cal. Func."), :FitStatus, :Error)}
    wpool  = get_workerPool(processing_config, nameof(var"#self#"))
    flush(stdout)

    for (i, dfk) in enumerate(data_filekeys)
        outkey = i == 1 ? string(run) :
                 i == 2 ? "$(run)_after_voltage_change" :
                          "$(run)_after_voltage_change_$(i-1)"
        @info "── MVC file $i/$(length(data_filekeys)): $dfk  →  pars '$outkey'"

        # Two raw layouts: per-PMT groups `PMTxyz/raw` (split by convert_mvc_to_pmt_ids.jl),
        # or the unsplit DAQ table `FCEvent` (all 55 channels) -> rows picked per PMT below
        rawfile    = string(l200.tier[DataTier(:raw), dfk])
        is_fcevent = h5open(f -> haskey(f, "FCEvent"), rawfile, "r")
        is_fcevent && @info "Raw file has an unsplit FCEvent table -- PMT rows selected by FlashCam channel"

        parsfile = joinpath(pmtcal_period_dir, "$(outkey).yaml")
        pars_db  = (!reprocess && isfile(parsfile)) ? PropDict(readlprops(parsfile)) : PropDict()
        if reprocess @info "Reprocess all detectors" end

        function det_pmt_calibration(chinfo_det::NamedTuple)

            ch  = chinfo_det.channel
            det = chinfo_det.detector
            @debug "Processing detector $det ($ch)"

            emptypanel = (det = Symbol(det), place = get(places, Symbol(det), "?"), edges = Float64[], counts = Float64[],
                          popt = Float64[], x_min = NaN, mu1 = NaN, mu1_err = NaN, sig1 = NaN, chi2ndf = NaN,
                          status = :error, error = "")

            # skip if already processed
            if !reprocess && haskey(pars_db, det)
                existing = pars_db[det]
                log_info = log_nt((det, ch, ProcessStatus(1),
                    get(get(existing, e_type, PropDict()), :fit, PropDict()) |> x -> get(x, :μ, "-"),
                    get(get(existing, e_type, PropDict()), :fit, PropDict()) |> x -> get(x, :chi2ndf, "-"),
                    get(get(existing, e_type, PropDict()), :cal, PropDict()) |> x -> get(x, :func, "-"),
                    get(get(existing, e_type, PropDict()), :fit, PropDict()) |> x -> get(x, :status, "-"),
                    "Already processed --> skipped."))
                return (result = Dict{Symbol,NamedTuple}(), log = Dict(e_type => log_info), processed = Dict(e_type => false), plotdata = emptypanel)
            end

            # load THIS MVC file's raw data and run DSP inline
            data_dsp = try
                data_raw = if is_fcevent
                    fc = fc_channels[Symbol(det)]
                    lh = lh5open(rawfile, "r")
                    try
                        tbl  = lh["FCEvent"]
                        chan = tbl.channel[:]
                        rows = (fc + 1):n_fc:length(chan)          # regular 55-channel layout
                        if isempty(rows) || !all(==(fc), view(chan, rows))
                            rows = findall(==(fc), chan)
                        end
                        Table(waveform = tbl.waveform[rows], timestamp = tbl.timestamp[rows],
                              channel = tbl.channel[rows], eventnumber = tbl.eventnumber[rows],
                              daqenergy = tbl.daqenergy[rows])
                    finally
                        close(lh)
                    end
                else
                    read_ldata(identity, l200, DataTier(:raw), dfk, det)
                end
                dsp_pmts(data_raw, dsp_config)
            catch e
                @error "Error loading/DSP data for detector $det ($ch): $(truncate_error(e))"
                log_info = log_nt((det, ch, ProcessStatus(0), "-", "-", "-", false, string(e)))
                return (result = Dict{Symbol,NamedTuple}(), log = Dict(e_type => log_info), processed = Dict(e_type => false), plotdata = emptypanel)
            end

            # QC cut
            calibration_config_det = merge(calibration_config.default, get(calibration_config, det, PropDict()))
            data_after_qc = try
                data_dsp[findall(ljl_propfunc(calibration_config_det.qc).(data_dsp))]
            catch e
                @error "Error in QC for detector $det ($ch): $(truncate_error(e))"
                log_info = log_nt((det, ch, ProcessStatus(0), "-", "-", "-", false, string(e)))
                return (result = Dict{Symbol,NamedTuple}(), log = Dict(e_type => log_info), processed = Dict(e_type => false), plotdata = emptypanel)
            end

            result_dict    = Dict{Symbol, NamedTuple}()
            log_info_dict  = Dict{Symbol, NamedTuple}()
            processed_dict = Dict{Symbol, Bool}()
            plotdata       = emptypanel

            try
                e_uncal = filter(isfinite, collect(getproperty(data_after_qc, e_type)))

                # 1 p.e. fit: exponential + 1 p.e. + 2 p.e. above the pedestal (mvcal.py)
                result_cal, report_cal = pmts_calibration(e_uncal; NamedTuple(calibration_config_det.kwargs)...)
                GC.gc()

                # bad fit -> calibration of the latest earlier run (NaN if there is none)
                cal_func, cal_source = if result_cal.status == :ok
                    result_cal.cal_func, "fit"
                elseif haskey(prev_cal, Symbol(det))
                    prev_cal[Symbol(det)]
                else
                    result_cal.cal_func, "none"
                end
                result_cal.status != :ok &&
                    @warn "$det: $(result_cal.status) -- calibration from: $cal_source ($cal_func)"

                μ1, μ1_err = Measurements.value(result_cal.μ), Measurements.uncertainty(result_cal.μ)
                result_dict[e_type] = (
                    cal = (func = cal_func,),
                    fit = (
                        μ          = μ1,
                        μ_err      = μ1_err,
                        σ          = result_cal.σ,
                        chi2ndf    = result_cal.chi2ndf,
                        n_spe      = result_cal.n_spe,
                        x_min      = result_cal.x_min,
                        status     = string(result_cal.status),
                        fit_failed = result_cal.fit_failed,
                        cal_source = cal_source,
                    ),
                )

                plotdata = merge(emptypanel, (
                    edges   = report_cal.edges,
                    counts  = report_cal.counts,
                    popt    = report_cal.popt,
                    x_min   = report_cal.x_min,
                    mu1     = μ1,
                    mu1_err = μ1_err,
                    sig1    = result_cal.σ,
                    chi2ndf = result_cal.chi2ndf,
                    status  = result_cal.status,
                    error   = result_cal.error))

                log_info_dict[e_type] = log_nt((det, ch, ProcessStatus(1),
                    μ1, result_cal.chi2ndf, cal_func, string(result_cal.status),
                    isempty(result_cal.error) ? "-" : result_cal.error))
                processed_dict[e_type] = true

            catch e
                @error "Error processing detector $det ($ch): $(truncate_error(e))"
                log_info_dict[e_type]  = log_nt((det, ch, ProcessStatus(0), "-", "-", "-", false, string(e)))
                processed_dict[e_type] = false
            end

            return (result = result_dict, log = log_info_dict, processed = processed_dict, plotdata = plotdata)
        end

        result_pmt_calibration = parallel(chinfo, det_pmt_calibration, log_nt, wpool;
            timeout=timeout, retry=false,
            process_name="$period-$run-$(outkey)-$(nameof(var"#self#"))")

        pars_db = create_pars(pars_db, result_pmt_calibration)
        writelprops(l200.par.rpars.pmtcal[period], Symbol(outkey), pars_db)
        _pmtcal_writevalidity(l200.par.rpars.pmtcal, dfk, "$(period)/$(outkey).yaml")
        @info "Saved pars '$outkey' to disk"

        # combined SPP overview plot for this MVC file
        try
            # only PMTs processed in this call: skipped ("already processed") and
            # unreadable PMTs come back without a histogram
            panels = [r.plotdata for (_, r) in result_pmt_calibration
                      if haskey(r, :plotdata) && !isempty(r.plotdata.counts)]
            if isempty(panels)
                @info "No PMT processed for '$outkey' -- overview plot not (re)written"
                continue
            end
            suffix = outkey == string(run) ? "" : replace(outkey, string(run) => "")
            pltdir = joinpath(string(l200.tier[DataTier(:jlplt)]), "rplt", "cal",
                              string(period), string(run), "pmt_overview")
            title  = "l200-$(period)-$(run)$(suffix) ($(dfk.time))"
            pmt_spe_grid(title, panels;
                outfile = joinpath(pltdir, "l200-$(period)-$(run)-cal-pmt_spe_grid$(suffix).png"))
            # after a HV change: the µ1 of the previous MVC file of this run as open circles
            before = nothing
            if i > 1
                prevkey  = i == 2 ? string(run) : "$(run)_after_voltage_change" * (i == 3 ? "" : "_$(i-2)")
                prevfile = joinpath(pmtcal_period_dir, "$(prevkey).yaml")
                if isfile(prevfile)
                    pp = readlprops(prevfile)
                    before = Dict(Symbol(d) => Float64(get(get(get(pp, Symbol(d), PropDict()), e_type, PropDict()), :fit, PropDict()) |>
                                                       x -> get(x, :μ, NaN)) for d in keys(pp))
                end
            end
            pmt_spe_mu1_overview(title, panels; before = before,
                outfile = joinpath(pltdir, "l200-$(period)-$(run)-cal-pmt_spe_mu1$(suffix).png"))
        catch e
            @error "Overview plot for '$outkey' failed: $(truncate_error(e))"
        end
        flush(stdout)
    end

    @info "Finished PMT calibration for $period/$run ($(length(data_filekeys)) MVC file(s))"
    flush(stdout)
end
