function menu()        
    # main menu options
    options = ["Execute processors", "Reload processors", "Select periods", "Select runs", "Reload processing config", "Reset dependency graph", "Submit workers", "Refresh master reports", "Exit"]
    # main menu
    choice = try
        println()
        menu = RadioMenu(options, ctrl_c_interrupt=true)
        choice = request("Select action:", menu)
        println()
        choice
    catch e
        println()
        @error "Abort: $e"
        return
    end
    # reload all processors from files
    if choice == 5
        global l200, processing_config, runs, periods
        l200, processing_config, runs, periods = get_processingconfig()
        @info "Reloaded processing config"
        global process_status, p_process_status
        process_status, p_process_status = setup_dependency_graph(l200, processing_config, periods, runs)
        @info "Necessary reload of dependency graph"
    # redefine periods per user choice
    elseif choice == 3
        global periods
        try
            possible_periods = get_available_periods(l200)
            periods_menu = MultiSelectMenu(string.(possible_periods); selected=eachindex(possible_periods)[map(x -> x in periods, possible_periods)], ctrl_c_interrupt = true)
            selected_periods = collect(request("Select periods to be executed:", periods_menu))
            periods = possible_periods[selected_periods]
        catch e
            println()
            @error "Abort: $e"
            return
        end
        @info "Selected periods: $periods"
        global process_status, p_process_status
        process_status, p_process_status = setup_dependency_graph(l200, processing_config, periods, runs)
        @info "Reloaded dependency graph"
    elseif choice == 4
        global runs
        try
            tiers = [:raw, :jldsp, :jlevt]
            categories = [:cal, :phy]
            tier, cat = nothing, nothing
            for t in tiers
                for c in categories
                    if ispath(l200.tier[t, c])
                        tier = t
                        cat = c
                        break
                    end
                end
                if !isnothing(tier)
                    break
                end
            end
            possible_runs = if isnothing(tier) || isnothing(cat)
                @warn "No `DataRun` found for in `raw`, `jldsp` or `jlevt` neither for `cal` nor `phy`"
                []
            else
                if length(periods) == 0
                    @warn "No periods selected"
                    []
                else
                    if length(periods) > 1
                        @warn "More than one period selected, choosing first to get runs"
                    end
                    search_disk(DataRun, l200.tier[tier, cat, first(periods)])
                end
            end
            runs_menu = MultiSelectMenu(string.(possible_runs); selected=eachindex(possible_runs)[map(x -> x in runs, possible_runs)], ctrl_c_interrupt = true)
            selected_runs = collect(request("Select runs to be executed:", runs_menu))
            runs = possible_runs[selected_runs]
            if length(runs) == length(possible_runs)
                runs = "all"
                @info "All runs selected."
            end
        catch e
            println()
            @error "Abort: $e"
            return
        end
        @info "Selected periods: $periods"
        global process_status, p_process_status
        process_status, p_process_status = setup_dependency_graph(l200, processing_config, periods, runs)
        @info "Reloaded dependency graph"
    # reload processors from all processor files
    elseif choice == 2
        r = include.(filter(contains(r".jl$"), readdir(joinpath(dirname(@__DIR__), "processors/"); join=true)))
        @info "Reloaded processors: $r"
    # reload dependency graph
    elseif choice == 6
        global process_status, p_process_status
        process_status, p_process_status = setup_dependency_graph(l200, processing_config, periods, runs)
        @info "Reloaded dependency graph"
    # add workers according to slurm settings
    elseif choice == 7
        @async runworkers(runmode)
        @info "Submitted workers"
    elseif choice == 8
        refresh_master_reports(l200)
    # execute processing steps
    elseif choice == 1
        Base.exit_on_sigint(false)
        try
            execute_processors()
        catch e
            e = ParallelProcessingTools.onlyfirst_exception(e)
            if e isa TaskFailedException
                e = e.task.exception
            end
            @error "Error in `execute_processors`: $(truncate_string(string(e)))"
        end
        Base.exit_on_sigint(true)
    end
end

