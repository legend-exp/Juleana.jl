module LegendLogging

using LegendDataManagement
using LegendDataManagement: DataSelector
using Unitful, Measurements, Dates, Formatting, Markdown
using TimerOutputs


# get and create log folder
function get_logfolder(data::LegendData, period::DataPeriodLike, run::DataRunLike, category::DataCategoryLike)
    log_folder = joinpath(data.tier[:jllog], "rlog", string(category), string(period), string(run))
    if isdir(log_folder)
        @debug("Log folder $log_folder already exists")
    else
        mkpath(log_folder)
    end
    log_folder
end


function get_logfolder(data::LegendData, filekey::FileKey)
    get_logfolder(data, filekey.period, filekey.run, filekey.category)
end

function get_logfolder(data::LegendData, partition::DataPartitionLike, category::DataCategoryLike)
    log_folder = joinpath(data.tier[:jllog], "plog", string(partition), string(category))
    if isdir(log_folder)
        @debug("Log folder $log_folder already exists")
    else
        mkpath(log_folder)
    end
    log_folder
end

function get_logfilename(data::LegendData, setup::ExpSetupLike, period::DataPeriodLike, run::DataRunLike, category::DataCategoryLike, process::Symbol)
    joinpath(get_logfolder(data, period, run, category), format("{}-{}-{}-{}-{}.md", string(setup), string(period), string(run), string(category), string(process)))
end

function get_logfilename(data::LegendData, filekey::FileKey, process::Symbol)
    get_logfilename(data, filekey.setup, filekey.period, filekey.run, filekey.category, process)
end

function get_totalTimer(result::NamedTuple)
    totalTimer = TimerOutput()
    for (key, value) in result
        if key isa Symbol && occursin("timer", string(key))
            merge!(totalTimer, value)
        end
    end
    totalTimer
end

"""
    MarkdownLogLine(identifier, success, error_msg, vals)

Create a MarkdownLogLine with the given identifier, success, error_msg and vals. The identifier can be a single DataSelector or a Vector of DataSelectors. The vals can be a Vector of Unitful quantities or a single Unitful quantity. If success is false, the error_msg must be given. If success is true, the error_msg is ignored.
If no error_msg is given, the error_msg is set to " - ".
If no vals are given, the vals are set to " - ". In case of a fail, an integer value in the constructor will result in empty vals of that length.
# Examples
```julia
julia> MarkdownLogLine(start_filekey(l200, (:p03, :r000, :cal)), true, [5, 1.0])
MarkdownLogLine(FileKey[FileKey("l200-p03-r000-cal-20230311T235840Z")], true, " - ", [5.0, 1.0])
julia> println(MarkdownLogLine(FileKey[FileKey("l200-p03-r000-cal-20230311T235840Z")], true, " - ", [5.0, 1.0]))
| l200-p03-r000-cal-20230311T235840Z | Success | 5.0 | 1.0 |  -  |
"""
struct MarkdownLogLine
    identifier::Vector{<:DataSelector}
    success::Bool
    error_msg::String
    vals::Vector{<:Unitful.RealOrRealQuantity}
end
export MarkdownLogLine

function MarkdownLogLine(identifier, success::Bool, vals::Vector{<:Unitful.RealOrRealQuantity})
    if !success
        throw(ArgumentError("Error message must be given if success is false"))
    end
    MarkdownLogLine(identifier, success, " - ", vals)
end

function MarkdownLogLine(identifier, success::Bool, error_msg::String, vals::Vector{<:Unitful.RealOrRealQuantity})
    if !isa(identifier, Vector)
        identifier = [identifier]
    end
    MarkdownLogLine(identifier, success, error_msg, vals)
end

function MarkdownLogLine(identifier, success::Bool, error_msg::String, n_vals::Int)
    if success        
        throw(ArgumentError("If no values given, success cannot be true"))
    end
    MarkdownLogLine(identifier, success, error_msg, Vector{Real}(undef, n_vals))
end

function _get_markdown_string(mdline::MarkdownLogLine)
    # create string with identifiers first
    strline = "| "
    for identifier in mdline.identifier
        strline *= "$(identifier) | "
    end
    # check if success
    strline *= if mdline.success
        raw"$${\color{green}Success}$$ | "
    else
        raw"$${\color{red}Failed}$$ | "
    end
    # add vals to log
    for idx in eachindex(mdline.vals)
        if isassigned(mdline.vals, idx)
            val = mdline.vals[idx]
        else
            val = " - "
        end
        strline *= "$(val) | "
    end
    # append error message
    strline *= "$(mdline.error_msg) |"
    strline
