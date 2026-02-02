function setdefaults(directory::AbstractString)
    LegendSpecFits.set_timelimit(180.0)

    # pin threads
    pinthreads_auto()

    global_logger(TerminalLogger())
    include(joinpath(directory,"log_texts.jl"))

    GC.gc()
end