function execute_processors()
    # create menus for processing steps
    process_steps, p_process_steps, additional_args = try
        steps_menu = MultiSelectMenu(String.(processing_config.possible_process_steps), ctrl_c_interrupt = true)
        p_steps_menu = MultiSelectMenu(String.(processing_config.p_possible_process_steps), ctrl_c_interrupt = true)
        additional_args = ["reprocess", "no-reprocess", "check_dependencies", "check_report"]
        additional_args_menu = MultiSelectMenu(additional_args, ctrl_c_interrupt = true)
    
        # processing steps menu to select and deselect
        process_steps = processing_config.possible_process_steps[collect(request("Select processing steps to be executed:", steps_menu))]
        process_steps = sort(process_steps, by = s -> processing_config.processors[s].rank)
        println()
        println()
        p_process_steps = processing_config.p_possible_process_steps[collect(request("Select partition processing steps to be executed:", p_steps_menu))]
        p_process_steps = sort(p_process_steps, by = s -> processing_config.p_processors[s].rank)
        println()
        println()
        additional_args = additional_args[collect(request("Select additional args:", additional_args_menu))]
        println()
        println()
        process_steps, p_process_steps, additional_args
    catch e
        println()
        @error "Abort: $e"
        return
    end
    
    # execute steps one after each other without period and run parallelization
    if isempty(process_steps) && isempty(p_process_steps)
        @warn "No processing steps selected"
        return
    else
        # only inspect the reports of the selected steps and return without processing
        if "check_report" in additional_args
            check_reports(process_steps, p_process_steps)
            return
        end

        if "check_dependencies" in additional_args
            # set all process steps to true in case selection, false otherwise
            for p in processing_config.possible_process_steps
                if p in process_steps
                    processing_config.processors[p].enabled = true
                else
                    processing_config.processors[p].enabled = false
                end
            end
            # set all p process steps to true in case selection, false otherwise
            for p in processing_config.p_possible_process_steps
                if p in p_process_steps
                    processing_config.p_processors[p].enabled = true
                else
                    processing_config.p_processors[p].enabled = false
                end
            end
            # setup dependency graph
            global process_status, p_process_status
            process_status, p_process_status = setup_dependency_graph(l200, processing_config, periods, runs)
        end

        @sync begin

            if !isempty(process_steps)
                # process periods
                Threads.@spawn begin
                    for period in periods
                        Threads.@spawn begin
                            @info "Process period $period"

                            # select runs to process
                            processable_runs = sort(collect(keys(last(first(process_status[period])))))

                            # process runs
                            for run in processable_runs

                                Threads.@spawn begin
                                    # iterate through process steps
                                    @info "Process run $run"
                                    for process in process_steps
                                        @info "$(string(process))"
                                        flush(stdout)

                                        # check if run is a analysis run if switched on
                                        if processing_config.analysis_runs_only && !is_analysis_run(l200, (period, run, processing_config.processors[process].category))
                                            @warn "$period-$run-$(processing_config.processors[process].category) is not a analysis run, skip $(string(process))"
                                            continue
                                        elseif !is_lrun(l200, (period, run, processing_config.processors[process].category))
                                            @warn "$period-$run-$(processing_config.processors[process].category) is not in runinfo, skip $(string(process))"
                                            continue
                                        end
                                        
                                        # check if process has dependencies
                                        if "check_dependencies" in additional_args
                                            # get all dependencies of process from config
                                            dependencies = Symbol.(processing_config.processors[process].dependencies)
                                            # add all smaller ranks to list of dependencies and remove duplicates
                                            dependencies = unique(vcat([processing_config.p_possible_process_steps[1:findfirst(processing_config.p_possible_process_steps .== dep)] for dep in dependencies]...))
                                            # check if dependencies are met
                                            if !all([p_process_status[period][dep] for dep in dependencies])
                                                @warn "Dependencies not yet met for $(string(process))"
                                            end
                                            # if not met wait till met
                                            while !all([p_process_status[period][dep] for dep in dependencies])
                                                sleep(10)
                                            end
                                        end

                                        # run process
                                        kwargs = NamedTuple([(k, v) for (k, v) in pairs(processing_config.processors[process].kwargs)])
                                        if "reprocess" in additional_args
                                            kwargs = merge(kwargs, (reprocess = true, ))
                                        end
                                        if "no-reprocess" in additional_args
                                            kwargs = merge(kwargs, (reprocess = false, ))
                                        end
                                        getfield(Main, process)(processing_config, l200, period, run,; kwargs...)
                                        flush(stdout)

                                        # update process status
                                        process_status[period][process][run] = true

                                        @info "Finished $period-$run $(string(process))"
                                    end
                                end
                            end
                        end
                    end
                end
            end

            if !isempty(p_process_steps)
                # process partitions 
                Threads.@spawn begin
                    for period in periods

                        @info "Process partitions in $period"

                        Threads.@spawn begin
                            # iterate through process steps
                            for process in p_process_steps
                                @info "$(string(process))"

                                if "check_dependencies" in additional_args
                                    # check if p process has dependencies
                                    dependencies = Symbol.(processing_config.p_processors[process].dependencies)
                                    # combined periods and actual period to check for dependency globally
                                    combined_periods = unique(push!(get_partition_combined_periods(l200, period), period))
                                    # add all smaller ranks to list of dependencies and remove duplicates
                                    dependencies = unique(vcat([processing_config.possible_process_steps[1:findfirst(processing_config.possible_process_steps .== dep)] for dep in dependencies]...))
                                    if !all([all(values(process_status[period][dep])) for dep in dependencies for period in combined_periods])
                                        @warn "Dependencies not yet met for $(string(process))"
                                    end
                                    while !all([all(values(process_status[period][dep])) for dep in dependencies])
                                        sleep(10)
                                    end
                                end
                                
                                # get kwargs
                                kwargs = NamedTuple([(k, v) for (k, v) in pairs(processing_config.p_processors[process].kwargs)])
                                # make sure that only the first period in each partitions are processed
                                kwargs = merge(kwargs, (only_first_period = DataPeriod(period.no - 1) in periods, ))
                                if "reprocess" in additional_args
                                    kwargs = merge(kwargs, (reprocess = true, ))
                                end
                                if "no-reprocess" in additional_args
                                    kwargs = merge(kwargs, (reprocess = false, ))
                                end
                                # process partitions
                                has_lower_period_depedency = getfield(Main, process)(processing_config, l200, period,; kwargs...)
                                
                                # if process finished but depends on lower period dependency wait till met
                                if has_lower_period_depedency && "check_dependencies" in additional_args
                                    if !p_process_status[DataPeriod(period.no - 1)][process]
                                        @warn "Processed $period $(string(process)) but depends on $(DataPeriod(period.no - 1)) --> wait"
                                    end
                                    while !p_process_status[DataPeriod(period.no - 1)][process]
                                        sleep(10)
                                    end
                                end
                                # update process status
                                p_process_status[period][process] = true

                                @info "Finished $period $(string(process))"
                            end
                        end
                    end
                end
            end
        end
        refresh_master_reports(l200)
    end
