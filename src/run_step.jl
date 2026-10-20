# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

# Names of the detectors chosen by `run_step`; `nothing` outside of it. `parallel` sets it
# again on the workers.
const DETECTOR_SELECTION = ScopedValue{Union{Nothing,Set{String}}}(nothing)

# `false` inside `run_step` with `outputs = :temp`: parameters and validity are not written.
# `parallel` sets it again on the workers.
const WRITE_PARS = ScopedValue{Bool}(true)

# Inside `run_step`: collects the reports the processor writes and the results of `parallel`.
const STEP_RECORD = ScopedValue{Any}(nothing)

"""
    detector_selected(det)::Bool

`true` unless [`run_step`](@ref) runs a processor for chosen detectors and `det` is not one
of them. Processors that loop over detectors inside one item, such as the DSP processors,
skip the detectors that are not selected.
"""
detector_selected(det) = (sel = DETECTOR_SELECTION[]; isnothing(sel) || string(det) in sel)

"""
    redo_detector(det)::Bool

`true` if [`run_step`](@ref) runs a processor for chosen detectors and `det` is one of them.
A processor processes such a detector again even if its parameters or output already
exist, as with `reprocess = true` for this detector only.
"""
redo_detector(det) = (sel = DETECTOR_SELECTION[]; !isnothing(sel) && string(det) in sel)

"""
    write_pars(args...)

Write parameters with `writelprops(args...)`, except inside
[`run_step`](@ref) with `outputs = :temp`, where nothing is written.
"""
write_pars(args...) = WRITE_PARS[] ? writelprops(args...) : nothing

"""
    write_validity(args...; kwargs...)

Write a validity entry with `LegendDataManagement.LDMUtils.writevalidity`, except inside
[`run_step`](@ref) with `outputs = :temp`, where nothing is written.
"""
write_validity(args...; kwargs...) = WRITE_PARS[] ? writevalidity(args...; kwargs...) : nothing

"""
    make_par_dir(path) -> path

Create the parameter directory `path` like `mkpath`, except inside [`run_step`](@ref) with
`outputs = :temp`, where nothing is created.
"""
make_par_dir(path) = WRITE_PARS[] ? mkpath(path) : path

"""
    write_report(filename, report)

Write the processor report `report` to `filename` with `writelreport`. Inside
[`run_step`](@ref), `report` also goes into the report of the step.
"""
function write_report(filename, report)
    record = STEP_RECORD[]
    isnothing(record) || push!(record.reports, report)
    writelreport(filename, report)
end

"""
    PROCESSOR_TRAITS::Dict{Symbol,NamedTuple}

Properties of the registered processors that [`run_step`](@ref) needs, set by
[`register_processor!`](@ref): `output_tiers`, the data tiers the processor writes, and
`detector_selection`, whether the processor processes the detectors that
[`redo_detector`](@ref) names again and skips the others.
"""
const PROCESSOR_TRAITS = Dict{Symbol,NamedTuple{(:output_tiers, :detector_selection),Tuple{Vector{Symbol},Bool}}}()

const DEFAULT_TRAITS = (output_tiers = Symbol[], detector_selection = true)

