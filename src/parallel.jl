# creates workers for the parallel processing and sets up the environment
function create_workers(n_workers::Int, n_threads::Int; env_args::Vector{Pair{String, String}}=Pair{String, String}[])
    # config for MPP servers
    # push!(env_args, "JULIA_DEPOT_PATH" => "/depot")
    addprocs(n_workers, exeflags=`--threads=$(n_threads) --project=$(dirname(Pkg.project().path)) --heap-size-hint=10G`, topology=:master_worker, env=env_args, enable_threaded_blas=true)
    
    # Sanity check:
    worker_ids = Distributed.remotecall_fetch.(Ref(Distributed.myid), Distributed.workers())
    @assert length(worker_ids) == Distributed.nworkers()

    @info "$(Distributed.nworkers()) Julia worker processes active."
end

function create_workers(processing_config::PropDict, process::Symbol)
    n_workers = get(processing_config.processors[process], :n_workers, processing_config.processors.default.n_workers)
    n_threads = get(processing_config.processors[process], :n_threads, processing_config.processors.default.n_threads)
    @info "Creating $(n_workers) workers with $(n_threads) threads each."
    create_workers(n_workers, n_threads; env_args=processing_config.env_args_worker)
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
    n_threads = get(processing_config.processors[process], :n_threads, processing_config.processors.default.n_threads)
    if n_workers <= nworkers()
        return WorkerPool(2:n_workers+1)
    else
        return WorkerPool(2:nworkers()+1)
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
    result =  @showprogress pmap(iterator, wpool; batch_size=1, retry_check=ifelse(retry, retry_check, nothing), retry_delays=ExponentialBackOff(n=3)) do itr
        try
            t_end = time() + timeout
            # task = Threads.@spawn f(itr)
            task = @async f(itr)
            while time() <= t_end && !istaskdone(task)
                sleep(0.1)
            end
            if !istaskdone(task)
                @debug "Timeout for $(ifelse(haskey(itr, :detector), itr.detector, itr))"
                @async Base.throwto(task, InterruptException())
                throw(ErrorException("Timeout for $(ifelse(haskey(itr, :detector), itr.detector, itr))"))
            end
            return itr => fetch(task)
        catch e
            if e isa TaskFailedException
                e = e.task.exception
            end
            @debug "Write Error log for $(ifelse(haskey(itr, :detector), itr.detector, itr)): $e"
            # distinguish between ch and det logging or iterator logging
            log_itr = nothing
            if haskey(itr, :channel) && haskey(itr, :detector)
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