end

"""
    get_report_status(text::AbstractString)

Read the saved processor status from Markdown report text; return `nothing` if unavailable.
"""
function get_report_status(text::AbstractString)
    status = match(r"(?m)^\|\h*Processor Status\h*\|\r?\n\|[ :\-]+\|\r?\n\|([^|\r\n]*)\|", text)
    isnothing(status) && return nothing
    label = strip(replace(status[1], r"<[^>]*>" => ""))
    return get((Success = process_succeeded, Warning = process_warning, Failure = process_failed), Symbol(label), nothing)
end

"""
    refresh_master_reports(l200)

Rebuild `<jlrep>/master/<processor>.md` from all available run and partition reports,
independently of the selected periods, runs, or enabled processors. Each overview
shows the saved processor status, processing date, and a link to the detailed report.
Reports without a saved master status appear as Unknown.
"""
function refresh_master_reports(l200)
    master_folder = data_path(l200.tier, "jlrep", "master")
    reports = Dict{String, Vector{NamedTuple}}()
    unknown = """<span style="color:gray">Unknown</span>"""
    folders = NamedTuple[]
    # Run reports: jlrep/rreport/<category>/<period>/<run>.
    run_reports = data_path(l200.tier, "jlrep", "rreport")
    if isdir(run_reports)
        for category in search_disk(DataCategory, run_reports),
            period in search_disk(DataPeriod, data_path(l200.tier, "jlrep", "rreport", string(category))),
            run in search_disk(DataRun, data_path(l200.tier, "jlrep", "rreport", string(category), string(period)))
            push!(folders, (Path = get_rreportfolder(l200, period, run, category), Period = period, Run = run, Category = category))
        end
    end
    # Partition reports: jlrep/preport/<period>/<category>, without a run.
    partition_reports = data_path(l200.tier, "jlrep", "preport")
    if isdir(partition_reports)
        for period in search_disk(DataPeriod, partition_reports),
            category in search_disk(DataCategory, data_path(l200.tier, "jlrep", "preport", string(period)))
            push!(folders, (Path = get_preportfolder(l200, period, category), Period = period, Run = nothing, Category = category))
        end
    end
    for folder in folders, filename in readdir(folder.Path; join=true)
        endswith(filename, ".md") || continue
        # LDM filenames: setup-period-run-category-processor.md (5 parts), or without run (4).
        # Limit the split so hyphens inside a processor name remain part of that name.
        n_parts = isnothing(folder.Run) ? 4 : 5
        parts = split(chopsuffix(basename(filename), ".md"), '-'; limit=n_parts)
        length(parts) == n_parts || continue
        processor = (isnothing(folder.Run) ? "p_process_" : "process_") * last(parts)
        text = read(filename, String)
        status = get_report_status(text)
        processing_date = match(r"(?m)^(?:Date|Time) of processing:\h*(.+)$", text)
        row = (Setup = first(parts), Period = folder.Period, Category = folder.Category,
               var"Processor Status" = isnothing(status) ? unknown : status, var"Processing Date" = isnothing(processing_date) ? "-" : strip(processing_date[1]),
               Report = "[open report]($(relpath(filename, master_folder)))")
        if !isnothing(folder.Run)
            row = merge((Setup = row.Setup, Period = folder.Period, Run = folder.Run), row)
        end
        push!(get!(reports, processor, NamedTuple[]), row)
    end
    mkpath(master_folder)
    filenames = map(sort(collect(keys(reports)))) do processor
        rows = reports[processor]
        sort!(rows; by = row -> (row.Setup, row.Period, get(row, :Run, DataRun(0)), row.Category))
        report = lreport("# `$processor`", "Refresh: `julia main.jl -c <config> --refresh-master-reports` or interactive menu → **Refresh master reports**.",
                         "Last refreshed: $(now())", rows)
        filename = data_path(l200.tier, "jlrep", "master", "$processor.md")
        writelreport(filename, report)
        filename
    end
    @info "Refreshed $(length(filenames)) master reports in $master_folder"
    return filenames
