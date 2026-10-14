# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

# Rows of the options pane: label and the values a row cycles through.
const SETUP_OPTIONS = (
    (:reprocess, "Reprocess", (nothing, true, false)),
    (:check_dependencies, "Check dependencies", (true, false)),
    (:analysis_runs_only, "Analysis runs only", (true, false)),
)

"""
    SetupPage()

State of the Setup page of the terminal user interface: a [`Juleana.Checklist`](@ref)
of periods with their runs, one of the run-level and one of the partition-level
processors, and the options pane. The checklists are built from the controller
snapshots by [`Juleana.sync_setup!`](@ref); keys are handled by
[`Juleana.setup_key!`](@ref).

`focus` is the focused pane: 1 periods, 2 run processors, 3 partition processors,
4 options. `editor` is the open [`Juleana.KwargsEditor`](@ref) and `confirm` is `:write`
while writing the config waits for confirmation.
"""
mutable struct SetupPage
    periods::Checklist
    run_procs::Checklist
    part_procs::Checklist
    focus::Int
    option::Int
    # available periods, runs and processors the checklists were built for
    layout::Any
    editor::Union{Nothing,KwargsEditor}
    confirm::Union{Nothing,Symbol}
    # inside of the options pane at the last render
    options::Tachikoma.Rect
end

SetupPage() = SetupPage(Checklist(ChecklistItem[]; title = "Periods / runs"),
    Checklist(ChecklistItem[]; title = "Run processors", focused = false, tag_style = setup_tag_style),
    Checklist(ChecklistItem[]; title = "Partition processors", focused = false, tag_style = setup_tag_style), 1, 1, nothing,
    nothing, nothing, Tachikoma.Rect(1, 1, 0, 0))

setup_panes(page::SetupPage) = (page.periods, page.run_procs, page.part_procs)

# Selected runs of each selected period in `snap` that are on disk.
function selected_period_runs(snap)
    return Dict(p => (snap.runs isa AbstractDict ? intersect(snap.available_runs[p], get(snap.runs, p, snap.available_runs[p])) :
        isnothing(snap.runs) ? snap.available_runs[p] : intersect(snap.available_runs[p], snap.runs))
        for p in snap.periods if haskey(snap.available_runs, p))
end

# Style of a processor tag in the checklists: category, rank, dependencies, disabled.
function setup_tag_style(tag)
    tag == "cal" && return Tachikoma.tstyle(:primary)
    tag == "phy" && return Tachikoma.tstyle(:secondary)
    startswith(tag, "rank ") && return Tachikoma.tstyle(:text_dim)
    startswith(tag, "deps: ") && return Tachikoma.tstyle(:warning)
    tag == "disabled" && return Tachikoma.tstyle(:error)
    return nothing
end

processor_tags(p) = vcat(string(p.category), "rank $(p.rank)",
    isempty(p.dependencies) ? String[] : ["deps: " * join(p.dependencies, ", ")],
    p.enabled ? String[] : ["disabled"])

"""
    Juleana.sync_setup!(page::SetupPage, snap; pending::Bool = false)

Bring `page` in line with the controller snapshot `snap`. The checklists are rebuilt when
the available periods, runs or processors change, keeping their cursor and filter
otherwise. Unless commands of the page are `pending`, the checked items are set to the
selection of `snap`.
"""
function sync_setup!(page::SetupPage, snap; pending::Bool = false)
    (isnothing(snap) || isempty(snap.processors)) && return page
    layout = (snap.available_periods, snap.available_runs,
        [(p.name, p.level, p.category, p.rank, p.enabled, p.dependencies) for p in snap.processors])
    if layout != page.layout
        selected = Set(snap.periods)
        groups = [ChecklistGroup(p, string(p),
            [ChecklistItem((p, r), string(r)) for r in snap.available_runs[p]];
            tags = [(n = length(snap.available_runs[p]); n == 1 ? "1 run" : "$n runs")], expanded = p in selected)
            for p in snap.available_periods]
        items(level) = [ChecklistItem(p.name, string(p.name); tags = processor_tags(p))
            for p in snap.processors if p.level === level]
        focused = page.focus
        page.periods = Checklist(groups; title = "Periods / runs", focused = focused == 1)
        page.run_procs = Checklist(items(:run); title = "Run processors", focused = focused == 2, tag_style = setup_tag_style)
        page.part_procs = Checklist(items(:partition); title = "Partition processors", focused = focused == 3,
            tag_style = setup_tag_style)
        page.layout = layout
        pending = false
    end
    if !pending
        set_checked!(page.periods, [(p, r) for (p, runs) in selected_period_runs(snap) for r in runs])
        set_checked!(page.run_procs, snap.run_steps)
        set_checked!(page.part_procs, snap.partition_steps)
    end
    return page
