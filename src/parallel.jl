"""
    failure_log(log_nt, itr, message::AbstractString)

Build the report row for an item of `parallel` that threw. `log_nt` is the processor's
`NamedTuple{names}` row type and `message` the truncated error text. The status column
is `ProcessStatus(0)` and every column without data is filled with `"-"`.

Methods exist for `FileKey` items, giving `(itr, status, "-"..., message)`, and for
`NamedTuple` items with `detector` and `usability` fields, giving
`(detector, usability, [partition,] status, "-"..., message)`; the partition column is
present when the item has a `partition` field.
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

"""
    parallel(f, iterator::AbstractArray, log_nt; timeout::Real=0, retry::Bool=false, process_name::AbstractString="")
    parallel(iterator::AbstractArray, log_nt; kwargs...) do itr
        ...
    end

Apply `f` to every element of `iterator` on the ParallelProcessingTools worker pool and
return an array of `itr => f(itr)` pairs with the same shape and axes as `iterator`.
The function comes first, as in `map`, so a `do`-block can supply it.

An item whose `f` throws, or exceeds `timeout` seconds when `timeout > 0`, does not abort
the batch: its pair is `itr => (processed = false, log = failure_log(log_nt, itr, msg))`
and the batch continues. `retry = true` gives each item up to three attempts on worker
loss. Element types without a [`failure_log`](@ref) method for `log_nt` are rejected
with an `ArgumentError` before any work starts.
"""
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
                # The pool's own limit is a backstop for the poll loop below, which checks every 0.1 s;
                # whichever fires first, the item ends up as a failure row rather than aborting the batch.
                onworker(; tries=retry ? 3 : 1, label="$itr", maxtime=1.1*timeout) do
                    try
                        if timeout <= 0
                            return itr => f(itr)
                        end
                        t_end = time() + timeout
                        task = Threads.@spawn f(itr)
                        while time() <= t_end && !istaskdone(task)
                            sleep(0.1)
                        end
                        if !istaskdone(task)
                            @debug "Timeout for $(itr)"
                            schedule(task, InterruptException(); error=true)
                            throw(ErrorException("Timeout for $(itr)"))
                        end
                        return itr => fetch(task)
                    catch e
                        # Caught here so that `retry` only covers worker loss, not errors in `f`.
                        e isa TaskFailedException && (e = e.task.exception)
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