end

# read a report and return the number of result entries, the number of failed entries and
# the failures as detector => error. An entry is a table row: per detector and filter type
# for the fit reports, per filekey for the dsp reports - so for a dsp report the failure
# count stays in filekeys while the labels name the individual failed detectors of each row.
function get_report_failures(filename::AbstractString)
    header, previous, n_entries, n_failed, failures = String[], String[], 0, 0, Tuple{String, String}[]
    for line in eachline(filename)
        startswith(strip(line), "|") || continue
        cells = strip.(split(strip(strip(line), '|'), "|"))
        # a separator row marks the previous row as the header of a new table
        if all(c -> !isempty(c) && all(in((':', '-')), c), cells)
            header = previous
            continue
        end
        previous = cells
        # only tables with a status column hold results, the metadata table is skipped
        i_status = findfirst(isequal("Status"), header)
        (isnothing(i_status) || length(cells) != length(header)) && continue
        n_entries += 1
        occursin("Failure", replace(cells[i_status], r"<[^>]*>" => "")) || continue
        n_failed += 1
        # label the entry by detector, by the failed detectors of a dsp report or else by filekey
        i_det = findfirst(in(("Detector", "Failed Detectors")), header)
        labels = if isnothing(i_det) || cells[i_det] in ("", "-")
            [first(cells)]
        elseif header[i_det] == "Failed Detectors"
            [m.captures[1] for m in eachmatch(r"\"([^\"]+)\"", cells[i_det])]
        else
            [cells[i_det]]
        end
        # add the filter/energy type and, for partition reports, the partition to
        # distinguish several entries per detector; "-" cells carry no information
        i_type = findfirst(in(("Filter Type", "Energy Type")), header)
        i_part = findfirst(isequal("Partition"), header)
        suffix = join([cells[i] for i in (i_type, i_part) if !isnothing(i) && !(cells[i] in ("", "-"))], ", ")
        isempty(suffix) || (labels = labels .* " ($suffix)")
        # collect every error-like column: the fit reports have "Error", the aoe/lq cut
        # reports have "CalError" and "CutError" - matching on the substring covers all
        i_errs = findall(h -> occursin("Error", h), header)
        err = join([cells[i] for i in i_errs if !(cells[i] in ("", "-"))], " | ")
        append!(failures, [(l, err) for l in labels])
    end
    return n_entries, n_failed, failures