end

# The `SelectRuns` command for the periods and runs checked on `page`.
function period_selection(page::SetupPage, snap)
    chosen = Dict{DataPeriod,Vector{DataRun}}()
    for (p, r) in checked(page.periods)
        push!(get!(chosen, p, DataRun[]), r)
    end
    return SelectRuns(Dict(p => (length(runs) == length(snap.available_runs[p]) ? nothing : runs)
        for (p, runs) in chosen))
end

steps_selection(page::SetupPage) = SelectSteps(checked(page.run_procs), checked(page.part_procs))

# Names of the steps that the checked steps wait for: their dependencies and every step of
# the same level ranked before a dependency, recursively.
function with_dependencies(page::SetupPage, snap)
    order = Dict(level => [p.name for p in snap.processors if p.level === level] for level in (:run, :partition))
    spec = Dict(p.name => p for p in snap.processors)
    chosen = Set{Symbol}(vcat(checked(page.run_procs), checked(page.part_procs)))
    todo = collect(chosen)
    while !isempty(todo)
        for dep in spec[pop!(todo)].dependencies
            steps = order[spec[dep].level]
            for name in steps[firstindex(steps):findfirst(==(dep), steps)]
                name in chosen || (push!(chosen, name); push!(todo, name))
            end
        end
    end
    return chosen
end

option_value(snap, key) = getproperty(snap, key)

function option_command(key, value)
    key === :reprocess && return SetReprocess(value)
    key === :check_dependencies && return SetCheckDependencies(value)
    return SetAnalysisRunsOnly(value)
end

