# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

"""
    menu(session::DataflowSession)

Show the interactive dataflow menu, perform the selected action on `session`, and
return. The actions are:

1. Execute processors: select run and partition processors and options, then run them
   (or only inspect their reports with `check_report`).
2. Select periods, 3. Select runs: change the selection and rebuild the dependency graph.
4. Reload processing config: read the config file again with the original command line
   options and rebuild the steps and the dependency graph.
5. Reset dependency graph: rebuild the dependency graph for the enabled steps.
6. Submit workers: start workers for the configured run mode.
7. Exit: return without action.

Processor functions are package code; with Revise loaded, edits to `src/processors/`
take effect at the next menu call.
"""
function menu(session::DataflowSession)
    # main menu options
    options = ["Execute processors", "Select periods", "Select runs", "Reload processing config", "Reset dependency graph", "Submit workers", "Exit"]
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
    if choice == 1
        Base.exit_on_sigint(false)
        try
            execute_processors(session)
        catch e
            e = onlyfirst_exception(e)
            if e isa TaskFailedException
                e = e.task.exception
            end
            @error "Error in `execute_processors`: $(truncate_string(string(e)))"
        end
        Base.exit_on_sigint(true)
    # redefine periods per user choice
    elseif choice == 2
        try
            possible_periods = available_periods(session.l200)
            periods_menu = MultiSelectMenu(string.(possible_periods); selected=eachindex(possible_periods)[map(x -> x in session.periods, possible_periods)], ctrl_c_interrupt = true)
            selected_periods = collect(request("Select periods to be executed:", periods_menu))
            session.periods = possible_periods[selected_periods]
        catch e
            println()
            @error "Abort: $e"
            return
        end
        @info "Selected periods: $(session.periods)"
        reset_dependency_graph!(session)
        @info "Reloaded dependency graph"
    elseif choice == 3
        try
            possible_runs = if isempty(session.periods)
                @warn "No periods selected"
                DataRun[]
            else
                if length(session.periods) > 1
                    @warn "More than one period selected, choosing first to get runs"
                end
                available_runs(session.l200, first(session.periods))
            end
            runs_menu = MultiSelectMenu(string.(possible_runs); selected=eachindex(possible_runs)[map(x -> isnothing(session.runs) || x in session.runs, possible_runs)], ctrl_c_interrupt = true)
            selected_runs = collect(request("Select runs to be executed:", runs_menu))
            session.runs = possible_runs[selected_runs]
            if length(session.runs) == length(possible_runs)
                session.runs = nothing
                @info "All runs selected."
            end
        catch e
            println()
            @error "Abort: $e"
            return
        end
        @info "Selected periods: $(session.periods)"
        reset_dependency_graph!(session)
        @info "Reloaded dependency graph"
    # reload the config file with the original command line options
    elseif choice == 4
        l200, config, periods = setup_processing(session.args)
        check_processor_kwargs(config)
        session.l200, session.config, session.periods, session.runs = l200, config, periods, config.runs
        session.run_steps, session.partition_steps = selected_steps(config)
        @info "Reloaded processing config"
        reset_dependency_graph!(session)
        @info "Necessary reload of dependency graph"
    elseif choice == 5
        reset_dependency_graph!(session)
        @info "Reloaded dependency graph"
    # add workers according to the run mode settings
    elseif choice == 6
        errormonitor(@async runworkers(runprocs_mode(session.config)))
        @info "Submitted workers"
    end
    return nothing
end

function execute_processors(session::DataflowSession)
    # create menus for processing steps
    # `run_steps`/`partition_steps` are local names here, so read the step lists from the tables.
    possible_steps = _sorted_steps(session.config.processors, false)
    possible_p_steps = _sorted_steps(session.config.p_processors, false)
    run_steps, partition_steps, additional_args = try
        steps_menu = MultiSelectMenu(String.(possible_steps), ctrl_c_interrupt = true)
        p_steps_menu = MultiSelectMenu(String.(possible_p_steps), ctrl_c_interrupt = true)
        additional_args = ["reprocess", "no-reprocess", "check_dependencies", "check_report"]
        additional_args_menu = MultiSelectMenu(additional_args, ctrl_c_interrupt = true)

        # processing steps menu to select and deselect
        # `possible_steps` is sorted by rank, so sorted indices keep the rank order
        run_steps = possible_steps[sort!(collect(request("Select processing steps to be executed:", steps_menu)))]
        println()
        println()
        partition_steps = possible_p_steps[sort!(collect(request("Select partition processing steps to be executed:", p_steps_menu)))]
        println()
        println()
        additional_args = additional_args[collect(request("Select additional args:", additional_args_menu))]
        println()
        println()
        run_steps, partition_steps, additional_args
    catch e
        println()
        @error "Abort: $e"
        return
    end

    if isempty(run_steps) && isempty(partition_steps)
        @warn "No processing steps selected"
        return
    else
        # only inspect the reports of the selected steps and return without processing
        if "check_report" in additional_args
            check_reports(session, run_steps, partition_steps)
            return
        end

        if "check_dependencies" in additional_args
            # only the selected steps start as unfinished in the dependency graph
            session.periods, session.run_status, session.partition_status = setup_dependency_graph(
                session.l200, session.config, session.periods, session.runs, run_steps, partition_steps)
        end

        if "reprocess" in additional_args && "no-reprocess" in additional_args
            @error "Select only one of `reprocess` and `no-reprocess`"
            return
        end
        reprocess = "reprocess" in additional_args ? true : "no-reprocess" in additional_args ? false : nothing
        run_processing(session.config, session.l200, session.periods, run_steps, partition_steps,
            session.run_status, session.partition_status;
            check_dependencies = "check_dependencies" in additional_args, reprocess)
    end
