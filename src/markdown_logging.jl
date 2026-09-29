import Logging: AbstractLogger, min_enabled_level, shouldlog, catch_exceptions, handle_message

# TerminalLogger parses string messages as Markdown. Escape underscores in plain
# text while leaving existing code spans and non-string reports untouched.
escape_log_underscores(message::AbstractString) = replace(message, r"(`+).*?\1|(?<!\\)_"s => m -> m == "_" ? "\\_" : m)

struct UnderscoreSafeLogger{L<:AbstractLogger} <: AbstractLogger
    inner::L
end

min_enabled_level(logger::UnderscoreSafeLogger) = min_enabled_level(logger.inner)
shouldlog(logger::UnderscoreSafeLogger, level, _module, group, id) = shouldlog(logger.inner, level, _module, group, id)
catch_exceptions(logger::UnderscoreSafeLogger) = catch_exceptions(logger.inner)

function handle_message(logger::UnderscoreSafeLogger, level, message, _module, group, id, file, line; kwargs...)
    safe_message = message isa AbstractString ? escape_log_underscores(message) : message
    handle_message(logger.inner, level, safe_message, _module, group, id, file, line; kwargs...)
end
