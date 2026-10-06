# Remote helper of the sync tool: lists and extracts the per-detector groups of
# LEGEND HDF5 files. It needs only HDF5 and ParallelProcessingTools; jobs are
# read from a TOML file and every result is one line of TOML on standard output.
#
#     julia --project=ENV extract.jl inspect JOBFILE [--jobs N]
#     julia --project=ENV extract.jl extract JOBFILE [--jobs N]
using Distributed
using HDF5
using ParallelProcessingTools
using TOML

const SCRIPT = abspath(@__FILE__)

# Groups and datasets are summed through their stored size; any other object
# (a named datatype) holds no data.
storage_bytes(dset::HDF5.Dataset) = Int(HDF5.API.h5d_get_storage_size(dset))
storage_bytes(group::HDF5.Group) = sum(name -> storage_bytes(group[name]), keys(group); init = 0)
storage_bytes(::Any) = 0

function inspect_file(path::String)::Tuple{Vector{String},Vector{Int}}
    h5open(path, "r") do f
        names = collect(String, keys(f))
        names, [storage_bytes(f[name]) for name in names]
    end
end

# The return type is concrete because `onworker` converts the remote result to
# the inferred return type.
# An existing destination that cannot be read as HDF5 stops the job; it is never
# overwritten silently. The result also carries the id of the process that ran it.
function extract_file(source::String, groups::Vector{String}, destination::String)::Tuple{Symbol,Int,Int}
    if isfile(destination)
        held = try
            h5open(destination, "r") do f
                haskey(attrs(f), "juleana_sync_groups") ? String.(attrs(f)["juleana_sync_groups"]) : String[]
            end
        catch err
            error(source, ": cannot read existing destination ", destination, ": ", sprint(showerror, err))
        end
        held == groups && mtime(source) <= mtime(destination) &&
            return (:skipped, Int(filesize(destination)), myid())
    end
    mkpath(dirname(destination))
    # The final name only ever holds a complete file, so an interrupted run
    # leaves nothing the skip rule above could mistake for a finished file.
    partial = destination * ".partial"
    try
        h5open(source, "r") do src
            h5open(partial, "w") do dst
                for group in groups
                    haskey(src, group) || error("group $group not found in $source")
                    HDF5.copy_object(src, group, dst, group)
                end
                attrs(dst)["juleana_sync_groups"] = groups
                attrs(dst)["juleana_sync_source"] = source
            end
        end
        mv(partial, destination; force = true)
    catch err
        rm(partial; force = true)
        # The message leads with the source so a failure on a worker names its file.
        error(source, ": ", sprint(showerror, err))
    end
    (:extracted, Int(filesize(destination)), myid())
end

# TOML's own encoder formats the values, so strings are escaped correctly.
toml_value(x) = chopprefix(strip(sprint(TOML.print, Dict("v" => x))), "v = ")

function emit(; fields...)
    println("r = {", join(("$k = $(toml_value(v))" for (k, v) in fields), ", "), "}")
    flush(stdout)
end

default_workers(nitems) = nitems < 4 ? 1 : min(8, nitems, Sys.CPU_THREADS ÷ 2)

function start_workers(n::Integer)
    ppt_worker_pool!(FlexWorkerPool(withmyid = false, label = "juleana-sync"))
    # The workers include this file to get its functions. The sentinel keeps the
    # entry point at the bottom from running there (and again in this process).
    @always_everywhere begin
        const LOADED_AS_LIBRARY = true
        include($SCRIPT)
    end
    runworkers(OnLocalhost(n = n))
    timedwait(() -> nprocs() > n, 300.0) == :ok ||
        error("only $(nprocs() - 1) of $n workers started within 300 s")
end

# Call `done(item, f(item...))` for every item, in the main process for `n <= 1`
# and on `n` workers otherwise. `n` consumer tasks take items from a channel, so
# at most `n` files are in flight; once one fails, no consumer takes another item.
# Files already written stay for a resumed run.
function run_items(done, f, items::Vector, n::Integer)
    if n <= 1
        for item in items
            done(item, f(item...))
        end
        return nothing
    end
    try
        start_workers(n)
        queue = Channel{eltype(items)}(length(items))
        foreach(item -> put!(queue, item), items)
        close(queue)
        failed = Threads.Atomic{Bool}(false)
        consumers = [Threads.@spawn(begin
                         for item in queue
                             failed[] && break
                             try
                                 done(item, onworker(f, item...))
                             catch
                                 failed[] = true
                                 rethrow()
                             end
                         end
                     end) for _ in 1:n]
        errors = Exception[]
        for task in consumers
            try
                wait(task)
            catch err
                push!(errors, err isa TaskFailedException ? err.task.exception : err)
            end
        end
        isempty(errors) || throw(first(errors))
    finally
        stopworkers()
    end
    nothing
end

function main(args)
    usage = "usage: extract.jl (inspect|extract) JOBFILE [--jobs N]"
    valid = length(args) in (2, 4) && args[1] in ("inspect", "extract") &&
            (length(args) == 2 ||
             (args[3] == "--jobs" && something(tryparse(Int, args[4]), 0) >= 1))
    valid || (println(stderr, usage); return 2)
    command, jobfile = args[1], args[2]
    jobs = length(args) == 4 ? parse(Int, args[4]) : 0
    try
        spec = TOML.parsefile(jobfile)
        if command == "inspect"
            files = String.(spec["files"])
            n = jobs > 0 ? min(jobs, length(files)) : default_workers(length(files))
            run_items(inspect_file, [(f,) for f in files], n) do item, (names, sizes)
                emit(event = "inspect", file = item[1], groups = names, bytes = sizes)
            end
        else
            list = [(String(j["source"]), String.(j["groups"]), String(j["destination"]))
                    for j in spec["job"]]
            n = jobs > 0 ? min(jobs, length(list)) : default_workers(length(list))
            io_lock = ReentrantLock()
            counts = Dict(:extracted => 0, :skipped => 0)
            run_items(extract_file, list, n) do item, (status, bytes, worker)
                Base.@lock io_lock begin
                    counts[status] += 1
                    emit(event = "file", source = item[1], destination = item[3],
                         status = String(status), groups = length(item[2]), bytes = bytes,
                         worker = worker)
                end
            end
            emit(event = "summary", files = length(list), extracted = counts[:extracted],
                 skipped = counts[:skipped], groups = sum(j -> length(j[2]), list; init = 0),
                 workers = n <= 1 ? 0 : n)
        end
    catch err
        println(stderr, "extract.jl: ", sprint(showerror, err))
        return 1
    end
    0
end

!@isdefined(LOADED_AS_LIBRARY) && abspath(PROGRAM_FILE) == SCRIPT && exit(main(ARGS))