end

# Saved processor statuses govern the overview; result failures provide detector-level detail.
function check_reports(process_steps::Vector{Symbol}, p_process_steps::Vector{Symbol})
    colors = Dict(process_succeeded => :green, process_warning => :yellow, process_failed => :red)
    function check_report(label::String, filename::AbstractString, failed::Dict{String, Vector{String}}, errors::Dict{String, Vector{String}})
        if !isfile(filename)
            printstyled("  $(rpad(label, 11)) no report\n"; color = :light_black)
            return nothing
        end
        status = get_report_status(read(filename, String))
        status_label = isnothing(status) ? "Unknown" : sprint(show, MIME"text/plain"(), status)
        n_entries, n_failed, failures = get_report_failures(filename)
        printstyled("  $(rpad(label, 11)) $status_label"; color = get(colors, status, :light_black))
        println(" ($n_entries entries)")
        # Drop filter/partition suffixes when grouping failures by detector.
        for (det, err) in failures
            push!(get!(failed, first(split(det, " (")), String[]), label)
            isempty(err) || push!(get!(errors, first(split(det, " (")), String[]), err)
        end
        if n_failed > 0
            printstyled("      $n_failed of $n_entries entries failed: "; color = :red)
            println(truncate_string(join(unique(first.(failures)), ", "), 80))
        end
        return status
    end

    function check_summary(process::Symbol, statuses, failed::Dict{String, Vector{String}}, errors::Dict{String, Vector{String}})
        println("-"^110)
        counts = join(["$(sprint(show, MIME"text/plain"(), status)): $(count(isequal(status), statuses))" for status in (process_succeeded, process_warning, process_failed)], ", ")
        println("  Summary $process: $counts, Unknown/no report: $(count(isnothing, statuses))")
        if !isempty(failed)
            printstyled("  $(length(failed)) detector(s) with failed result entries\n"; color = :red)
            for det in sort(collect(keys(failed)))
                runs_failed = unique(failed[det])
                println("      $(rpad(det, 12)) $(lpad(length(runs_failed), 3)) run(s): $(truncate_string(join(runs_failed, ", "), 85))")
                for err in unique(get(errors, det, String[]))
                    println("      $(" "^12)      $(truncate_string(err, 100))")
                end
            end
        end
        println()
    end

    for process in process_steps
        report = Symbol("$(last(split(string(process), "process_")))")
        category = processing_config.processors[process].category
        printstyled("\n$(string(process)) ($category)\n"; bold = true)
        println("-"^110)
        failed, errors = Dict{String, Vector{String}}(), Dict{String, Vector{String}}()
        statuses = Union{Nothing, ProcessStatus}[]
        for period in periods
            for run in get_proccessable_runs(l200, period, runs)
                filename = get_rreportfilename(l200, l200.name, period, run, category, report)
                push!(statuses, check_report("$period-$run", filename, failed, errors))
            end
        end
        check_summary(process, statuses, failed, errors)
    end

    for process in p_process_steps
        report = Symbol("$(last(split(string(process), "process_")))")
        # Calibration partition processors omit the category in their configuration.
        category = get(processing_config.p_processors[process], :category, "cal")
        printstyled("\n$(string(process)) ($category)\n"; bold = true)
        println("-"^110)
        failed, errors = Dict{String, Vector{String}}(), Dict{String, Vector{String}}()
        statuses = Union{Nothing, ProcessStatus}[]
        for period in periods
            filename = get_preportfilename(l200, l200.name, period, category, report)
            push!(statuses, check_report("$period", filename, failed, errors))
        end
        check_summary(process, statuses, failed, errors)
    end
end
