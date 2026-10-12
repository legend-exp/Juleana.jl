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
The function comes first, as in `map`, so a `do`-block can supply it. A progress bar
labeled `process_name` shows the finished items.

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
    # prevent crash from Base
    Base.exit_on_sigint(false)
    try

        flush(stdout)
        # assign tasks to workers 
        # Known Caveat: Split broadcasting over iterator and fetch of results in two separate lines, otherwise weird things with onworker going on
        failure_row(itr, e) = itr => (processed = false, log = failure_log(log_nt, itr, truncate_string(string(e))))
        tasks = broadcast(iterator) do itr
            Threads.@spawn try
                # Past `maxtime`, onworker terminates the worker (never the main process) and
                # counts the timeout as a failed try; the last failure lands in the catch below.
                onworker(; tries=retry ? 3 : 1, label="$itr", maxtime=timeout) do
                    try
                        return itr => f(itr)
                    catch e
                        # Caught here so that `retry` only covers worker loss and timeouts, not errors in `f`.
                        @debug "Write Error log for $(itr): $e"
                        return failure_row(itr, e)
                    end
                end
            catch e
                e isa TaskFailedException && (e = e.task.exception)
                @debug "Worker call failed for $(itr): $e"
                failure_row(itr, e)
            end
        end
        # set up Porgressbar
        p = Progress(length(iterator); desc=process_name, showspeed=true, dt=0.5)
        update!(p)
    
        errormonitor(Threads.@spawn watch_tasks(() -> next!(p), tasks))
        # fetch results
        result = fetch.(tasks)

        flush(stdout)
        return result
    finally
        Base.exit_on_sigint(true)
    end
end
