# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

"""
    wait_for(ready, what::AbstractString; abort::Threads.Atomic{Bool}, timeout::Real, poll::Real=10,
        stop::Threads.Atomic{Bool}=Threads.Atomic{Bool}(false))

Block until the zero-argument function `ready()` returns `true`, checking every `poll`
seconds, and return `nothing`. When `ready()` is `false` on the first check, log a
warning `"Waiting for \$what"`. Throw [`ProcessingStopped`](@ref) as soon as `stop[]` is
`true`, and an `ErrorException` that names `what` as soon as `abort[]` is `true` or after
`timeout` seconds.

# Examples
```julia
abort = Threads.Atomic{Bool}(false)
Juleana.wait_for("energy calibration of p03"; abort, timeout = 3600) do
    all(values(run_status[DataPeriod(3)][:process_energy_calibration_cal]))
end
```
"""
function wait_for(ready, what::AbstractString; abort::Threads.Atomic{Bool}, timeout::Real, poll::Real = 10,
        stop::Threads.Atomic{Bool} = Threads.Atomic{Bool}(false))
    ready() && return nothing
    @warn "Waiting for $what"
    t_end = time() + timeout
    while !ready()
        stop[] && throw(ProcessingStopped())
        abort[] && error("Stopped waiting for $what: another processing task failed")
        time() > t_end && error("Timed out after $timeout s waiting for $what")
        sleep(poll)
    end
    return nothing
end

"""
    partition_periods(l200::LegendData, period::DataPeriod)

Return the sorted periods that share a default `cal` or `phy` partition with `period`,
`period` included. The default partitions in `datasets.cal_groupings` and
`datasets.phy_groupings` are the widest: the partitions of single detectors lie within
them.
"""
function partition_periods(l200::LegendData, period::DataPeriod)
    periods = Set([period])
    for category in (:cal, :phy), periods_runs in values(l200.metadata.datasets[Symbol("$(category)_groupings")].default)
        partition = DataPeriod.(collect(keys(periods_runs)))
        period in partition && union!(periods, partition)
    end
    return sort!(collect(periods))
end