"""
    run_step(step::Symbol, period, run = nothing; detectors = nothing, outputs = :temp,
        output_dir = nothing, config = Juleana.default_config_file(), l200 = nothing,
        show_report::Bool = isinteractive(), processors::AbstractDict{Symbol} = PROCESSORS, kwargs...)

Run the processor `step` for `period` and, for a run-level processor, `run`, in the
calling Julia process, for example in the REPL. Items go to the workers of the
ParallelProcessingTools worker pool, or run in the calling process when no workers are
started.

`detectors` are the detectors to process: they are processed again, also when their
parameters or output exist. With `outputs = :production`, the other detectors are
skipped as already processed, so the parameters, validity and reports of the step stay
complete; with `outputs = :temp`, they are not run. `detectors = nothing` processes all
detectors, with `reprocess = true` unless given.

With `outputs = :temp` (the default), plots, reports and the data tiers the processor
writes (its `output_tiers`, see [`register_processor!`](@ref)) go to `output_dir`, and no
parameters or validity are written; parameters are read from the production. With
`outputs = :production`, everything is written to the production paths of `l200`.

`output_dir` defaults to one temporary directory for all calls of `run_step` in the Julia
session. The report of each call is appended to `<output_dir>/reports/<step>.md`: the
report of the processor, with only the rows of `detectors`, and below it the plots of each
detector the processor saved during this call, in the order they were saved, as images in
the file. With `show_report = true`, the default in an interactive session, the report is
also displayed with [`display_report`](@ref).

`config` is a [`ProcessingConfig`](@ref) or the path of a config file. Its
`env_variables` are set before `l200` is built as `LegendData(:l200)` when `l200` is
`nothing`. The keyword arguments of the processor are those of `config`, then
`only_first_period = false` for a partition-level processor and `reprocess = true` when
`detectors` is `nothing`, then `kwargs`.

Return a [`StepOutput`](@ref).

Throws an `ArgumentError` if `step` is not registered or not in `config`, if `run` is given
for a partition-level processor or missing for a run-level one, if `detectors` is given for
a processor that cannot select detectors, or if `outputs` is not `:temp` or `:production`.

# Examples
```julia
using Juleana
step = run_step(:process_energy_calibration_cal, 3, 0; detectors = [:V01234A])  # a detector of p03 r000
step.report
```
"""
function run_step(step::Symbol, period, run = nothing; detectors = nothing, outputs::Symbol = :temp,
        output_dir = nothing, config = default_config_file(), l200 = nothing,
        show_report::Bool = isinteractive(), processors::AbstractDict{Symbol} = PROCESSORS, kwargs...)
    haskey(processors, step) || throw(ArgumentError("run_step: unregistered processor `$step`"))
    outputs in (:temp, :production) ||
        throw(ArgumentError("run_step: `outputs` is $(repr(outputs)), expected :temp or :production"))
    traits = get(PROCESSOR_TRAITS, step, DEFAULT_TRAITS)
    !isnothing(detectors) && !traits.detector_selection &&
        throw(ArgumentError("run_step: processor `$step` cannot select detectors, run it without `detectors`"))
    cfg = config isa ProcessingConfig ? config : ProcessingConfig(config)
    spec = haskey(cfg.processors, step) ? cfg.processors[step] : get(cfg.p_processors, step, nothing)
    isnothing(spec) && throw(ArgumentError("run_step: processor `$step` is not in the config"))
    spec.level === :run && isnothing(run) && throw(ArgumentError("run_step: the run-level processor `$step` needs a run"))
    spec.level === :partition && !isnothing(run) &&
        throw(ArgumentError("run_step: the partition-level processor `$step` takes no run"))
    if isnothing(l200)
        # the environment variables must be set before the metadata is loaded
        foreach(((key, value),) -> ENV[key] = value, cfg.env_variables)
        l200 = LegendData(:l200)
    end
    dir = mkpath(isnothing(output_dir) ? session_output_dir() : output_dir)
    step_l200 = outputs === :temp ? redirect_outputs(l200, dir, vcat([:jlplt, :jlrep, :jllog], traits.output_tiers)) : l200
    period = DataPeriod(period)
    args = spec.level === :run ? (period, DataRun(run)) : (period,)
    defaults = merge(spec.level === :partition ? (; only_first_period = false) : (;),
        isnothing(detectors) ? (; reprocess = true) : (;))
    selection = isnothing(detectors) ? nothing : Set(string.(detectors))
    record = (reports = Any[], results = Any[])
    started = time()
    with(DETECTOR_SELECTION => selection, WRITE_PARS => outputs === :production, STEP_RECORD => record) do
        processors[step](cfg, step_l200, args...; merge(NamedTuple(spec.kwargs), defaults, NamedTuple(kwargs))...)
    end
    plot_roots = if spec.level === :run
        [joinpath(step_l200.tier[:jlplt], "rplt", string(spec.category), string(period), string(DataRun(run)))]
    else
        pplt = joinpath(step_l200.tier[:jlplt], "pplt")
        isnothing(selection) ? [pplt] : [joinpath(pplt, det) for det in selection]
    end
    report = step_report(step, args, spec.level, outputs, dir, selection, record.reports, plot_roots, started)
    report_file = joinpath(mkpath(joinpath(dir, "reports")), "$step.md")
    open(io -> (show(io, MIME"text/markdown"(), report); println(io)), report_file, "a")
    @info "run_step: report appended to $report_file"
    # outside of the logger, which shows messages as text only
    show_report && display_report(report)
    return StepOutput(step, args, report, report_file, record.reports, dir, record.results)
end

"""
    StepOutput

The output of [`run_step`](@ref), with the fields
- `step`, `args`: the processor and its period and run,
- `report`: the report of the call as a `LegendReport`, with the plots as
  [`ReportPlot`](@ref)s; [`display_report`](@ref) shows it with the plots as images,
- `report_file`: the path of the report file the report was appended to,
- `reports`: the reports the processor wrote, complete with all detectors,
- `output_dir`: the output directory,
- `results`: the `item => result` pairs of all `parallel` calls of the processor.
"""
struct StepOutput
    step::Symbol
    args::Tuple
    report::Any
    report_file::String
    reports::Vector{Any}
    output_dir::String
    results::Vector{Any}
end

Base.show(io::IO, out::StepOutput) = print(io, "StepOutput(", out.step, " ", join(string.(out.args), " "), ": ",
    length(out.results), " results, report in ", out.report_file, ")")

