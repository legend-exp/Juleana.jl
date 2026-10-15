# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

"""
    menu(session::DataflowSession)

Show the interactive dataflow menu, perform one selected action on `session`, and
return `nothing`. Call `menu` again for the next action. The actions are:

1. Execute processors: select run and partition processors and options, then run them,
   or with the `check_report` option only summarize their reports with
   [`check_reports`](@ref).
2. Select periods: change the period selection and rebuild the dependency graph.
3. Select runs: change the run selection and rebuild the dependency graph.
4. Reload processing config: read the config file again with the original command line
   options, keeping the session's log directory, and rebuild the steps and the
   dependency graph.
5. Reset dependency graph: rebuild the dependency graph for the enabled steps.
6. Submit workers: start workers for the configured run mode.
7. Exit: return without action.

!!! note
    Processor functions are package code. With Revise loaded, edits to
    `src/processors/` take effect at the next menu call.

# Examples
```julia
session = Juleana.setup_session(["--config", "config/processing_config.json"])
menu(session)
```
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
            # the menu selects the same runs in every period; per-period runs preselect those of the first period
            current = session.runs isa AbstractDict && !isempty(session.periods) ? get(session.runs, first(session.periods), possible_runs) : session.runs isa AbstractDict ? nothing : session.runs
            runs_menu = MultiSelectMenu(string.(possible_runs); selected=eachindex(possible_runs)[map(x -> isnothing(current) || x in current, possible_runs)], ctrl_c_interrupt = true)
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
        session.l200, session.config, session.periods, session.runs = l200, config, periods, session_runs(session.args, config)
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

"""
    check_reports(session::DataflowSession, run_steps, partition_steps)

Print, for every step in `run_steps` (run level) and `partition_steps` (partition
level), one line per report of the session's periods and runs, followed by a summary of
the failed detectors and their errors. The reports are read with
[`report_index`](@ref) and summarized with [`failure_summary`](@ref). Return `nothing`.

A line shows the failed entries of the report, `OK` with the number of entries, or
`Warning` when only warnings occurred. A missing report is listed as `no report`.
An entry is a row of a report table with a `Status` column; it counts as failed when
its status cell contains `Failure`, see [`read_report`](@ref).
"""
function check_reports(session::DataflowSession, run_steps::AbstractVector{Symbol}, partition_steps::AbstractVector{Symbol})
    (; l200, config, periods, runs) = session
    for (steps, specs) in ((run_steps, config.processors), (partition_steps, config.p_processors)), process in steps
        spec = specs[process]
        printstyled("\n$(string(process)) ($(spec.category))\n"; bold = true)
        println("-"^110)
        rows = report_index(l200, [spec], periods, runs)
        for row in rows
            label = rpad(row_label(row), 11)
            if row.state == :missing
                printstyled("  $label no report\n"; color = :light_black)
            elseif !isempty(row.failures)
                printstyled("  $label $(row.n_failed) of $(row.n_entries) entries failed: "; color = :red)
                println(truncate_string(join(unique(first.(row.failures)), ", "), 80))
            elseif row.state == :failed
                printstyled("  $label processor failed\n"; color = :red)
            elseif row.state == :warning
                printstyled("  $label Warning"; color = :yellow)
                println(" ($(row.n_warnings) of $(row.n_entries) entries with warnings)")
            else
                printstyled("  $label OK"; color = :green)
                println(" ($(row.n_entries) entries)")
            end
        end
        # print which detector failed in which runs and with which errors
        println("-"^110)
        detectors = isempty(rows) ? [] : only(failure_summary(rows)).detectors
        if isempty(detectors)
            printstyled("  All detectors passed in all checked reports of $(string(process))\n"; color = :green)
        else
            printstyled("  Summary $(string(process)): $(length(detectors)) detector(s) with failures\n"; color = :red)
            for (; detector, labels, errors) in detectors
                println("      $(rpad(detector, 12)) $(lpad(length(labels), 3)) run(s): $(truncate_string(join(labels, ", "), 85))")
                for err in errors
                    println("      $(" "^12)      $(truncate_string(err, 100))")
                end
            end
        end
        println()
    end
    return nothing
end