end

Base.print(io::IO, mdline::MarkdownLogLine) = print(io, _get_markdown_string(mdline))
Base.write(io::IO, mdline::MarkdownLogLine) = write(io, _get_markdown_string(mdline))


"""
    MarkdownLogger(file, log, header, footer)

Create a MarkdownLogger with the given file, log, header and footer. The file is the path to the markdown file. The log is a Vector of MarkdownLogLines. The header and footer are strings that are written to the file before and after the log.
The constructor can be used by initializing the MarkdownLogger with LegendData, FileKey and process the log should be created for. The header is then created automatically.
# Examples
```julia
julia> l200 = LegendData(:l200)
julia> MarkdownLogger(l200, FileKey("l200-p03-r000-cal-20230311T235840Z"), :dsp_cal)
MarkdownLogger("/remote/ceph/group/legendex/data/l200/julia/current/generated/jllog/rlog/cal/p03/r000/l200-p03-r000-cal-dsp_cal.md", MarkdownLogLine[], "# Main log \n\nTime of processing: Dates.DateTime(\"2024-01-31T11:12:14.206\")\n\n## DSP\nThis is the log for the dsp. The algorithm iterates through each file and process within each file each detector separate.\n\n# MetaData\n| Setup | Period | Run | Category |\n|-------|--------|-----|----------|\n|   l200  |   p03   |  r000 |    cal    |\n\n# Results\n| FileKey | Number of Detectors | Status | Total Time | Total Allocated | Error |\n|---------|---------------------|--------|------------|-----------------|-------|\n", "")
```
"""
mutable struct MarkdownLogger
    file::String
    log::Vector{MarkdownLogLine}
    header::String
    footer::String
end
export MarkdownLogger

function _get_mdheader(filekey::FileKey, process::Symbol)
    format(eval(Symbol(string(process)*"_header")), string(Dates.now()), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category))
end

function MarkdownLogger(data::LegendData, filekey::FileKey, process::Symbol, footer::String = "")
    MarkdownLogger(get_logfilename(data, filekey, process), MarkdownLogLine[], _get_mdheader(filekey, process), footer)
end

function MarkdownLogger(data::LegendData, filekey::FileKey, process::Symbol, result::NamedTuple; footer::Union{String, Symbol}=:none)
    footer_str = if typeof(footer) isa String
                    footer
                elseif footer == :timer
                    format(_timer_footer, get_totalTimer(result))
                elseif footer == :none
                    ""
                else
                    throw(ArgumentError("Footer must be a string, :timer or :none"))
                end
    MarkdownLogger(get_logfilename(data, filekey, process), [val.log for (key, val) in result], _get_mdheader(filekey, process), footer_str)
end

function _write_markdownlog(io::IO, logger::MarkdownLogger)
    write(io, logger.header)
    for mdline in logger.log
        write(io, mdline)
    end
    write(io, logger.footer)
end

function _get_logstring(logger::MarkdownLogger)
    join([logger.header, _get_markdown_string.(logger.log)..., logger.footer])
end

Base.write(io::IO, logger::MarkdownLogger) = _write_markdownlog(io, logger)
# TODO: Fix this to have also the IOBuffer in here, didn't get it to work for now
Base.print(io::IO, logger::MarkdownLogger) = print(io, Markdown.parse(_get_logstring(logger)))
# Base.println(logger::MarkdownLogger) = print(logger)

Base.convert(::Type{Markdown.MD}, logger::MarkdownLogger) = Markdown.parse(_get_logstring(logger))
Base.convert(::Type{AbstractString}, logger::MarkdownLogger) = _get_logstring(logger)

function Base.write(logger::MarkdownLogger)
    open(logger.file, "w") do io
        write(io, logger)
    end
end


const _timer_footer = """# Total Timing
```
{}
```
"""

const dsp_cal_header = """# Main log 

Time of processing: {}

## DSP
This is the log for the dsp. The algorithm iterates through each file and process within each file each detector separate.

# MetaData
| Setup | Period | Run | Category |
|-------|--------|-----|----------|
|   {}  |   {}   |  {} |    {}    |

# Results
| FileKey | Status | Number of Detectors | Total Time | Total Allocated | Error |
|---------|--------|---------------------|------------|-----------------|-------|
"""

end