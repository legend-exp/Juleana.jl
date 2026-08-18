# Serial debug-rerun machinery for `rerun_failed` (see src/interactive.jl).
# This file is included on the driver and on the workers (via @always_everywhere in
# startup.jl): everything here is inert unless DEBUG_RERUN[] is set, and only
# rerun_failed() on the driver ever sets it.

# thrown by the serial parallel() branch after diagnosing the matched items so the
# processor aborts before it can write pars/plots/reports built from filtered results
struct DebugAbort <: Exception
    process::Symbol
    n_matched::Int
end

# one full exception chain, captured while the error was still being handled
struct DebugCapture
    item::Any               # iterator item being processed, nothing outside parallel
    when::DateTime
    stack::Base.ExceptionStack
end

mutable struct DebugRerunState
    process::Symbol
    detectors::Set{String}                  # failed detectors from the reports
    partitions::Dict{String, Set{String}}   # detector => partitions; absent/empty = all
    io::IO                                  # verbose log sink, written through per capture
    task::Task                              # only capture exceptions raised in this task
    current_item::Any
    captures::Vector{DebugCapture}
    failed_rows::Vector{Any}                # ProcessStatus(0) rows returned by the closures
    matched_any::Bool
end
DebugRerunState(process::Symbol, detectors::Set{String}, partitions::Dict{String, Set{String}}, io::IO) =
    DebugRerunState(process, detectors, partitions, io, current_task(), nothing, DebugCapture[], Any[], false)

const DEBUG_RERUN = Ref{Union{Nothing, DebugRerunState}}(nothing)

# a zero-match stage this small is executed for real instead of skipped: auxiliary
# stages like the pulser stage of process_hit_cal produce files the main stage reads
const DEBUG_PASSTHROUGH_MAX_ITEMS = 2

_debug_label(itr) = itr isa NamedTuple && haskey(itr, :detector) ?
    string(itr.detector) * (haskey(itr, :partition) ? " ($(itr.partition))" : "") : string(itr)
_debug_label(::Nothing) = "processor level (outside parallel)"

function _debug_matches(st::DebugRerunState, itr)
    itr isa NamedTuple && haskey(itr, :detector) || return false
    det = string(itr.detector)
    det in st.detectors || return false
    haskey(itr, :partition) || return true
    parts = get(st.partitions, det, nothing)
    return isnothing(parts) || isempty(parts) || string(itr.partition) in parts
end

# called from truncate_error, i.e. from inside the catch blocks of the processors,
# where Base.current_exceptions() still holds the original exception and backtrace
# underneath any rethrown wrapper. Must stay a cheap no-op when inactive.
function _debug_capture()
    st = DEBUG_RERUN[]
    isnothing(st) && return nothing
    current_task() === st.task || return nothing
    stack = Base.current_exceptions()
    isempty(stack) && return nothing
    push!(st.captures, DebugCapture(st.current_item, Dates.now(), stack))
    _write_capture(st.io, last(st.captures), length(st.captures))
    return nothing
end

# the chain is ordered oldest to most recent: entry [1] is the root cause, the last
# entry is the wrapper text that ends up in the report
function _write_capture(io::IO, cap::DebugCapture, n::Int)
    println(io, "\n", "="^100)
    println(io, "## capture $n at $(cap.when) — item: $(_debug_label(cap.item)) — exception chain of length $(length(cap.stack))")
    for (i, entry) in enumerate(cap.stack)
        println(io, "\n-- exception [$i]", i == 1 ? " (root cause)" : " (wrapped around the previous one)")
        showerror(io, entry.exception)
        println(io)
        Base.show_backtrace(IOContext(io, :color => false, :limit => true, :displaysize => (24, 240)), entry.backtrace)
        println(io)
    end
    flush(io)
end

# innermost exception plus the first frame in LEGEND/Juleana code, for the REPL summary
function _root_cause(stack::Base.ExceptionStack)
    isempty(stack) && return nothing, nothing
    root = first(stack)
    frames = Base.stacktrace(root.backtrace)
    isempty(frames) && return root.exception, nothing
    # never point at the debug machinery itself, it is part of every serial backtrace
    i = findfirst(fr -> occursin(r"Legend|Juleana|processors", string(fr.file)) && !endswith(string(fr.file), joinpath("src", "debug.jl")), frames)
    # fall back to the first frame outside base julia (base files print as ./file.jl or
    # live under share/julia), then to the innermost frame
    if isnothing(i)
        i = findfirst(fr -> !startswith(string(fr.file), "./") && !occursin("share/julia", string(fr.file)) && !endswith(string(fr.file), joinpath("src", "debug.jl")), frames)
    end
    return root.exception, frames[isnothing(i) ? 1 : i]
