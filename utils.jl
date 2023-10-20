function create_workers(n_workers::Int64)
    # config for MPP servers
    addprocs(n_workers, exeflags=`--threads=4 --project=$(dirname(Pkg.project().path)) --heap-size-hint=10G`, env=["JULIA_CPU_TARGET"=>"generic"], topology=:master_worker)#, enable_threaded_blas=true)

    # Sanity check:
    worker_ids = Distributed.remotecall_fetch.(Ref(Distributed.myid), Distributed.workers())
    @assert length(worker_ids) == Distributed.nworkers()

    @info "$(Distributed.nworkers()) Julia worker processes active."
end