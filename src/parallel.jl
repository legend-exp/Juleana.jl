# get worker pool
function get_workerPool(processing_config::PropDict, process::Symbol)
    n_workers = get(processing_config.processors[process], :n_workers, "all")
    @assert typeof(n_workers) <: Int || n_workers == "all" "Number of workers must be an integer or 'all'."
    # do not compare with nworkers() here: elastic workers may not have joined yet when a
    # processor is called, and an integer n_workers must still act as the concurrency limit
    if n_workers == "all"
        wp = default_worker_pool()
        @info "Use default worker pool with $(length(wp)) workers."
        return wp
    else
        # make sure to distribute the workers evenly between all clusters
        if length(processing_config.processing.remote_workers) == 0
            return WorkerPool(2:n_workers+1)
        end
        cluster_workers_pids = [2:processing_config.processing.local_workers+1]
        for p in processing_config.processing.remote_workers
            last_pid = last(cluster_workers_pids[end])
            push!(cluster_workers_pids, last_pid+1:last_pid+last(p))
        end
        cluster_workers = append!([processing_config.processing.local_workers], [last(p) for p in processing_config.processing.remote_workers])
        cluster_shares = [floor(Int, n_workers * n / sum(cluster_workers)) for n in cluster_workers]
        wpool = Int64[]
        for (pids, share) in zip(cluster_workers_pids, cluster_shares)
            append!(wpool, rand(pids, share))
        end
        wp = WorkerPool(wpool)
        @info "Use custom worker pool with $(length(wp)) workers."
        return wp
    end
end

# retry delay check for parallel processing
function retry_check(delay_state, err)
    # Below each condition to retry is listed along with an explanation about why
    # retrying should/might work.
    should_retry = (
        # Worker death is normally stocastic, if not then doesn't matter how many
        # retries as it will rapidly kill all workers
        err isa ProcessExitedException ||
        # If we are in the middle of fetching data and the process is killed we could
        # get an ArgumentError saying that the stream was closed or unusable.
        # So same as above.
        err isa ArgumentError && occursin("stream is closed or unusable", err.msg) ||
        # In general IO errors can be transient and related to network blips
        err isa Base.IOError
    )
    if should_retry
        @info "Retrying computation that failed due to a $(typeof(err)): $err"
    else
        @warn "Non-retryable $(typeof(err)) occurred: $err"
    end
    return should_retry
end

function parallel(iterator::AbstractArray, f::Function, log_nt::UnionAll, wpool::WorkerPool; timeout::Int=0, retry::Bool=false, process_name::String="")
    # debug rerun (see src/debug.jl): run the matching items serially in the driver
    # task for full exception chains, never dispatch to workers; timeout and retry
    # do not apply there
    if !isnothing(DEBUG_RERUN[])
        return debug_serial_parallel(DEBUG_RERUN[], iterator, f, log_nt; process_name=process_name)
    end

    # prevent crash from Base
    Base.exit_on_sigint(false)

    flush(stdout)
    # onworker draws from the global elastic pool; a per-processor `wpool` (config n_workers)
    # smaller than that pool acts as a concurrency limit - at most length(wpool) items in
    # flight. The default pool may still be empty at this point (workers joining) - no limit then.
    n_limit = (wpool === default_worker_pool() || length(wpool) == 0) ? typemax(Int) : length(wpool)
    slots = Base.Semaphore(n_limit)
    # assign tasks to workers 
    # Known Caveat: Split broadcasting over iterator and fetch of results in two separate lines, otherwise weird things with onworker going on
    tasks = broadcast(iterator) do itr
        Threads.@spawn Base.acquire(slots) do
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
                            @async Base.throwto(task, InterruptException())
                            throw(ErrorException("Timeout for $(itr)"))
                        end
                        return itr => fetch(task)
                    end
                catch e
                    if e isa TaskFailedException
                        e = e.task.exception
                    end
                    @debug "Write Error log for $(itr): $(truncate_string(string(e)))"
                    # distinguish between ch and det logging or iterator logging
                    log_itr = nothing
                    if itr isa NamedTuple && haskey(itr, :channel) && haskey(itr, :detector)
                        if haskey(itr, :partition)
                            log_itr = log_nt((itr.detector, itr.channel, itr.partition, ProcessStatus(0), fill("-", length(fieldnames(log_nt))-5)..., "$(truncate_string(string(e)))"))
                        else
                            log_itr = log_nt((itr.detector, itr.channel, ProcessStatus(0), fill("-", length(fieldnames(log_nt))-4)..., "$(truncate_string(string(e)))"))
                        end
                    elseif itr isa FileKey
                        log_itr = log_nt((itr, ProcessStatus(0), fill("-", length(fieldnames(log_nt))-3)..., "$(truncate_string(string(e)))"))
                    else
                        throw(ErrorException("No logging for $(itr)"))
                    end
                    return itr => (processed = false, log = log_itr)
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
                if !ParallelProcessingTools.wouldwait(t)
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

    # finish!(p)
    flush(stdout)
    Base.exit_on_sigint(true)

    return result
end