end

# read a report and return the number of result entries, the number of failed entries and
# the failures as detector => error. An entry is a table row: per detector and filter type
# for the fit reports, per filekey for the dsp reports - so for a dsp report the failure
# count stays in filekeys while the labels name the individual failed detectors of each row.
function report_failures(filename::AbstractString)
    header, previous, n_entries, n_failed, failures = String[], String[], 0, 0, Tuple{String, String}[]
    for line in eachline(filename)
        # only markdown table rows are of interest
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

"""
    check_reports(session::DataflowSession, run_steps, partition_steps)

Print, for every step in `run_steps` (run level) and `partition_steps` (partition
level), one line per report of the session's periods and runs with its failed entries,
followed by a summary of the failed detectors and their errors.
"""
function check_reports(session::DataflowSession, run_steps::AbstractVector{Symbol}, partition_steps::AbstractVector{Symbol})
    (; l200, config, periods, runs) = session
    # print one line per report and collect the failed detectors and their errors for the summary
    function check_report(label::String, filename::AbstractString, failed::Dict{String, Vector{String}}, errors::Dict{String, Vector{String}})
        if !isfile(filename)
            printstyled("  $(rpad(label, 11)) no report\n"; color = :light_black)
            return
        end
        n_entries, n_failed, failures = report_failures(filename)
        if isempty(failures)
            printstyled("  $(rpad(label, 11)) OK"; color = :green)
            println(" ($n_entries entries)")
            return
        end
        # collect run and error per detector, dropping the filter type suffix for the summary
        for (det, err) in failures
            push!(get!(failed, first(split(det, " (")), String[]), label)
            isempty(err) || push!(get!(errors, first(split(det, " (")), String[]), err)
        end
        printstyled("  $(rpad(label, 11)) $n_failed of $n_entries entries failed: "; color = :red)
        println(truncate_string(join(unique(first.(failures)), ", "), 80))
    end

    # print which detector failed in which runs and with which errors
    function check_summary(process::Symbol, failed::Dict{String, Vector{String}}, errors::Dict{String, Vector{String}})
        println("-"^110)
        if isempty(failed)
            printstyled("  All detectors passed in all checked reports of $(string(process))\n"; color = :green)
        else
            printstyled("  Summary $(string(process)): $(length(failed)) detector(s) with failures\n"; color = :red)
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

    # reports written per run
    for process in run_steps
        report = Symbol("$(last(split(string(process), "process_")))")
        category = config.processors[process].category
        printstyled("\n$(string(process)) ($category)\n"; bold = true)
        println("-"^110)
        failed, errors = Dict{String, Vector{String}}(), Dict{String, Vector{String}}()
        for period in periods
            for run in processable_runs(l200, period, runs)
                # `start_filekey` throws an `ArgumentError` for a run without run information
                filekey = try
                    start_filekey(l200, (period, run, category))
                catch e
                    e isa ArgumentError || rethrow()
                    @warn "No start filekey for $period-$run-$category, skip: $(truncate_error(e))"
                    continue
                end
                if ismissing(filekey)
                    @warn "No $category data in $period-$run, skip"
                    continue
                end
                check_report("$period-$run", get_rreportfilename(l200, filekey, report), failed, errors)
            end
        end
        check_summary(process, failed, errors)
    end

    # reports written per partition, i.e. one per period
    for process in partition_steps
        report = Symbol("$(last(split(string(process), "process_")))")
        category = config.p_processors[process].category
        printstyled("\n$(string(process)) ($category)\n"; bold = true)
        println("-"^110)
        failed, errors = Dict{String, Vector{String}}(), Dict{String, Vector{String}}()
        for period in periods
            period_runs = processable_runs(l200, period, runs)
            if isempty(period_runs)
                @warn "No selected runs in $period, skip"
                continue
            end
            filekey = try
                start_filekey(l200, (period, first(period_runs), category))
            catch e
                e isa ArgumentError || rethrow()
                @warn "No start filekey for $period-$category, skip: $(truncate_error(e))"
                continue
            end
            if ismissing(filekey)
                @warn "No $category data in $period-$(first(period_runs)), skip"
                continue
            end
            check_report("$period", get_preportfilename(l200, filekey, report), failed, errors)
        end
        check_summary(process, failed, errors)
    end
end