end

# best capture per item: several fire per failure (inner @error, outer catch), the
# longest chain carries the most context
function _best_captures(st::DebugRerunState)
    best = Dict{Any, DebugCapture}()
    for c in st.captures
        b = get(best, c.item, nothing)
        if isnothing(b) || length(c.stack) > length(b.stack)
            best[c.item] = c
        end
    end
    return best
end

# replica of the worker catch in parallel() so pass-through stages return the same
# log rows the report writer expects
function _debug_error_log_row(log_nt::UnionAll, itr, e)
    if e isa TaskFailedException
        e = e.task.exception
    end
    if itr isa NamedTuple && haskey(itr, :channel) && haskey(itr, :detector)
        if haskey(itr, :partition)
            return log_nt((itr.detector, itr.channel, itr.partition, ProcessStatus(0), fill("-", length(fieldnames(log_nt))-5)..., "$(truncate_string(string(e)))"))
        else
            return log_nt((itr.detector, itr.channel, ProcessStatus(0), fill("-", length(fieldnames(log_nt))-4)..., "$(truncate_string(string(e)))"))
        end
    elseif itr isa FileKey
        return log_nt((itr, ProcessStatus(0), fill("-", length(fieldnames(log_nt))-3)..., "$(truncate_string(string(e)))"))
    else
        throw(ErrorException("No logging for $(itr)"))
    end
end

# collect the failed rows a closure returned without throwing (most closures catch
# per stage and only mark the log row) so the summary can cross-check the captures
function _debug_collect_failed_rows!(st::DebugRerunState, itr, res)
    res isa NamedTuple && haskey(res, :log) || return nothing
    rows = res.log isa AbstractDict ? collect(values(res.log)) : [res.log]
    for row in rows
        if row isa NamedTuple && haskey(row, :Status) && row.Status == ProcessStatus(0)
            push!(st.failed_rows, (item = itr, row = row))
        end
    end
    return nothing
end

# serial replacement for the worker dispatch in parallel(): run the matched items in
# the driver task itself so the truncate_error hook sees the full exception chains
function debug_serial_parallel(st::DebugRerunState, iterator::AbstractArray, f::Function, log_nt::UnionAll; process_name::String="")
    sel = [itr for itr in iterator if _debug_matches(st, itr)]
    if isempty(sel)
        if length(iterator) <= DEBUG_PASSTHROUGH_MAX_ITEMS
            @info "[debug rerun] $process_name: no matching item, running the $(length(iterator))-item auxiliary stage for real"
            println(st.io, "\n# stage $process_name: no matching items, ran all $(length(iterator)) item(s) for real (auxiliary stage)")
            flush(st.io)
            return map(collect(iterator)) do itr
                st.current_item = itr
                try
                    itr => f(itr)
                catch e
                    push!(st.captures, DebugCapture(itr, Dates.now(), Base.current_exceptions()))
                    _write_capture(st.io, last(st.captures), length(st.captures))
                    itr => (processed = false, log = _debug_error_log_row(log_nt, itr, e))
                finally
                    st.current_item = nothing
                end
            end
        end
        @info "[debug rerun] $process_name: 0 of $(length(iterator)) items match — passing this stage through empty"
        println(st.io, "\n# stage $process_name: no matching items ($(length(iterator)) total) — passed through empty")
        flush(st.io)
        return Pair[]
    end
    st.matched_any = true
    println(st.io, "\n# stage $process_name: running $(length(sel)) matched item(s) serially in the driver")
    flush(st.io)
    for (i, itr) in enumerate(sel)
        label = _debug_label(itr)
        @info "[debug rerun] ($i/$(length(sel))) $label — serial run for full logs and exception chains"
        st.current_item = itr
        t_start = time()
        try
            _debug_collect_failed_rows!(st, itr, f(itr))
        catch e
            # the closure let the exception escape: capture the chain here instead
            push!(st.captures, DebugCapture(itr, Dates.now(), Base.current_exceptions()))
            _write_capture(st.io, last(st.captures), length(st.captures))
        finally
            st.current_item = nothing
        end
        @info "[debug rerun] $label finished in $(round(time() - t_start, digits=1)) s"
    end
    # diagnosis done: abort the processor before it writes pars/reports from filtered results
    throw(DebugAbort(st.process, length(sel)))
end
