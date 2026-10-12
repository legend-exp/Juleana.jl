"""
    p_process_qc_ml_sampling(processing_config, l200, period; category=:cal, reprocess=false, only_first_period=true)

Draw the QC machine-learning training sample of `period` and `category`,
cluster it with affinity propagation and write the unlabeled parameter entry
`rpars/ml/<qc_pars_entry_name(fk)>` with its validity, where `fk` is the start
key of the first analysis run. The sample itself goes to the `jlqml` tier.

An existing entry is kept unless `reprocess`; with `reprocess`, an entry that
carries exemplar labels other than `UNLABELED` is never overwritten and the
processor throws. The sample is drawn once per period, so `only_first_period`
has no effect.
"""
function p_process_qc_ml_sampling(processing_config::PropDict, l200::LegendData, period::DataPeriod,;
        category::DataCategoryLike=:cal, reprocess::Bool=false, only_first_period::Bool=true)
    category = DataCategory(category)
    report_name = category == DataCategory(:cal) ? :qc_ml_sampling : Symbol("qc_ml_sampling_$category")
    @info "Draw the QC ML training sample of $period $category"

    fk = training_filekey(l200, period, category)
    @info "Found training filekey $fk"

    cfg = qc_ml_config(l200, fk)
    @info "Loaded QC ML config: $(length(cfg.detectors)) detectors, n_max = $(cfg.n_max)"

    # The entry goes to the primary par directory: `l200.par.rpars.ml` resolves to the metadata
    # override directory as long as the primary one has no `rpars/ml`.
    ml_dir = joinpath(data_path(l200.par), "rpars", "ml")
    entry_name = qc_pars_entry_name(fk)
    entry_path = joinpath(ml_dir, entry_name)
    if isfile(entry_path)
        if !reprocess
            @info "QC ML entry $entry_path exists --> skipped"
            return false
        end
        existing = readlprops(entry_path)
        haskey(existing, :exemplar_labels) && all(==(UNLABELED), existing.exemplar_labels) ||
            throw(ErrorException("QC ML entry $entry_path is labeled or has no exemplar_labels; it is never overwritten, remove it by hand to draw a new sample"))
        @info "Reprocess unlabeled QC ML entry $entry_path"
    end

    start_time = now()
    filekeys = raw_filekeys(l200, period, category)
    @info "Drawing from $(length(filekeys)) raw files of runs $(join(unique(string(k.run) for k in filekeys), ", "))"
    rng = Xoshiro(Int(get(cfg, :seed, 1)))
    sample, cluster, pars, scan = run_qc_sampling(l200, fk, cfg; rng, filekeys)
    sampling_time = canonicalize(now() - start_time)
    @info "Affinity propagation scan: best damp = $(scan.best.damp), preference = $(scan.best.preference)"

    mkpath(dirname(entry_path))
    writelprops(entry_path, pars)
    pars_db = l200.par.rpars.ml
    data_path(pars_db) == ml_dir ||
        throw(ErrorException("l200.par.rpars.ml resolves to $(data_path(pars_db)), not to $ml_dir; no validity written"))
    writevalidity(pars_db, fk, entry_name; category=fk.category)
    @info "Saved QC ML entry $entry_path with validity from $(fk.time)"

    n_clusters = length(cluster.exemplars)
    @info "Sampling and clustering done in $sampling_time: $(length(sample)) rows, $n_clusters clusters (converged: $(cluster.converged), $(cluster.iterations) iterations)"
    @info "Rows per stratum: $(join(("$s = $n" for (s, n) in pairs(pars.sample.n_per_stratum)), ", "))"
    for d in cfg.detectors
        matched = pars.sample.n_matched[Symbol(d)]
        @info "$d: $(pars.sample.n_scan[Symbol(d)]) scan rows, rule matches $(join(("$r = $n" for (r, n) in pairs(matched)), ", "))"
    end

    for fname in plot_qc_ml_sampling(l200, fk, cfg, filekeys, sample, pars)
        @info "Saved plot $fname"
    end

    # create log report
    detector_tbl = StructArray([(; Detector = string(d), Rows = count(==(DetectorId(string(d))), sample.detector),
        var"Scan rows" = pars.sample.n_scan[Symbol(d)], pairs(pars.sample.n_matched[Symbol(d)])...) for d in cfg.detectors])
    report = lreport()
    lreport!(report, "# Main Log")
    lreport!(report, StructArray(var"Processor Status" = [process_succeeded]))
    lreport!(report, "Date of processing: $(now())")
    lreport!(report, "Total Processing time: $(canonicalize(now() - start_time))")
    lreport!(report, qc_ml_sampling_log_text)
    lreport!(report, "# Metadata")
    lreport!(report, create_metadatatbl(fk))
    lreport!(report, "# Results")
    lreport!(report, "Entry `$entry_name`: $(length(sample)) rows from $(length(filekeys)) raw files, $n_clusters clusters (converged: $(cluster.converged)).")
    lreport!(report, StructArray(Stratum = string.(collect(keys(pars.sample.n_per_stratum))), Rows = collect(values(pars.sample.n_per_stratum))))
    lreport!(report, detector_tbl)

    @info "Write log report"
    writelreport(get_preportfilename(l200, fk, report_name), report)
    @info report

    flush(stdout)
    return false