# The temporary output directory of `run_step` in this Julia session, created on first use.
const SESSION_OUTPUT_DIR = Ref("")

function session_output_dir()
    isempty(SESSION_OUTPUT_DIR[]) && (SESSION_OUTPUT_DIR[] = mktempdir(; prefix = "juleana-run_step-", cleanup = false))
    return SESSION_OUTPUT_DIR[]
end

# `l200` with the data tiers `tiers` in the directory `dir`; everything else, also the
# parameters, at the paths of `l200`.
function redirect_outputs(l200::LegendData, dir::AbstractString, tiers)
    setup = getfield(l200, :_config)
    keys_new = [["tier", string(t)] for t in tiers]
    paths = vcat(filter(p -> !(first(p) in keys_new), setup.paths), [k => mkpath(joinpath(dir, last(k))) for k in keys_new])
    return LegendData(LegendDataManagement.SetupConfig(sort(paths), setup.dataset), getfield(l200, :_name), getfield(l200, :_dataset))
end

# The report of `run_step`: the processor reports with only the rows of `selection`, then
# the plots below `plot_roots` saved since `started`, grouped by detector.
function step_report(step, args, level, outputs, dir, selection, reports, plot_roots, started)
    report = lreport("# $step: $(join(string.(args), " ")), $(utc_timestamp())")
    lreport!(report, "Detectors: $(isnothing(selection) ? "all" : join(sort!(collect(selection)), ", "))")
    lreport!(report, "Outputs: $outputs, `$dir`")
    for processor_report in reports, content in processor_report._contents
        lreport!(report, selected_rows(content, selection))
    end
    plots = [joinpath(root, f) for plot_root in filter(isdir, plot_roots) for (root, _, files) in walkdir(plot_root)
        for f in files if endswith(f, ".png") && mtime(joinpath(root, f)) >= started]
    isempty(plots) && return report
    lreport!(report, "# Plots")
    plot_det(file) = plot_detector(file, level)
    detectors = isnothing(selection) ? sort!(unique(plot_det.(plots))) : sort!(collect(selection))
    for det in detectors
        det_plots = sort!(filter(p -> plot_det(p) == det, plots); by = mtime)
        isempty(det_plots) && continue
        lreport!(report, "## $det")
        for file in det_plots
            lreport!(report, "### $(splitext(basename(file))[1])")
            lreport!(report, ReportPlot(file))
        end
    end
    return report
end

"""
    ReportPlot(file)

The PNG plot `file` in the report of [`run_step`](@ref). In the Markdown and HTML report,
the plot is embedded as an image; as text, it is shown by its file name.
[`display_report`](@ref) displays it as an image.
"""
struct ReportPlot
    file::String
end

Base.show(io::IO, ::MIME"image/png", p::ReportPlot) = write(io, read(p.file))

Base.show(io::IO, ::MIME"text/html", p::ReportPlot) =
    print(io, "<img src=\"data:image/png;base64,$(base64encode(read(p.file)))\" width=\"800\">")

Base.show(io::IO, ::MIME"text/plain", p::ReportPlot) = print(io, p.file)

"""
    display_report(report)

Display the report `report` of [`run_step`](@ref), e.g. `step.report`, with `display`: the
text and tables as usual, and each [`ReportPlot`](@ref) as an image by the first display in
the display stack that shows `image/png`. In a terminal, such displays come with
KittyTerminalImages (Kitty, Ghostty) and ImageInTerminal (terminals with Sixel support,
needs ImageIO to read the PNG); in VS Code, the plots go to the plot pane. Without such a
display, a plot is shown by its file name.

# Examples
```julia
using KittyTerminalImages
Juleana.display_report(step.report)
```
"""
function display_report(report)
    text = Any[]
    show_text() = isempty(text) || (display(lreport(text...)); empty!(text))
    for content in report._contents
        if content isa ReportPlot
            show_text()
            try
                display(MIME"image/png"(), content)
            catch e
                # no display in the display stack shows `image/png`
                e isa MethodError && e.f === display || rethrow()
                display(content)
            end
        else
            push!(text, content)
        end
    end
    show_text()
    return nothing
end

# The detector in a plot file name `<setup>-<period>-<run>-<category>-<detector>-<name>.png` of
# a run-level processor or `<setup>-<partition>-<category>-<detector>-<name>.png` of a
# partition-level one.
plot_detector(file, level::Symbol) = String(split(basename(file), '-')[level === :run ? 5 : 4])

# `content` with only the rows whose `Detector` is in `selection`.
function selected_rows(content, selection)
    (isnothing(selection) || !(content isa StructArray) || !hasproperty(content, :Detector)) && return content
    return content[[string(det) in selection for det in content.Detector]]
end
