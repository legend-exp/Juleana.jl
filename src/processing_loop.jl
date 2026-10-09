# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

"""
    wait_for(ready, what::AbstractString; abort::Threads.Atomic{Bool}, timeout::Real, poll::Real=10)

Block until `ready()` returns `true`, checking every `poll` seconds. Throw an
`ErrorException` that names `what` as soon as `abort[]` is `true` or after `timeout`
seconds.
"""
function wait_for(ready, what::AbstractString; abort::Threads.Atomic{Bool}, timeout::Real, poll::Real = 10)
    ready() && return nothing
    @warn "Waiting for $what"
    t_end = time() + timeout
    while !ready()
        abort[] && error("Stopped waiting for $what: another processing task failed")
        time() > t_end && error("Timed out after $timeout s waiting for $what")
        sleep(poll)
    end
    return nothing
end

"""
    run_processing(cfg::ProcessingConfig, l200::LegendData, periods, process_steps, p_process_steps,
        process_status, p_process_status; processors::AbstractDict{Symbol}=PROCESSORS,
        check_dependencies::Bool=true, reprocess::Union{Nothing,Bool}=nothing,
        dependency_timeout::Real=24*3600)

Run the partition-level steps `p_process_steps` for every period in `periods` and the
run-level steps `process_steps` for every period and every run listed in
`process_status`. Periods, runs, and the two levels run concurrently; the steps of one
period (partition level) or one run (run level) run in order. Processor functions are
looked up by name in `processors`.

`process_status[period][step][run]` and `p_process_status[period][step]` are set to
`true` when a step finishes. A run step that is skipped because the run is not an
analysis run (with `cfg.analysis_runs_only`) or not in the run info also counts as
finished for that run. Steps that are not scheduled must start as finished, as
`setup_dependency_graph` does.

With `check_dependencies`:
- a run step waits until each of its dependencies, and every partition step ranked
  before them, has finished for its period;
- a partition step waits until each of its dependencies, and every run step ranked
  before them, has finished for all runs of its period;
- a partition step whose processor returns `true` waits after processing until the
  same step has finished for the previous period.

A wait that exceeds `dependency_timeout` seconds throws. When any task throws, the other
tasks stop at their next wait, and the exceptions are rethrown once all tasks have
stopped. `reprocess`, when not `nothing`, overrides the `reprocess` keyword of every
processor. A step without an entry in `processors` throws an `ArgumentError` before any
work starts.
"""
function run_processing(
        cfg::ProcessingConfig, l200::LegendData, periods::AbstractVector{DataPeriod},
        process_steps::AbstractVector{Symbol}, p_process_steps::AbstractVector{Symbol},
        process_status::AbstractDict, p_process_status::AbstractDict;
        processors::AbstractDict{Symbol} = PROCESSORS, check_dependencies::Bool = true, reprocess::Union{Nothing,Bool} = nothing,
        dependency_timeout::Real = 24 * 3600
    )
    unregistered = filter(!in(keys(processors)), [process_steps; p_process_steps])
    isempty(unregistered) ||
        throw(ArgumentError("run_processing: unregistered processor(s) $(join(unregistered, ", "))"))
    abort = Threads.Atomic{Bool}(false)
    possible_steps = run_steps(cfg; enabled_only = false)
    possible_p_steps = partition_steps(cfg; enabled_only = false)
    # A dependency on a step implies every step of the same level ranked before it.
    ranked_upto(steps, deps) = unique(reduce(vcat, (steps[1:findfirst(==(d), steps)] for d in deps); init = Symbol[]))
    overrides = isnothing(reprocess) ? (;) : (; reprocess)

    function partition_chain(period)
        @info "Process partitions in $period"
        for process in p_process_steps
            @info "$process"
            spec = cfg.p_processors[process]
            if check_dependencies
                deps = ranked_upto(possible_steps, spec.dependencies)
                wait_for("run steps $(join(deps, ", ")) of $period before $process"; abort, timeout = dependency_timeout) do
                    all(dep -> all(values(process_status[period][dep])), deps)
                end
            end
            only_first_period = DataPeriod(period.no - 1) in periods
            kwargs = merge(NamedTuple(spec.kwargs), (; only_first_period), overrides)
            has_lower_period_dependency = processors[process](cfg, l200, period; kwargs...)
            if has_lower_period_dependency && check_dependencies
                previous = DataPeriod(period.no - 1)
                wait_for("$process of $previous before finishing $period"; abort, timeout = dependency_timeout) do
                    p_process_status[previous][process]
                end
            end
            p_process_status[period][process] = true
            @info "Finished $period $process"
        end
    end

    function run_chain(period, run)
        @info "Process run $period-$run"
        for process in process_steps
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
                    wait_for("partition steps $(join(deps, ", ")) of $period before $process"; abort, timeout = dependency_timeout) do
                        all(dep -> p_process_status[period][dep], deps)
                    end
                end
                processors[process](cfg, l200, period, run; merge(NamedTuple(spec.kwargs), overrides)...)
                flush(stdout)
                @info "Finished $period-$run $process"
            end
            process_status[period][process][run] = true
        end
    end

    # Each spawned task sets `abort` before rethrowing so that waiting tasks stop too.
    guarded(f, args...) = try
        f(args...)
    catch
        abort[] = true
        rethrow()
    end

    @sync begin
        if !isempty(p_process_steps)
            for period in periods
                Threads.@spawn guarded(partition_chain, period)
            end
        end
        if !isempty(process_steps)
            for period in periods
                # every step lists the same runs of the period
                for run in sort!(collect(keys(last(first(process_status[period])))))
                    Threads.@spawn guarded(run_chain, period, run)
                end
            end
        end
    end
    return nothing
end
