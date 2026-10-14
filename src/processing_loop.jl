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
    all(values(run_status[DataPeriod(3)][:process_energy_calibration]))
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
    run_processing(cfg::ProcessingConfig, l200, periods, run_steps, partition_steps,
        run_status, partition_status; processors::AbstractDict{Symbol}=PROCESSORS,
        check_dependencies::Bool=true, reprocess::Union{Nothing,Bool}=nothing,
        dependency_timeout::Real=24*3600, stop::Threads.Atomic{Bool}=Threads.Atomic{Bool}(false))

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

With `check_dependencies`:
- a run step waits until each of its dependencies, and every partition step ranked
  before them, has finished for its period;
- a partition step waits until each of its dependencies, and every run step ranked
  before them, has finished for all runs of its period;
- a partition step whose processor returns `true` waits after processing until the
  same step has finished for the previous period.

A wait that exceeds `dependency_timeout` seconds throws. When any task throws, the other
tasks stop at their next wait, and the exceptions are rethrown once all tasks have
stopped.

Setting `stop[]` to `true` stops the run: no further step starts, waiting steps stop
waiting, and [`parallel`](@ref) hands no further items to workers and throws
[`ProcessingStopped`](@ref) once its running items have finished. The run then ends with
the resulting exceptions as above. `reprocess`, when not `nothing`, overrides the `reprocess` keyword of every
processor. A step without an entry in `processors` throws an `ArgumentError` before any
work starts. Return `nothing`.
"""
function run_processing(
        cfg::ProcessingConfig, l200, periods::AbstractVector{DataPeriod},
        run_steps::AbstractVector{Symbol}, partition_steps::AbstractVector{Symbol},
        run_status::AbstractDict, partition_status::AbstractDict;
        processors::AbstractDict{Symbol} = PROCESSORS, check_dependencies::Bool = true, reprocess::Union{Nothing,Bool} = nothing,
        dependency_timeout::Real = 24 * 3600, stop::Threads.Atomic{Bool} = Threads.Atomic{Bool}(false)
    )
    unregistered = filter(!in(keys(processors)), collect(Iterators.flatten((run_steps, partition_steps))))
    isempty(unregistered) ||
        throw(ArgumentError("run_processing: unregistered processor(s) $(join(unregistered, ", "))"))
    abort = Threads.Atomic{Bool}(false)
    # `run_steps`/`partition_steps` are local names here, so read the step lists from the tables.
    possible_steps = _sorted_steps(cfg.processors, false)
    possible_p_steps = _sorted_steps(cfg.p_processors, false)
    # A dependency on a step implies every step of the same level ranked before it.
    ranked_upto(steps, deps) = unique(reduce(vcat, (steps[1:findfirst(==(d), steps)] for d in deps); init = Symbol[]))
    overrides = isnothing(reprocess) ? (;) : (; reprocess)

    function partition_chain(period)
        @info "Process partitions in $period"
        for process in partition_steps
            stop[] && throw(ProcessingStopped())
            @info "$process"
            spec = cfg.p_processors[process]
            if check_dependencies
                deps = ranked_upto(possible_steps, spec.dependencies)
                wait_for("run steps $(join(deps, ", ")) of $period before $process"; abort, stop, timeout = dependency_timeout) do
                    all(dep -> all(values(run_status[period][dep])), deps)
                end
            end
            only_first_period = DataPeriod(period.no - 1) in periods
            kwargs = merge(NamedTuple(spec.kwargs), (; only_first_period), overrides)
            has_lower_period_dependency = processors[process](cfg, l200, period; kwargs...)
            if has_lower_period_dependency && check_dependencies
                previous = DataPeriod(period.no - 1)
                wait_for("$process of $previous before finishing $period"; abort, stop, timeout = dependency_timeout) do
                    partition_status[previous][process]
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
            elseif !is_lrun(l200, key)
                @warn "$period-$run-$(spec.category) is not in runinfo, skip $process"
            else
                if check_dependencies
                    deps = ranked_upto(possible_p_steps, spec.dependencies)
                    wait_for("partition steps $(join(deps, ", ")) of $period before $process"; abort, stop, timeout = dependency_timeout) do
                        all(dep -> partition_status[period][dep], deps)
                    end
                end
                processors[process](cfg, l200, period, run; merge(NamedTuple(spec.kwargs), overrides)...)
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

    # `parallel` reads the stop flag from the scope; spawned tasks inherit it.
    with(PROCESSING_STOP => stop) do
        @sync begin
            if !isempty(partition_steps)
                for period in periods
                    Threads.@spawn guarded(partition_chain, period)
                end
            end
            if !isempty(run_steps)
                for period in periods
                    # every step lists the same runs of the period
                    for run in sort!(collect(keys(last(first(run_status[period])))))
                        Threads.@spawn guarded(run_chain, period, run)
                    end
                end
            end
        end
    end
    return nothing
end
