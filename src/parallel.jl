"""
    ProcessingStopped()

Exception thrown by [`parallel`](@ref) when processing was stopped while the batch ran:
items that had not started are not run, and the processor that called `parallel` ends
without writing results.
"""
struct ProcessingStopped <: Exception end

Base.showerror(io::IO, ::ProcessingStopped) = print(io, "ProcessingStopped: processing was stopped")

# Stop flag of the current processing run, set by `run_processing`; `nothing` outside of it.
const PROCESSING_STOP = ScopedValue{Union{Nothing,Threads.Atomic{Bool}}}(nothing)

# Flag of the current processing run to stop waiting for running items; `nothing` outside of it.
const PROCESSING_ABANDON = ScopedValue{Union{Nothing,Threads.Atomic{Bool}}}(nothing)

# Progress entry of the current processing step, set by `run_processing`; `nothing` outside of it.
const PROGRESS_STEP = ScopedValue{Union{Nothing,Tuple{ProgressStore,ProgressKey}}}(nothing)

# Called by `StoppablePool` with each worker it hands out to the current item of `parallel`.
const ITEM_STARTED = ScopedValue{Any}(nothing)

# Worker pool that hands out no worker once `stop` is set: `take!` throws
# `ProcessingStopped` instead, also while it waits for a free worker. That keeps a stop
# from hanging when no worker will become free, e.g. after all workers were stopped.
struct StoppablePool{P<:AbstractWorkerPool} <: AbstractWorkerPool
    pool::P
    stop::Threads.Atomic{Bool}
end

function Base.take!(p::StoppablePool)
    p.stop[] && throw(ProcessingStopped())
    taker = Threads.@spawn take!(p.pool)
    while !istaskdone(taker)
        if p.stop[]
            # the worker the taker gets later goes back to the pool
            errormonitor(Threads.@spawn put!(p.pool, fetch(taker)))
            throw(ProcessingStopped())
        end
        sleep(0.2)
    end
    worker = fetch(taker)
    if p.stop[]
        put!(p.pool, worker)
        throw(ProcessingStopped())
    end
    started = ITEM_STARTED[]
    isnothing(started) || started(worker)
    return worker
end

Base.put!(p::StoppablePool, worker::Int) = put!(p.pool, worker)

"""
    failure_log(log_nt, itr, message::AbstractString)

Build the report row for an item of `parallel` that threw. `log_nt` is the processor's
`NamedTuple{names}` row type and `message` the truncated error text. The status column
is `ProcessStatus(0)` and every column without data is filled with `"-"`.

Methods exist for `FileKey` items, giving `(itr, status, "-"..., message)`, and for
`NamedTuple` items with `detector` and `usability` fields, giving
`(detector, usability, [partition,] status, "-"..., message)`; the partition column is
present when the item has a `partition` field. A new item type for [`parallel`](@ref)
needs its own `failure_log` method.
"""
function failure_log(log_nt::Type{<:NamedTuple}, itr::FileKey, message::AbstractString)
    log_nt((itr, ProcessStatus(0), fill("-", length(fieldnames(log_nt)) - 3)..., message))
end

function failure_log(log_nt::Type{<:NamedTuple}, itr::NamedTuple, message::AbstractString)
    haskey(itr, :detector) && haskey(itr, :usability) ||
        throw(ArgumentError("failure_log needs `detector` and `usability` fields, got $(keys(itr))"))
    lead = haskey(itr, :partition) ?
        (itr.detector, detector_status(itr.usability), itr.partition) :
        (itr.detector, detector_status(itr.usability))
    log_nt((lead..., ProcessStatus(0), fill("-", length(fieldnames(log_nt)) - length(lead) - 2)..., message))
end

# Call `advance()` once for each task in `tasks` as it finishes, checking every `poll` seconds;
# return when all tasks are done.
function watch_tasks(advance, tasks::AbstractArray{Task}; poll::Real = 2)
    counted = fill!(similar(tasks, Bool), false)
    while !all(counted)
        for i in eachindex(tasks, counted)
            if !counted[i] && istaskdone(tasks[i])
                counted[i] = true
                advance()
            end
        end
        all(counted) || sleep(poll)
    end
    return nothing
end

