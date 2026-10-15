# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

const HISTORY_TITLE = "# Processing history"
const HISTORY_COLUMNS = ["Processor", "Level", "Category", "Period", "Run", "Outcome", "Started (UTC)", "Finished (UTC)",
    "Items ok/failed/not run"]
const HISTORY_TIME_FORMAT = dateformat"yyyy-mm-dd HH:MM:SS"

"""
    Juleana.history_path(l200::LegendData)

Return the path of the processing history of the data production `l200`: `history.md` in
the `jllog` tier.
"""
history_path(l200::LegendData) = joinpath(l200.tier[:jllog], "history.md")

format_history_time(t) = isnothing(t) ? "–" : Dates.format(t, HISTORY_TIME_FORMAT)
parse_history_time(s) = s == "–" ? nothing : DateTime(s, HISTORY_TIME_FORMAT)

"""
    Juleana.history_section(entry)

Return the Markdown section of the processing history for the processing run `entry`, a
`NamedTuple` with the fields of the entries [`Juleana.read_history`](@ref) returns.
"""
function history_section(entry)
    io = IOBuffer()
    println(io, "## ", format_history_time(entry.started), " UTC, ", entry.user, "@", entry.host, ": ", entry.outcome)
    println(io)
    println(io, "Finished: ", format_history_time(entry.finished), " UTC  ")
    println(io, "Log folder: ", entry.log_path)
    println(io)
    println(io, "| ", join(HISTORY_COLUMNS, " | "), " |")
    println(io, "|", repeat("---|", length(HISTORY_COLUMNS)))
    for s in entry.steps
        cells = [string(s.process), string(s.level), string(s.category), string(s.period),
            isnothing(s.run) ? "–" : string(s.run), string(s.outcome), format_history_time(s.started),
            format_history_time(s.finished), "$(s.done)/$(s.failed)/$(s.notrun)"]
        println(io, "| ", join(cells, " | "), " |")
    end
    return String(take!(io))
end

"""
    Juleana.append_history(path::AbstractString, entry)

Append the section of the processing run `entry` (see [`Juleana.history_section`](@ref)) to
the processing history file `path`, creating the file with its title if it does not
exist. The section is written with a single write.
"""
function append_history(path::AbstractString, entry)
    mkpath(dirname(path))
    text = (isfile(path) ? "\n" : HISTORY_TITLE * "\n\n") * history_section(entry)
    open(io -> write(io, text), path, "a")
    return path
end

"""
    Juleana.read_history(path::AbstractString)

Read the processing history file `path` written by [`Juleana.append_history`](@ref) and
return its processing runs in the order they were written, an empty vector if the file
does not exist. Each run is a `NamedTuple` `(; started, finished, user, host, outcome,
log_path, steps)` with `outcome` a `Symbol`, the times as `DateTime` (UTC, to the second)
or `nothing`,
and `steps` a vector of `(; process, level, category, period, run, outcome, started,
finished, done, failed, notrun)` with `period` a `DataPeriod` and `run` a `DataRun`, or
`nothing` for a partition-level step.

Throws an `ArgumentError` naming the file and line of a line that does not follow the
format.
"""
function read_history(path::AbstractString)
    entries = NamedTuple[]
    isfile(path) || return entries
    malformed(i, line) = throw(ArgumentError("read_history: line $i of $path does not follow the history format: $(repr(line))"))
    current = nothing
    flush!() = isnothing(current) || push!(entries, current)
    for (i, line) in enumerate(eachline(path))
        if startswith(line, "## ")
            flush!()
            m = match(r"^## (.+) UTC, (.+)@(.+): (\w+)$", line)
            isnothing(m) && malformed(i, line)
            current = (; started = parse_history_time(m[1]), finished = nothing, user = String(m[2]), host = String(m[3]),
                outcome = Symbol(m[4]), log_path = "", steps = NamedTuple[])
        elseif isnothing(current) || isempty(strip(line)) || line == HISTORY_TITLE
            isnothing(current) && !isempty(strip(line)) && line != HISTORY_TITLE && malformed(i, line)
        elseif startswith(line, "Finished: ")
            current = merge(current, (; finished = parse_history_time(strip(chopsuffix(chopprefix(line, "Finished: "), "UTC  ")))))
        elseif startswith(line, "Log folder: ")
            current = merge(current, (; log_path = String(chopprefix(line, "Log folder: "))))
        elseif startswith(line, "|")
            cells = strip.(split(strip(line, '|'), '|'))
            length(cells) == length(HISTORY_COLUMNS) || malformed(i, line)
            (cells == HISTORY_COLUMNS || all(c -> c == "---", cells)) && continue
            counts = tryparse.(Int, split(cells[9], '/'))
            (length(counts) == 3 && !any(isnothing, counts)) || malformed(i, line)
            push!(current.steps, (; process = Symbol(cells[1]), level = Symbol(cells[2]), category = Symbol(cells[3]),
                period = DataPeriod(cells[4]), run = cells[5] == "–" ? nothing : DataRun(cells[5]), outcome = Symbol(cells[6]),
                started = parse_history_time(cells[7]), finished = parse_history_time(cells[8]),
                done = counts[1], failed = counts[2], notrun = counts[3]))
        else
            malformed(i, line)
        end
    end
    flush!()
    return entries
end
