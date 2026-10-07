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
    parallel(iterator::AbstractArray, f, log_nt; timeout::Int=0, retry::Bool=false, process_name::String="")

Apply `f` to every element of `iterator` on the ParallelProcessingTools worker pool and
return a vector of `itr => f(itr)` pairs in iterator order.

An item whose `f` throws, or exceeds `timeout` seconds when `timeout > 0`, does not abort
the batch: its pair is `itr => (processed = false, log = failure_log(log_nt, itr, msg))`
and the batch continues. `retry = true` gives each item up to three attempts on worker
loss. Element types without a [`failure_log`](@ref) method for `log_nt` are rejected
with an `ArgumentError` before any work starts.
"""
function parallel(iterator::AbstractArray, f, log_nt::Type{<:NamedTuple}; timeout::Int=0, retry::Bool=false, process_name::String="")
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
        tasks = broadcast(iterator) do itr
            Threads.@spawn begin
                # maxtime will be set togehter with internal timeout for better handling
                onworker(; tries=retry ? 3 : 1, label="$itr", maxtime=1.1*timeout) do
                    try
                        # without timeout execute task
                        if timeout <= 0
                            f_res = f(itr)
                            return itr => f_res
                        # with timeout execute task inside thread and kill with InterruptException() in case it overruns maxtime
                        else
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
                        end
                    catch e
                        if e isa TaskFailedException
                            e = e.task.exception
                        end
                        msg = truncate_string(string(e))
                        @debug "Write Error log for $(itr): $msg"
                        return itr => (processed = false, log = failure_log(log_nt, itr, msg))
                    end
                end
            end
        end
        # set up Porgressbar
        p = Progress(length(iterator); desc=process_name, showspeed=true, dt=0.5)
        update!(p)
    
        # create result vector
        Threads.@spawn begin
            update!(p)
            n_finished = 0
            while n_finished < length(iterator)
                for t in tasks
                    if istaskdone(t)
                        n_finished += 1
                        next!(p)
                        update!(p)
                    end
                end
                sleep(2)
            end
        end
        # fetch results
        result = fetch.(tasks)

        flush(stdout)
        return result
    finally
        Base.exit_on_sigint(true)
    end
end
