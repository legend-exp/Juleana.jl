# creates workers for the parallel processing and sets up the environment
function create_workers(workers, n_threads::Int; env_args::Vector{Pair{String, String}}=Pair{String, String}[])
    # config for MPP servers
    # push!(env_args, "JULIA_DEPOT_PATH" => "/depot")
    addprocs(workers, exeflags=`--threads=$(n_threads) --project=$(dirname(Pkg.project().path)) --heap-size-hint=10G`, topology=:master_worker, env=env_args) #, enable_threaded_blas=true)
    
    # Sanity check:
    worker_ids = Distributed.remotecall_fetch.(Ref(Distributed.myid), Distributed.workers())
    @assert length(worker_ids) == Distributed.nworkers()

    @info "$(Distributed.nworkers()) Julia worker processes active."
end

function create_workers(processing_config::PropDict)
    # number of threads
    n_threads = processing_config.processors.default.n_threads
    # number of local workers
    @info "Create $(processing_config.processors.default.local_workers) local workers for parallel processing"
    create_workers(processing_config.processors.default.local_workers, n_threads; env_args=processing_config.env_args_worker)
    # number of remote workers
    if !isempty(processing_config.processors.default.remote_workers)
        @info "Create remote workers: $(processing_config.processors.default.remote_workers)"
        create_workers([Tuple(p) for p in processing_config.processors.default.remote_workers], n_threads; env_args=processing_config.env_args_worker)
    end
    # check for precompile on the workers and debug flag
    worker_instantiate, worker_precompile, debug = processing_config.config.worker_instantiate, processing_config.config.worker_precompile, processing_config.config.debug
    @everywhere begin
        worker_instantiate, worker_precompile, debug = $worker_instantiate, $worker_precompile, $debug
    end
    # set up startup on each worker
    @everywhere include(joinpath(@__DIR__, "startup.jl"))
end

function get_workerPool(processing_config::PropDict, process::Symbol)
    n_workers = get(processing_config.processors[process], :n_workers, processing_config.processors.default.n_workers)
    if n_workers >= nworkers()
        wp = default_worker_pool()
        @info "Use default worker pool with $(length(wp)) workers."
        return wp
    else
        # make sure to distribute the workers evenly between all clusters
        if length(processing_config.processors.default.remote_workers) == 0
            return WorkerPool(2:n_workers+1)
        end
        cluster_workers_pids = [2:processing_config.processors.default.local_workers+1]
        for p in processing_config.processors.default.remote_workers
            last_pid = last(cluster_workers_pids[end])
            push!(cluster_workers_pids, last_pid+1:last_pid+last(p))
        end
        cluster_workers = append!([processing_config.processors.default.local_workers], [last(p) for p in processing_config.processors.default.remote_workers])
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


function parallel(iterator::AbstractArray, f::Function, log_nt::UnionAll, wpool::WorkerPool; timeout::Int=3600, retry::Bool=false)
    # prevent crash from Base
    Base.exit_on_sigint(false)

    # run parallel
    result =  @showprogress pmap(wpool, iterator; batch_size=1, retry_check=ifelse(retry, retry_check, nothing), retry_delays=ExponentialBackOff(n=3)) do itr
        try
            t_end = time() + timeout
            task = Threads.@spawn f(itr)
            # task = @async f(itr)
            while time() <= t_end && !istaskdone(task)
                sleep(0.1)
            end
            if !istaskdone(task)
                @debug "Timeout for $(itr)"
                @async Base.throwto(task, InterruptException())
                throw(ErrorException("Timeout for $(itr)"))
            end
            return itr => fetch(task)
        catch e
            if e isa TaskFailedException
                e = e.task.exception
            end
            @debug "Write Error log for $(itr): $e"
            # distinguish between ch and det logging or iterator logging
            log_itr = nothing
            if itr isa NamedTuple && haskey(itr, :channel) && haskey(itr, :detector)
                log_itr = log_nt((itr.channel, itr.detector, ProcessStatus(0), fill("-", length(fieldnames(log_nt))-4)..., "$e"))
            elseif itr isa FileKey
                log_itr = log_nt((itr, ProcessStatus(0), fill("-", length(fieldnames(log_nt))-3)..., "$e"))
            else
                throw(ErrorException("No logging for $(itr)"))
            end
            return itr => (processed = false, log = log_itr)
        end
    end

    Base.exit_on_sigint(true)

    return result
end