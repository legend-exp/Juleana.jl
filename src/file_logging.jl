# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

const LOG_LEVELS = Dict("debug" => Logging.Debug, "info" => Logging.Info, "warn" => Logging.Warn, "error" => Logging.Error)

"""
    parse_log_level(level::AbstractString)

Return the `Logging.LogLevel` named by `level`: `"debug"`, `"info"`, `"warn"` or
`"error"`. Throw an `ArgumentError` for any other value.

# Examples
```jldoctest
julia> Juleana.parse_log_level("warn")
Warn
```
"""
function parse_log_level(level::AbstractString)
    haskey(LOG_LEVELS, level) ||
        throw(ArgumentError("processing_config: key `config.log_level` must be one of \"debug\", \"info\", \"warn\" or \"error\", got $(repr(level))"))
    return LOG_LEVELS[level]
end

# One record per entry: `<UTC time> <level> [<module>] <message>`, further message lines
# and `key = value` pairs indented below, and the source location for warnings and errors.
# An `exception = (exception, backtrace)` pair is shown with its backtrace.
function format_log_record(io::IO, log)
    print(io, Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sss\Z"), " ",
        rpad(string(log.level), 5), " [", log._module, "] ")
    lines = split(string(log.message), '\n')
    println(io, first(lines))
    for line in lines[2:end]
        println(io, "    ", line)
    end
    for (key, value) in log.kwargs
        # `showerror` shows the errors inside wrappers such as `CompositeException`
        text = key !== :exception ? string(value) : value isa Tuple{Exception,Any} ? sprint(showerror, value...) :
            value isa Exception ? sprint(showerror, value) : string(value)
        println(io, "    ", key, " = ", replace(text, '\n' => "\n        "))
    end
    log.level >= Logging.Warn && println(io, "    @ ", log.file, ":", log.line)
    return nothing
end

"""
    processing_logger(; log_file=nothing, log_level=Logging.Info, console_level=Logging.Info)

Build the logger that [`init_process`](@ref) installs.

- With `log_file`, records are appended to that file, one timestamped entry per record,
  and the file is flushed after every record. Progress bar records of ProgressLogging
  (see [`show_progress`](@ref)) are not written. `log_level = Logging.Debug` writes the
  records of level `Info` and above plus the debug records of the modules listed in the
  `JULIA_DEBUG` environment variable; any other level writes only the records at or above
  it.
- With `console_level` not `nothing`, records go to a `TerminalLogger` wrapped in an
  [`UnderscoreSafeLogger`](@ref). `console_level = Logging.Info` shows the debug
  records of the `JULIA_DEBUG` modules as well; a higher level shows only the records at
  or above it.

Throw an `ArgumentError` when neither sink is requested.
"""
function processing_logger(; log_file::Union{Nothing,AbstractString} = nothing,
        log_level::LogLevel = Logging.Info, console_level::Union{Nothing,LogLevel} = Logging.Info)
    isnothing(log_file) && isnothing(console_level) &&
        throw(ArgumentError("processing_logger: no log file and no console output requested"))
    # `JULIA_DEBUG` lets debug records of the listed modules pass every level check of the
    # composed loggers, so levels above debug are enforced on the record itself.
    at_least(level, logger) = level <= Logging.Debug ? logger : ActiveFilteredLogger(log -> log.level >= level, logger)
    sinks = AbstractLogger[]
    if !isnothing(console_level)
        console = UnderscoreSafeLogger(TerminalLogger(stderr, min(console_level, Logging.Info)))
        push!(sinks, console_level <= Logging.Info ? console : at_least(console_level, console))
    end
    if !isnothing(log_file)
        file = MinLevelLogger(FormatLogger(format_log_record, log_file; append = true), Logging.Info)
        # progress bars are for the terminal only
        no_bars = ActiveFilteredLogger(log -> !(log.message isa ProgressLogging.Progress), file)
        push!(sinks, at_least(log_level, no_bars))
    end
    return length(sinks) == 1 ? only(sinks) : TeeLogger(sinks...)
end

"""
    process_log_file(log_path::AbstractString)

Return the log file of the current process in the directory `log_path`: `head.log` on
the main process, `worker-<id>-<hostname>.log` on a worker.
"""
process_log_file(log_path::AbstractString) =
    joinpath(log_path, myid() == 1 ? "head.log" : "worker-$(myid())-$(gethostname()).log")