"""
    parallel(f, iterator::AbstractArray, log_nt; timeout::Real=0, retry::Bool=false, process_name::AbstractString="")
    parallel(iterator::AbstractArray, log_nt; kwargs...) do itr
        ...
    end

Apply `f` to every element of `iterator` on the ParallelProcessingTools worker pool and
return an array of `itr => f(itr)` pairs with the same shape and axes as `iterator`.
The function comes first, as in `map`, so a `do`-block can supply it. Inside
[`run_processing`](@ref) with a [`ProgressStore`](@ref), each item's start, worker and
outcome are recorded for the current step; otherwise a progress bar labeled
`process_name` shows the finished items.

`log_nt` is the `NamedTuple` type of the processor's report rows. On success `f` returns a
`NamedTuple` with at least the fields `processed::Bool` and `log`, a row of type `log_nt`
(or a `Dict` of such rows), so that successful and failed items have the same shape for
[`master_status`](@ref) and the report.

An item whose `f` throws, or exceeds `timeout` seconds when `timeout > 0`, does not abort
the batch: its pair is `itr => (processed = false, log = failure_log(log_nt, itr, msg))`.
A timed-out item's worker process is terminated and not replaced; an item on the main
process keeps running in the background. With `retry = true`, each item gets up to three
attempts after a worker loss or a timeout; an error thrown by `f` is not retried.

Element types without a [`failure_log`](@ref) method for `log_nt` are rejected with an
`ArgumentError` before any work starts.

Inside [`run_processing`](@ref), a stop of the processing run takes effect here: items that
have not been handed to a worker are not run, items already running finish, and `parallel`
then throws [`ProcessingStopped`](@ref) instead of returning. When the run is stopped without
waiting for running items, `parallel` throws right away and the running items go on in
the background; their workers return to the pool when the items end.

# Examples
```julia
using LegendDataManagement: FileKey, ProcessStatus
Row = NamedTuple{(:Filekey, :Status, :Events, :Error)}
filekeys = [FileKey("l200-p03-r000-cal-20230311T235840Z")]
results = parallel(filekeys, Row; process_name = "count events") do fk
    (processed = true, log = Row((fk, ProcessStatus(1), 1000, "")))
end
master_status(results)  # process_succeeded
```
"""
function parallel(f, iterator::AbstractArray, log_nt::Type{<:NamedTuple}; timeout::Real=0, retry::Bool=false, process_name::AbstractString="")
    for T in unique(typeof.(iterator))
        hasmethod(failure_log, Tuple{Type{log_nt}, T, String}) ||
            throw(ArgumentError("parallel: no failure_log method for items of type $T"))
    end
    stop = PROCESSING_STOP[]
    pool = isnothing(stop) ? ppt_worker_pool() : StoppablePool(ppt_worker_pool(), stop)
    step = PROGRESS_STEP[]
    first_id = isnothing(step) ? 0 : items_queued!(step..., length(iterator))
    flush(stdout)
    # assign tasks to workers
    # Known Caveat: Split broadcasting over iterator and fetch of results in two separate lines, otherwise weird things with onworker going on
    failure_row(itr, e) = itr => (processed = false, log = failure_log(log_nt, itr, truncate_string(string(e))))
    # one progress id per item, with the axes of `iterator`
    ids = first_id .+ (LinearIndices(iterator) .- first(LinearIndices(iterator)))
    tasks = broadcast(iterator, ids) do itr, id
        Threads.@spawn begin
            started = isnothing(step) ? nothing : worker -> item_started!(step..., id, worker, string(itr))
            result, outcome = try
                # Past `maxtime`, onworker terminates the worker (never the main process) and
                # counts the timeout as a failed try; the last failure lands in the catch below.
                with(ITEM_STARTED => started) do
                    onworker(; pool, tries=retry ? 3 : 1, label="$itr", maxtime=timeout) do
                        try
                            return itr => f(itr), :done
                        catch e
                            # Caught here so that `retry` only covers worker loss and timeouts, not errors in `f`.
                            @debug "Write Error log for $(itr): $e"
                            return failure_row(itr, e), :failed
                        end
                    end
                end
            catch e
                e isa TaskFailedException && (e = e.task.exception)
                @debug "Worker call failed for $(itr): $e"
                failure_row(itr, e), e isa ProcessingStopped ? :notrun : :failed
            end
            isnothing(step) || item_finished!(step..., id, outcome)
            result
        end
    end
    if isnothing(step)
        p = Progress(length(iterator); desc=process_name, showspeed=true, dt=0.5)
        update!(p)
        errormonitor(Threads.@spawn watch_tasks(() -> next!(p), tasks))
    end
    abandon = PROCESSING_ABANDON[]
    if !isnothing(abandon)
        while !abandon[] && !all(istaskdone, tasks)
            sleep(0.2)
        end
        if !all(istaskdone, tasks)
            # the running items go on in the background and free their workers when done
            isnothing(step) || items_abandoned!(step...)
            throw(ProcessingStopped())
        end
    end
    # fetch results
    result = fetch.(tasks)

    flush(stdout)
    !isnothing(stop) && stop[] && throw(ProcessingStopped())
    return result
end
