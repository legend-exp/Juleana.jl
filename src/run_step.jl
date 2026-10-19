# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

"""
    StepItemsDone(results)

Thrown by [`parallel`](@ref) inside [`run_step`](@ref) once the selected items have run:
it ends the processor before it writes parameters, validity or reports for the subset.
`results` holds the `item => result` pairs. [`run_step`](@ref) catches it and returns
`results`.
"""
struct StepItemsDone <: Exception
    results::Vector{Any}
end

Base.showerror(io::IO, e::StepItemsDone) =
    print(io, "StepItemsDone: ", length(e.results), " item(s) ran; the processor ends here")

# Predicate of the items `parallel` runs in the calling process, set by `run_step`;
# `nothing` outside of it.
const LOCAL_ITEMS = ScopedValue{Union{Nothing,Function}}(nothing)

"""
    run_step(step::Symbol, period, run = nothing; config = Juleana.default_config_file(),
        l200 = nothing, detectors = nothing, select = nothing,
        processors::AbstractDict{Symbol} = PROCESSORS, kwargs...)

Run the processor `step` for `period` and, for a run-level processor, `run` in the
calling Julia process, for debugging in the REPL. The processor runs as in
[`run_processing`](@ref) up to its first [`parallel`](@ref) call. There, only the items
whose `detector` is in `detectors` (all items with `detectors = nothing`) and for which
`select(item)` is `true` run, one after another in the calling process and not on
workers. An error in an item is thrown, not written to the report row. Then the processor
ends before it writes parameters, validity or reports. Return the `item => result` pairs of
the items that ran.

Since the items run in the calling process, `Main.@infiltrate` from Infiltrator.jl in a
processor stops there with the local variables of the item.

`config` is a [`ProcessingConfig`](@ref) or the path of a config file. Its
`env_variables` are set before `l200` is built as `LegendData(:l200)` when `l200` is
`nothing`. The keyword arguments of the processor are those of `config` with
`reprocess = true`, for a partition-level processor `only_first_period = false`, and then
`kwargs`.

Throws an `ArgumentError` if `step` is not registered or not in `config`, if `run` is given
for a partition-level processor or missing for a run-level one, if `detectors` is given for
items without a `detector` field, or if no item is selected; and an `ErrorException` if the
processor returns without calling `parallel`.

# Examples
```julia
using Juleana, Infiltrator
results = run_step(:process_energy_calibration_cal, 3, 0; detectors = [:V01234A])
```
"""
function run_step(step::Symbol, period, run = nothing; config = default_config_file(), l200 = nothing,
        detectors = nothing, select = nothing, processors::AbstractDict{Symbol} = PROCESSORS, kwargs...)
    haskey(processors, step) || throw(ArgumentError("run_step: unregistered processor `$step`"))
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
    names = isnothing(detectors) ? nothing : Set(string.(detectors))
    function chosen(item)
        if !isnothing(names)
            hasproperty(item, :detector) ||
                throw(ArgumentError("run_step: the items of `$step` have no detector, select them with `select`: $item"))
            string(item.detector) in names || return false
        end
        return isnothing(select) || select(item)
    end
    args = spec.level === :run ? (DataPeriod(period), DataRun(run)) : (DataPeriod(period),)
    defaults = spec.level === :run ? (; reprocess = true) : (; reprocess = true, only_first_period = false)
    try
        with(LOCAL_ITEMS => chosen) do
            processors[step](cfg, l200, args...; merge(NamedTuple(spec.kwargs), defaults, NamedTuple(kwargs))...)
        end
    catch e
        e isa StepItemsDone && return e.results
        rethrow()
    end
    error("run_step: `$step` returned without calling `parallel`")
end