"""
    Juleana.setup_key!(page::SetupPage, evt::Tachikoma.KeyEvent, snap, send)

Handle the key `evt` on the Setup page and return whether it was used. `snap` is the
latest controller snapshot (or `nothing`) and `send(cmd)` sends a controller command.

An open kwargs editor gets every key (see [`Juleana.kwargs_key!`](@ref)); while writing
the config waits for confirmation, `y` sends [`WriteConfig`](@ref) for the config file
of the session and any other key cancels. Otherwise the focused checklist gets the key
first; a change of its selection sends `SelectRuns` or `SelectSteps`. Then: Tab and Shift-Tab move between the panes; in a processor pane
`c` and `p` select the `cal` and `phy` processors of the pane, `d` adds the steps
the selected steps wait for and `e` opens the kwargs editor for the processor under the
cursor; in the options pane Up and Down choose a row and Space or
Enter cycles its value; `s` starts processing, `x` stops it after the running items, `X`
stops it without waiting for them, `r` reloads the config, `g` rebuilds the
dependency graph, `W` starts workers with [`SubmitWorkers`](@ref) and `w` asks to write
the current settings to the config file.
"""
function setup_key!(page::SetupPage, evt::Tachikoma.KeyEvent, snap, send)
    evt.action == Tachikoma.key_release && return false
    if !isnothing(page.editor)
        kwargs_key!(page.editor, evt, snap, send) === :close && (page.editor = nothing)
        return true
    end
    if page.confirm === :write
        evt.key == :char && evt.char == 'y' && !isnothing(snap) && send(WriteConfig(snap.config_file))
        page.confirm = nothing
        return true
    end
    panes = setup_panes(page)
    if page.focus <= length(panes)
        list = panes[page.focus]
        before = checked(list)
        if Tachikoma.handle_key!(list, evt)
            if checked(list) != before && !isnothing(snap)
                send(page.focus == 1 ? period_selection(page, snap) : steps_selection(page))
            end
            return true
        end
    end
    key, char = evt.key, evt.char
    if key == :tab || key == :backtab
        page.focus = mod1(page.focus + (key == :tab ? 1 : -1), length(panes) + 1)
        for (i, list) in pairs(panes)
            list.focused = i == page.focus
        end
    elseif page.focus in (2, 3) && key == :char && char in ('c', 'p') && !isnothing(snap)
        category = char == 'c' ? :cal : :phy
        level = page.focus == 2 ? :run : :partition
        names = Set(p.name for p in snap.processors if p.level === level && p.category === category)
        set_checked!(item -> item.key in names, panes[page.focus])
        send(steps_selection(page))
    elseif page.focus in (2, 3) && key == :char && char == 'd' && !isnothing(snap)
        chosen = with_dependencies(page, snap)
        set_checked!(item -> item.key in chosen, page.run_procs)
        set_checked!(item -> item.key in chosen, page.part_procs)
        send(steps_selection(page))
    elseif page.focus in (2, 3) && key == :char && char == 'e' && !isnothing(current(panes[page.focus]))
        page.editor = KwargsEditor(current(panes[page.focus]).key)
    elseif key == :char && char == 'w' && !isnothing(snap) && !isnothing(snap.config_file)
        page.confirm = :write
    elseif page.focus == 4 && key in (:up, :down)
        page.option = clamp(page.option + (key == :up ? -1 : 1), 1, length(SETUP_OPTIONS))
    elseif page.focus == 4 && (key == :enter || (key == :char && char == ' ')) && !isnothing(snap)
        cycle_option(page, snap, send)
    elseif key == :char && char == 's'
        send(StartProcessing())
    elseif key == :char && char == 'x'
        send(StopProcessing())
    elseif key == :char && char == 'X'
        send(StopProcessing(; force = true))
    elseif key == :char && char == 'r'
        send(ReloadConfig())
    elseif key == :char && char == 'g'
        send(ResetDependencyGraph())
    elseif key == :char && char == 'W'
        send(SubmitWorkers())
    else
        return false
    end
    return true
end

"""
    Juleana.setup_mouse!(page::SetupPage, evt::Tachikoma.MouseEvent, snap, send)

Pass the mouse event `evt` to the checklist under the pointer, focus that pane, and send
the new selection if it changed. A left click in the options pane focuses it; on an
option row it also chooses the row and sends its next value. Return whether the event
was used.
"""
function setup_mouse!(page::SetupPage, evt::Tachikoma.MouseEvent, snap, send)
    (isnothing(page.editor) && isnothing(page.confirm)) || return false
    panes = setup_panes(page)
    function focus!(i)
        page.focus = i
        for (j, other) in pairs(panes)
            other.focused = j == i
        end
    end
    for (i, list) in pairs(panes)
        before = checked(list)
        Tachikoma.handle_mouse!(list, evt) || continue
        focus!(i)
        if checked(list) != before && !isnothing(snap)
            send(i == 1 ? period_selection(page, snap) : steps_selection(page))
        end
        return true
    end
    if evt.button == Tachikoma.mouse_left && evt.action == Tachikoma.mouse_press && Base.contains(page.options, evt.x, evt.y)
        focus!(length(panes) + 1)
        row = evt.y - page.options.y + 1
        if !isnothing(snap) && !isempty(snap.processors) && row in eachindex(SETUP_OPTIONS)
            page.option = row
            cycle_option(page, snap, send)
        end
        return true
    end
    return false
end

# Send the next value of the option row `page.option`.
function cycle_option(page::SetupPage, snap, send)
    option, _, values = SETUP_OPTIONS[page.option]
    i = something(findfirst(==(option_value(snap, option)), values), 0)
    send(option_command(option, values[mod1(i + 1, length(values))]))
    return nothing