end

"""
    plot_qc_ml_sampling(l200, fk, cfg, filekeys, sample, pars) -> Vector{String}

Save the sample-selection and rule-match figures of the training sample of
`fk` and return their file names.

- Sample selection, per detector: the daqenergy distribution of the candidate
  pool, of the rows the aux-trigger flags excluded and of the selected rows,
  and up to 20 baseline-subtracted waveforms of every stratum present.
- Rule matches, per detector: how many of the scan rows each rule selects,
  against the number of scan rows (dashed).
"""
function plot_qc_ml_sampling(l200::LegendData, fk::FileKey, cfg::PropDict, filekeys::AbstractVector{FileKey}, sample, pars::PropDict)
    blmean = read_sample(qc_sample_filename(l200, fk))[4].blmean
    strata_present = sort(unique(sample.stratum))
    excluded_names = Symbol.(get(cfg.strata, :exclude, String[]))
    n_cols = 4
    n_rows = 1 + cld(length(strata_present), n_cols)
    fig = Makie.Figure(size = (380 * n_cols, 320 * n_rows * length(cfg.detectors)))
    for (k, d) in enumerate(cfg.detectors)
        det = DetectorId(string(d))
        gl = fig[k, 1] = Makie.GridLayout()
        cand = scan_candidates(l200, filekeys, det, get(cfg.strata, :aux_triggers, PropDict()); ts_window = Float64(cfg.strata.ts_window) * u"µs")
        excluded = reduce((a, name) -> a .| getproperty(cand, name), excluded_names; init = falses(length(cand)))
        pool = .!excluded
        in_sample = sample.detector .== det
        sel_e = sample.daqenergy[in_sample]

        e_edges = range(0, max(maximum(cand.daqenergy), maximum(sel_e), 1); length = 101)
        ax = Makie.Axis(gl[1, 1:n_cols]; xlabel = "daqenergy (ADC)", ylabel = "events", yscale = log10,
            title = get_plottitle(fk, det, "QC ML sample: $(count(in_sample)) selected of $(count(pool)) pool rows in $(length(filekeys)) files"))
        Makie.hist!(ax, cand.daqenergy[pool]; bins = e_edges, color = (:gray, 0.6), label = "pool")
        any(excluded) && Makie.hist!(ax, cand.daqenergy[excluded]; bins = e_edges, color = (:seagreen, 0.5),
            label = "excluded ($(join(excluded_names, ", ")))")
        Makie.hist!(ax, sel_e; bins = e_edges, color = (:orangered, 0.8), label = "selected")
        Makie.axislegend(ax; position = :rt)

        for (j, s) in enumerate(strata_present)
            idx = findall(i -> in_sample[i] && sample.stratum[i] == s, eachindex(sample.stratum))
            ax = Makie.Axis(gl[1 + cld(j, n_cols), mod1(j, n_cols)]; xlabel = "time (µs)", ylabel = "ADC − blmean",
                title = "$d $s: $(length(idx)) rows")
            # evenly spaced over the stratum's rows, at most 20
            for i in idx[unique(round.(Int, range(1, length(idx), length = min(20, length(idx)))))]
                wf = sample.waveform[i]
                Makie.lines!(ax, ustrip.(u"µs", wf.time), wf.signal .- blmean[i]; color = (:steelblue, 0.35), linewidth = 1.0)
            end
        end
    end
    fname_selection = LDMUtils.get_pltfilename(l200, fk, :all, :qcml_sample_selection)
    LegendMakie.lsavefig(fig, fname_selection)

    rule_names = [String(r.name) for r in cfg.strata.rules]
    fig = Makie.Figure(size = (900, 380 * length(cfg.detectors)))
    for (k, d) in enumerate(cfg.detectors)
        n_scan = pars.sample.n_scan[Symbol(d)]
        counts = [pars.sample.n_matched[Symbol(d)][Symbol(r)] for r in rule_names]
        ax = Makie.Axis(fig[k, 1]; ylabel = "scan rows matched", yscale = log10, limits = (nothing, (0.5, 2 * n_scan)),
            xticks = (eachindex(rule_names), rule_names), xticklabelrotation = π / 4,
            title = get_plottitle(fk, DetectorId(string(d)), "QC ML rule matches among $n_scan scan rows"))
        # a bar of zero matches is drawn at 0.6 so that it stays visible on the log axis
        Makie.barplot!(ax, eachindex(rule_names), max.(counts, 0.6); color = :steelblue, fillto = 0.5)
        Makie.text!(ax, eachindex(rule_names), max.(counts, 0.6); text = string.(counts), align = (:center, :bottom), fontsize = 11)
        Makie.hlines!(ax, [n_scan]; color = :black, linestyle = :dash)
    end
    fname_rules = LDMUtils.get_pltfilename(l200, fk, :all, :qcml_rule_matches)
    LegendMakie.lsavefig(fig, fname_rules)

    [fname_selection, fname_rules]
end