"""
    run_processing(cfg::ProcessingConfig, l200, periods, run_steps, partition_steps,
        run_status, partition_status; processors::AbstractDict{Symbol}=PROCESSORS,
        check_dependencies::Bool=true, reprocess::Union{Nothing,Bool}=nothing,
        dependency_timeout::Real=24*3600, stop::Threads.Atomic{Bool}=Threads.Atomic{Bool}(false),
        abandon::Threads.Atomic{Bool}=Threads.Atomic{Bool}(false),
        progress_store::Union{Nothing,ProgressStore}=nothing)

Run the partition-level steps `partition_steps` for every period in `periods` and the
run-level steps `run_steps` for every period and every run listed in
`run_status`. Periods, runs, and the two levels run concurrently; the steps of one
period (partition level) or one run (run level) run in order. Processor functions are
looked up by name in `processors`. `l200` (usually a `LegendData`) is passed to every
processor and to the run-info checks `is_analysis_run` and `is_lrun`.

`run_status[period][step][run]` and `partition_status[period][step]` are set to
`true` when a step finishes. A run step that is skipped because the run is not an
analysis run (with `cfg.analysis_runs_only`) or not in the run info also counts as
finished for that run. Every step of `cfg` must have an entry for each period (and, at
run level, for each run), and steps that are not scheduled must start as `true`;
otherwise a dependency on them waits until `dependency_timeout`. `run_status` lists the
runs to process: every run of a period that has an entry in the first step's table.

With `check_dependencies`, a step waits for the steps that [`waited_processors`](@ref)
returns for it in the [`processor_graph`](@ref) of `cfg`, with `run_steps` and
`partition_steps` as the selected steps:
- a run step for the same run, or, when the graph reaches it through a partition step,
  for all runs of the periods given by [`partition_periods`](@ref) that are in `periods`;
- a run step that a partition step waits for, for all runs of the periods given by
  `partition_periods` that are in `periods`: a partition can contain runs of later
  periods;
- a partition step for the same period.
A partition step whose processor returns `true` also waits after processing until the
same step has finished for the previous period.

A wait that exceeds `dependency_timeout` seconds throws. When any task throws, the other
tasks stop at their next wait, and the exceptions are rethrown once all tasks have
stopped.

Setting `stop[]` to `true` stops the run: no further step starts, waiting steps stop
waiting, and [`parallel`](@ref) hands no further items to workers and throws
[`ProcessingStopped`](@ref) once its running items have finished. With `abandon[]` also
`true`, `parallel` throws without waiting for its running items, which go on in the
background. The run then ends with the resulting exceptions as above. `reprocess`, when not `nothing`, overrides the `reprocess` keyword of every
processor. A step without an entry in `processors` throws an `ArgumentError` before any
work starts. Return `nothing`.

With a [`ProgressStore`](@ref) as `progress_store`, the store is reset to the scheduled
steps, every step's state is recorded there (`:skipped` for a run that is not processed,
`:failed` or `:stopped` for a step that threw) and `parallel` records the items of the
step that calls it. Steps that never started are `:stopped` when the run was stopped and
`:cancelled` otherwise.
"""
function run_processing(
        cfg::ProcessingConfig, l200, periods::AbstractVector{DataPeriod},
        run_steps::AbstractVector{Symbol}, partition_steps::AbstractVector{Symbol},
        run_status::AbstractDict, partition_status::AbstractDict;
        processors::AbstractDict{Symbol} = PROCESSORS, check_dependencies::Bool = true, reprocess::Union{Nothing,Bool} = nothing,
        dependency_timeout::Real = 24 * 3600, stop::Threads.Atomic{Bool} = Threads.Atomic{Bool}(false),
        abandon::Threads.Atomic{Bool} = Threads.Atomic{Bool}(false), progress_store::Union{Nothing,ProgressStore} = nothing
    )
    unregistered = filter(!in(keys(processors)), collect(Iterators.flatten((run_steps, partition_steps))))
    isempty(unregistered) ||
        throw(ArgumentError("run_processing: unregistered processor(s) $(join(unregistered, ", "))"))
    abort = Threads.Atomic{Bool}(false)
    waits = check_dependencies ? waited_processors(processor_graph(cfg), vcat(run_steps, partition_steps)) : nothing
    span, span_lock = Dict{DataPeriod,Vector{DataPeriod}}(), ReentrantLock()
    # periods whose runs a step of `period` waits for when it waits for all runs
    span_periods(period) = @lock span_lock get!(() -> filter(in(periods), partition_periods(l200, period)), span, period)
    # Wait until the steps that `process` waits for have finished, for `period` and, at run level, `run`.
    function wait_for_steps(process, period, run = nothing)
        isempty(waits[process]) && return nothing
        done(step, same_run) = haskey(cfg.p_processors, step) ? partition_status[period][step] :
            same_run ? run_status[period][step][run] : all(q -> all(values(run_status[q][step])), span_periods(period))
        what = join((haskey(cfg.p_processors, step) || same_run ? "$step" : "$step of $(join(span_periods(period), ", "))"
            for (step, same_run) in waits[process]), ", ")
        wait_for("$what before $process of $(isnothing(run) ? period : "$period-$run")"; abort, stop, timeout = dependency_timeout) do
            all(((step, same_run),) -> done(step, same_run), waits[process])
        end
    end
    overrides = isnothing(reprocess) ? (;) : (; reprocess)
    # every step lists the same runs of the period
    period_runs = Dict(period => sort!(collect(keys(last(first(run_status[period]))))) for period in periods if !isempty(run_steps))

    if !isnothing(progress_store)
        reset_progress!(progress_store, vcat(
            ProgressKey[(period, nothing, step) for period in periods for step in partition_steps],
            ProgressKey[(period, run, step) for period in periods for run in get(period_runs, period, DataRun[]) for step in run_steps]))
    end
    mark(key, state; error = nothing) = isnothing(progress_store) || set_step_state!(progress_store, key, state; error)
    # Run the step `key` with `f`, recording its state and making it the progress entry of `parallel`.
    function tracked(f, key)
        mark(key, :running)
        try
            isnothing(progress_store) ? f() : with(f, PROGRESS_STEP => (progress_store, key))
        catch e
            e isa ProcessingStopped ? mark(key, :stopped) : mark(key, :failed; error = sprint(showerror, e))
            rethrow()
        end
        mark(key, :done)
    end

    function partition_chain(period)
        @info "Process partitions in $period"
        for process in partition_steps
            stop[] && throw(ProcessingStopped())
            @info "$process"
            spec = cfg.p_processors[process]
            check_dependencies && wait_for_steps(process, period)
            only_first_period = DataPeriod(period.no - 1) in periods
            kwargs = merge(NamedTuple(spec.kwargs), (; only_first_period), overrides)
            tracked((period, nothing, process)) do
                has_lower_period_dependency = processors[process](cfg, l200, period; kwargs...)
                if has_lower_period_dependency && check_dependencies
                    previous = DataPeriod(period.no - 1)
                    wait_for("$process of $previous before finishing $period"; abort, stop, timeout = dependency_timeout) do
                        partition_status[previous][process]
                    end
                end
            end
            partition_status[period][process] = true
            @info "Finished $period $process"
        end
    end

    function run_chain(period, run)
        @info "Process run $period-$run"
        for process in run_steps
            stop[] && throw(ProcessingStopped())
            @info "$process"
            flush(stdout)
            spec = cfg.processors[process]
            key = (period, run, spec.category)
            if cfg.analysis_runs_only && !is_analysis_run(l200, key)
                @warn "$period-$run-$(spec.category) is not an analysis run, skip $process"
                mark((period, run, process), :skipped)
            elseif !is_lrun(l200, key)
                @warn "$period-$run-$(spec.category) is not in runinfo, skip $process"
                mark((period, run, process), :skipped)
            else
                check_dependencies && wait_for_steps(process, period, run)
                tracked((period, run, process)) do
                    processors[process](cfg, l200, period, run; merge(NamedTuple(spec.kwargs), overrides)...)
                end
                flush(stdout)
                @info "Finished $period-$run $process"
            end
            run_status[period][process][run] = true
        end
    end

    # Each spawned task sets `abort` before rethrowing so that waiting tasks stop too.
    guarded(f, args...) = try
        f(args...)
    catch
        abort[] = true
        rethrow()
    end

    # `parallel` reads the stop flags from the scope; spawned tasks inherit it.
    try
        with(PROCESSING_STOP => stop, PROCESSING_ABANDON => abandon) do
            @sync begin
                if !isempty(partition_steps)
                    for period in periods
                        Threads.@spawn guarded(partition_chain, period)
                    end
                end
                if !isempty(run_steps)
                    for period in periods
                        for run in period_runs[period]
                            Threads.@spawn guarded(run_chain, period, run)
                        end
                    end
                end
            end
        end
    finally
        # steps that never ran: stopped by the user or cancelled by a failure elsewhere
        isnothing(progress_store) || finish_progress!(progress_store, stop[] ? :stopped : :cancelled)
    end
    return nothing
end