end

format_option(value) = value === nothing ? "config" : value === true ? "yes" : value === false ? "no" : string(value)

# Lines of the summary of what a start would process.
function setup_summary(snap)
    period_runs = selected_period_runs(snap)
    nruns = sum(length, values(period_runs); init = 0)
    nperiods = count(!isempty, values(period_runs))
    return [
        "Periods: $nperiods" * (nperiods == 0 ? "" : " (" * join(string.(sort!([p for (p, r) in period_runs if !isempty(r)])), ", ") * ")"),
        "Runs: $nruns",
        "Run steps: $(length(snap.run_steps)) × $nruns runs",
        "Partition steps: $(length(snap.partition_steps)) × $nperiods periods",
    ]
end

const SETUP_KEYS = [
    "Tab: next pane   Space: toggle",
    "/: filter   a/n: all/none",
    "c/p: cal/phy   d: add deps",
    "e: settings   w: write config",
    "s: start   x/X: stop/force",
    "r: reload config   W: start workers",
    "g: rebuild dependency graph",
]

"""
    Juleana.render_setup(page::SetupPage, snap, area::Tachikoma.Rect, buf::Tachikoma.Buffer)

Draw the Setup page into `area`: periods and runs on the left, the run and partition
processors in the middle, and the options, a summary of what a start would process and
the keys on the right.
"""
function render_setup(page::SetupPage, snap, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    columns = Tachikoma.Layout(Tachikoma.Horizontal,
        [Tachikoma.Percent(28), Tachikoma.Percent(42), Tachikoma.Fill()])
    left, middle, right = Tachikoma.split_layout(columns, area)
    Tachikoma.render(page.periods, left, buf)
    nrun, npart = length(page.run_procs.keys), length(page.part_procs.keys)
    procs = Tachikoma.Layout(Tachikoma.Vertical,
        [Tachikoma.Fill(max(1, nrun + 2)), Tachikoma.Fill(max(1, npart + 2))])
    top, bottom = Tachikoma.split_layout(procs, middle)
    Tachikoma.render(page.run_procs, top, buf)
    Tachikoma.render(page.part_procs, bottom, buf)

    block = pane_block("Options", page.focus == 4)
    inner = Tachikoma.render(block, right, buf)
    page.options = inner
    text, dim = Tachikoma.tstyle(:text), Tachikoma.tstyle(:text_dim)
    lines = Vector{Tuple{String,Tachikoma.Style}}[]
    if isnothing(snap) || isempty(snap.processors)
        push!(lines, [("Loading the session…", dim)])
    else
        for (i, (key, label, _)) in pairs(SETUP_OPTIONS)
            value = option_value(snap, key)
            chosen = page.focus == 4 && i == page.option
            value_color = value === true ? :success : value === false ? :error : :text_dim
            push!(lines, [("$label: ", chosen ? Tachikoma.tstyle(:accent, bold = true) : text),
                (format_option(value), Tachikoma.tstyle(value_color, bold = chosen))])
        end
        push!(lines, [("", text)])
        for line in setup_summary(snap)
            head, tail = split(line, ": "; limit = 2)
            push!(lines, [(head * ": ", dim), (tail, Tachikoma.tstyle(:text_bright))])
        end
    end
    push!(lines, [("", text)])
    append!(lines, [[(l, dim)] for l in SETUP_KEYS])
    for (i, spans) in pairs(lines)
        y = inner.y + i - 1
        y > Tachikoma.bottom(inner) && break
        put_spans!(buf, inner.x, y, Tachikoma.right(inner), spans)
    end
    isnothing(page.editor) || render_kwargs(page.editor, snap, area, buf)
    if page.confirm === :write && !isnothing(snap)
        file = snap.config_file
        Tachikoma.render(Tachikoma.Modal(; title = "Write config",
            message = "Write the current settings to\n$file?\nThe current file is kept as $(basename(file)).bak.\n\ny: write   any other key: cancel",
            confirm_label = "", cancel_label = ""), area, buf)
    end
    return nothing
end
