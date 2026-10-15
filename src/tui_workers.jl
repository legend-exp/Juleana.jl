# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

# Seconds between two background reads of the overview while the page is visible.
const WORKERS_READ_SECONDS = 5.0

# Lines scrolled per notch of the mouse wheel.
const WORKERS_WHEEL_LINES = 3

# Theme color of each state of a worker allocation.
const WORKERS_STATE_COLORS = (running = :success, ended = :text_dim, failed = :error, cancelled = :warning)

# A line of worker output as Distributed relays it to the output of the head process.
const WORKERS_OUTPUT_LINE = r"^\s*From worker (\d+):\t(.*)$"

"""
    WorkersPage()

State of the Workers page of the terminal user interface: the latest overview of the worker
allocations, the workers and SLURM as [`Juleana.workers_overview`](@ref) returns it, the
focused pane, the selected allocation and worker, the scroll positions of the output panes,
a pending confirmation, the start script editor and the requests for reading the overview.
Keys are handled by [`Juleana.workers_key!`](@ref) and [`Juleana.workers_mouse!`](@ref), the
page is drawn by [`Juleana.render_workers`](@ref).

The page never runs the commands of the overview. It queues requests (see
[`Juleana.take_requests!`](@ref)) that the interface carries out in the background and
answers with [`Juleana.workers_result!`](@ref). The selections are kept by allocation number
and process ID, so they stay on their item when the lists change.
"""
mutable struct WorkersPage
    overview::Union{Nothing,NamedTuple}
    error::Union{Nothing,String}
    # whether a read of the overview is under way
    reading::Bool
    # `time()` of the latest queued read
    read_at::Float64
    # 1 for the allocations, 2 for the workers or SLURM pane
    focus::Int
    # `:workers` or `:slurm`
    tab::Symbol
    alloc_id::Union{Nothing,Int}
    worker_pid::Union{Nothing,Int}
    # first displayed row of each list and of the SLURM text
    alloc_top::Int
    worker_top::Int
    slurm_top::Int
    # lines by which each output pane is scrolled up from the newest line
    alloc_back::Int
    worker_back::Int
    # `:cancel` or `:all` while the cancel of allocations waits for confirmation
    confirm::Union{Nothing,Symbol}
    confirm_id::Int
    editor::Union{Nothing,Tachikoma.TextArea}
    # message shown in place of the editor
    notice::Union{Nothing,String}
    const requests::Vector{Any}
    # areas of the lists and output panes at the last render
    alloc_list::Tachikoma.Rect
    worker_list::Tachikoma.Rect
    alloc_out::Tachikoma.Rect
    worker_out::Tachikoma.Rect
end

WorkersPage() = WorkersPage(nothing, nothing, false, -Inf, 1, :workers, nothing, nothing, 1, 1, 1, 0, 0, nothing, 0, nothing, nothing, Any[],
    Tachikoma.Rect(1, 1, 0, 0), Tachikoma.Rect(1, 1, 0, 0), Tachikoma.Rect(1, 1, 0, 0), Tachikoma.Rect(1, 1, 0, 0))

"""
    Juleana.take_requests!(page::WorkersPage)

Return the requests of `page` for reading the overview and clear them. A request is a named
tuple with `kind` `:overview`. [`Juleana.read_workers_page`](@ref) carries a request out and
[`Juleana.workers_result!`](@ref) takes its answer.
"""
function take_requests!(page::WorkersPage)
    requests = copy(page.requests)
    empty!(page.requests)
    return requests
end

"""
    Juleana.read_workers_page(ctrl::DataflowController, request)

Carry out a request of a [`Juleana.WorkersPage`](@ref) (see [`Juleana.take_requests!`](@ref))
and return `(; request, value)` with the [`Juleana.workers_overview`](@ref) of the workers
of `ctrl`, or `(; request, error)` with the message of the exception if the read failed.
Runs SLURM commands, so it belongs in a background task.
"""
function read_workers_page(ctrl::DataflowController, request)
    value = try
        workers_overview(ctrl.workers)
    catch e
        return (; request, error = first(split(sprint(showerror, e), '\n')))
    end
    return (; request, value)
end

"""
    Juleana.workers_result!(page::WorkersPage, answer)

Take the `answer` to a request of `page` as [`Juleana.read_workers_page`](@ref) returns it:
the overview replaces the one of `page`, or the message of a failed read becomes its `error`
and the shown overview stays.
"""
function workers_result!(page::WorkersPage, answer)
    page.reading = false
    page.error = haskey(answer, :error) ? answer.error : nothing
    haskey(answer, :error) || (page.overview = answer.value)
    return nothing
end

"""
    Juleana.workers_visit!(page::WorkersPage; at::Real = time())

Queue a read of the overview unless one is under way or the latest was queued less than five
seconds before `at`.
"""
function workers_visit!(page::WorkersPage; at::Real = time())
    (page.reading || at - page.read_at < WORKERS_READ_SECONDS) && return nothing
    page.reading, page.read_at = true, at
    push!(page.requests, (; kind = :overview))
    return nothing
end

"""
    Juleana.workers_stale!(page::WorkersPage)

Mark the overview of `page` as out of date, so that the next [`Juleana.workers_visit!`](@ref)
queues a read at once, even if a read is under way.
"""
function workers_stale!(page::WorkersPage)
    page.read_at = -Inf
    return nothing
end

workers_allocations(page::WorkersPage) = isnothing(page.overview) ? () : page.overview.allocations
workers_list(page::WorkersPage) = isnothing(page.overview) ? () : page.overview.workers

# Index of the item with `key` equal to `id` in `items`, the first item if there is none, 0 for no items.
workers_index(items, key, id) = isempty(items) ? 0 : something(findfirst(x -> getproperty(x, key) == id, items), 1)

"""
    Juleana.workers_selected_allocation(page::WorkersPage)

Return the selected allocation of `page` (the first one if none was selected) as the named tuple of
the overview, or `nothing` if there is none.
"""
function workers_selected_allocation(page::WorkersPage)
    items = workers_allocations(page)
    return isempty(items) ? nothing : items[workers_index(items, :id, page.alloc_id)]
end

"""
    Juleana.workers_selected_worker(page::WorkersPage)

Return the selected worker of `page` (the first one if none was selected) as `(; pid, host)`, or
`nothing` if there is none.
"""
function workers_selected_worker(page::WorkersPage)
    items = workers_list(page)
    return isempty(items) ? nothing : items[workers_index(items, :pid, page.worker_pid)]
end

# Whether the overview has SLURM output.
workers_has_slurm(page::WorkersPage) = !isnothing(page.overview) && !isnothing(page.overview.slurm)

# The pane shown at the right: `:slurm` only if the overview has SLURM output.
workers_tab(page::WorkersPage) = page.tab === :slurm && workers_has_slurm(page) ? :slurm : :workers

# Move the selection of the focused list, or the text of the SLURM pane, by `delta` rows.
function workers_move!(page::WorkersPage, delta)
    if page.focus == 1
        items = workers_allocations(page)
        isempty(items) && return nothing
        id = items[clamp(workers_index(items, :id, page.alloc_id) + delta, 1, length(items))].id
        id == page.alloc_id || (page.alloc_back = 0)
        page.alloc_id = id
    elseif workers_tab(page) === :slurm
        page.slurm_top = max(1, page.slurm_top + delta)
    else
        items = workers_list(page)
        isempty(items) && return nothing
        pid = items[clamp(workers_index(items, :pid, page.worker_pid) + delta, 1, length(items))].pid
        pid == page.worker_pid || (page.worker_back = 0)
        page.worker_pid = pid
    end
    return nothing
end

# Scroll the output pane of the focused list, or the SLURM text, by `delta` lines (positive: older lines).
function workers_scroll!(page::WorkersPage, delta)
    if page.focus == 1
        page.alloc_back = max(0, page.alloc_back + delta)
    elseif workers_tab(page) === :slurm
        page.slurm_top = max(1, page.slurm_top - delta)
    else
        page.worker_back = max(0, page.worker_back + delta)
    end
    return nothing
end

# Open the editor on the start script of the overview, or the notice that says why there is none.
function open_script_editor!(page::WorkersPage)
    script = isnothing(page.overview) ? "The start script has not been read yet." : page.overview.script
    if script isa AbstractString
        page.notice = String(script)
    else
        page.editor = Tachikoma.TextArea(; text = script.text, focused = true)
        page.editor.cursor_row, page.editor.cursor_col = 1, 0
    end
    return nothing
end

"""
    Juleana.workers_key!(page::WorkersPage, evt::Tachikoma.KeyEvent, send)::Bool

Apply the key event `evt` to `page`. `send(cmd)` queues the controller command `cmd`. Return
`true` if the key was used and `false` otherwise.

  - Tab and Shift-Tab switch between the allocations and the workers or SLURM pane.
  - Up and Down move the selection in the focused list; over the SLURM text they scroll it.
    PageUp, PageDown and End scroll the output of the focused pane, End to the newest line.
  - `s` switches the right pane between the workers and SLURM, if the overview has SLURM output.
  - `a` sends [`AddWorkers`](@ref).
  - `c` asks for confirmation to cancel the selected allocation if it is running, `C` for all
    allocations. The question says that items running on these workers fail; `y` sends
    [`CancelAllocation`](@ref) or [`CancelAll`](@ref), any other key cancels the question.
  - `p` sends [`PostponeIdleCancel`](@ref).
  - `r` reads the overview again.
  - `e` opens the start script in a full-page editor, or shows why there is none. In the
    editor Ctrl-S sends [`EditStartScript`](@ref) with the text and closes it, Escape closes
    it without saving, and every other key edits the text. A shown message closes with any key.
  - Other keys, such as `1` to `7` and `q`, are not used while no editor, message or question is open.
"""
function workers_key!(page::WorkersPage, evt::Tachikoma.KeyEvent, send)::Bool
    modal = !isnothing(page.editor) || !isnothing(page.notice) || !isnothing(page.confirm)
    evt.action == Tachikoma.key_release && return modal
    if !isnothing(page.editor)
        if evt.key == :escape
            page.editor = nothing
        elseif evt.key == :ctrl && evt.char == 's'
            send(EditStartScript(Tachikoma.text(page.editor)))
            page.editor = nothing
        else
            Tachikoma.handle_key!(page.editor, evt)
        end
        return true
    elseif !isnothing(page.notice)
        page.notice = nothing
        return true
    elseif !isnothing(page.confirm)
        confirm, page.confirm = page.confirm, nothing
        if evt.key == :char && evt.char == 'y'
            send(confirm === :all ? CancelAll() : CancelAllocation(page.confirm_id))
        end
        return true
    end
    key = evt.key
    if key in (:tab, :backtab)
        page.focus = 3 - page.focus
    elseif key == :up
        workers_move!(page, -1)
    elseif key == :down
        workers_move!(page, 1)
    elseif key in (:pageup, :pagedown)
        height = (page.focus == 1 ? page.alloc_out : page.worker_out).height
        workers_scroll!(page, key == :pageup ? max(1, height) : -max(1, height))
    elseif key == :end_key
        workers_scroll!(page, typemin(Int) ÷ 2)
    elseif key == :char && evt.char == 's'
        workers_has_slurm(page) || return false
        page.tab = workers_tab(page) === :slurm ? :workers : :slurm
    elseif key == :char && evt.char == 'a'
        send(AddWorkers())
    elseif key == :char && evt.char == 'c'
        alloc = workers_selected_allocation(page)
        (isnothing(alloc) || alloc.state !== :running) && return false
        page.confirm, page.confirm_id = :cancel, alloc.id
    elseif key == :char && evt.char == 'C'
        page.confirm = :all
    elseif key == :char && evt.char == 'p'
        send(PostponeIdleCancel())
    elseif key == :char && evt.char == 'r'
        workers_stale!(page)
    elseif key == :char && evt.char == 'e'
        open_script_editor!(page)
    else
        return false
    end
    return true
end

"""
    Juleana.workers_mouse!(page::WorkersPage, evt::Tachikoma.MouseEvent)::Bool

Apply the mouse event `evt` to `page`: a left click on a row of the allocations or the workers
selects it and focuses its pane, and the scroll wheel scrolls the output pane (or the SLURM
text) under the pointer by three lines. The mouse does nothing while the editor, a message or a
question is open. Return `true` if the event was used.
"""
function workers_mouse!(page::WorkersPage, evt::Tachikoma.MouseEvent)::Bool
    (!isnothing(page.editor) || !isnothing(page.notice) || !isnothing(page.confirm)) && return false
    evt.action == Tachikoma.mouse_press || return false
    if evt.button == Tachikoma.mouse_left
        if Base.contains(page.alloc_list, evt.x, evt.y)
            items = workers_allocations(page)
            i = page.alloc_top + evt.y - page.alloc_list.y
            i in eachindex(items) || return false
            page.focus = 1
            items[i].id == page.alloc_id || (page.alloc_back = 0)
            page.alloc_id = items[i].id
            return true
        elseif Base.contains(page.worker_list, evt.x, evt.y) && workers_tab(page) === :workers
            items = workers_list(page)
            i = page.worker_top + evt.y - page.worker_list.y
            i in eachindex(items) || return false
            page.focus = 2
            items[i].pid == page.worker_pid || (page.worker_back = 0)
            page.worker_pid = items[i].pid
            return true
        end
    elseif evt.button in (Tachikoma.mouse_scroll_up, Tachikoma.mouse_scroll_down)
        delta = (evt.button == Tachikoma.mouse_scroll_up ? 1 : -1) * WORKERS_WHEEL_LINES
        if Base.contains(page.alloc_out, evt.x, evt.y)
            page.alloc_back = max(0, page.alloc_back + delta)
            return true
        elseif Base.contains(page.worker_out, evt.x, evt.y)
            page.worker_back = max(0, page.worker_back + delta)
            return true
        elseif workers_tab(page) === :slurm && Base.contains(page.worker_list, evt.x, evt.y)
            page.slurm_top = max(1, page.slurm_top - delta)
            return true
        end
    end
    return false
end

# Text of the item `b` of the busy workers: processor and period or run.
workers_busy_text(b) = display_name(b.step) * " " * (isnothing(b.run) ? string(b.period) : "$(b.period)-$(b.run)")

# Spans of the row of the allocation `a` at the time `at`.
function workers_allocation_spans(a, at)
    color = WORKERS_STATE_COLORS[a.state]
    duration = format_duration(((something(a.finished, at)) - a.started) / Millisecond(1000))
    job = isnothing(a.job_name) ? "" : a.job_name * (isempty(a.job_ids) ? "" : " (" * join(a.job_ids, ",") * ")") * "  "
    spans = [(lpad(a.id, 2) * " ", Tachikoma.tstyle(:text_bright)), (rpad(a.backend, 6) * " ", Tachikoma.tstyle(:text)),
        (rpad(a.state, 9) * " ", Tachikoma.tstyle(color, bold = a.state === :running)), (job, Tachikoma.tstyle(:text_dim)),
        ((a.state === :running ? duration : "ended after " * duration), Tachikoma.tstyle(:text))]
    a.state === :failed && push!(spans, ("  exit $(a.exit_code)", Tachikoma.tstyle(:error)))
    return spans
end

# Spans of the row of the worker `w`; `item` is its busy item or `nothing`.
function workers_worker_spans(w, item)
    spans = [(lpad(w.pid, 3) * " ", Tachikoma.tstyle(:text_bright)), (rpad(isnothing(w.host) ? "…" : w.host, 12) * " ", Tachikoma.tstyle(:text))]
    if isnothing(item)
        push!(spans, ("idle", Tachikoma.tstyle(:text_dim)))
    else
        push!(spans, ("busy " * workers_busy_text(item), Tachikoma.tstyle(:accent)))
        item.abandoned && push!(spans, (" (abandoned)", Tachikoma.tstyle(:warning)))
    end
    return spans
end

# Draw the `rows` (lists of spans) into `inner` with the row `selected` marked and return the first displayed row.
function workers_draw_list!(buf, inner, rows, selected, top, focused)
    top = clamp(top, 1, max(1, length(rows) - inner.height + 1))
    selected > 0 && selected < top && (top = selected)
    selected > top + inner.height - 1 && (top = selected - inner.height + 1)
    for r in 0:(inner.height - 1)
        i = top + r
        i <= length(rows) || break
        marked = i == selected
        spans = vcat([(marked ? "▶ " : "  ", Tachikoma.tstyle(:accent, bold = true))], rows[i])
        put_spans!(buf, inner.x, inner.y + r, Tachikoma.right(inner), spans, marked && focused ? Tachikoma.tstyle(:border) : nothing)
    end
    return top
end

# Draw the output `lines` (`(text, style)` pairs) in a block titled `title` over `area`, the last line at the bottom
# unless scrolled up by `back` lines. Return the clamped `back` and the area inside the block.
function workers_draw_output!(buf, area, title, lines, back, focused)
    back = clamp(back, 0, max(0, length(lines) - max(0, area.height - 2)))
    inner = Tachikoma.render(pane_block(clip_text(title * (back > 0 ? "  (scrolled up $back)" : ""), max(0, area.width - 6)), focused), area, buf)
    if isempty(lines)
        Tachikoma.set_string!(buf, inner.x, inner.y, "No output.", Tachikoma.tstyle(:text_dim); max_x = Tachikoma.right(inner))
    elseif inner.height > 0
        last_line = length(lines) - back
        for (r, i) in enumerate(max(1, last_line - inner.height + 1):last_line)
            text, style = lines[i]
            Tachikoma.set_string!(buf, inner.x, inner.y + r - 1, text, style; max_x = Tachikoma.right(inner))
        end
    end
    return back, inner
end

# Output lines of the worker `pid` among the message `entries`: the lines relayed with its prefix, without the prefix.
function workers_output_lines(entries, pid)
    lines = Tuple{String,Tachikoma.Style}[]
    for e in entries
        m = match(WORKERS_OUTPUT_LINE, e.text)
        (isnothing(m) || parse(Int, m[1]) != pid) && continue
        color = e.level >= Logging.Error ? :error : e.level >= Logging.Warn ? :warning : :text
        push!(lines, (replace(m[2], '\t' => "    "), Tachikoma.tstyle(color)))
    end
    return lines
end

# Spans of the information line: workers, busy workers and the countdown to the cancel of idle allocations.
function workers_info_spans(page::WorkersPage, snap, busy, at)
    n = isnothing(snap) ? length(workers_list(page)) : snap.nworkers
    spans = [(" workers $n", Tachikoma.tstyle(:primary))]
    isempty(busy) || push!(spans, (", $(length(busy)) busy", Tachikoma.tstyle(:secondary)))
    push!(spans, ("  · ", Tachikoma.tstyle(:border)))
    if isnothing(snap) || isnothing(snap.idle_deadline)
        push!(spans, ("no idle cancel", Tachikoma.tstyle(:text_dim)))
    else
        left = max(0, round(Int, (snap.idle_deadline - at) / Millisecond(1000)))
        push!(spans, ("idle cancel in $(lpad(left ÷ 60, 2, '0')):$(lpad(left % 60, 2, '0'))", Tachikoma.tstyle(left < 300 ? :warning : :text)))
    end
    page.reading && !isnothing(page.overview) && push!(spans, ("  reading…", Tachikoma.tstyle(:text_dim)))
    isnothing(page.error) || push!(spans, ("  " * page.error, Tachikoma.tstyle(:error, bold = true)))
    return spans
end

# Draw the start script editor over the whole `area`.
function workers_render_editor(page::WorkersPage, area, buf)
    (area.width < 3 || area.height < 3) && return nothing
    inner = Tachikoma.render(pane_block(clip_text("Start script  (Ctrl-S saves, Esc closes)", max(0, area.width - 6)), true), area, buf)
    Tachikoma.render(page.editor, inner, buf)
    return nothing
end

"""
    Juleana.render_workers(page::WorkersPage, snap, busy, entries, area::Tachikoma.Rect, buf::Tachikoma.Buffer;
        at::DateTime = now(UTC))

Draw the Workers page into `area` of `buf`. `snap` is the controller snapshot (or `nothing`),
`busy` the busy workers (see `busy_workers`), `entries` the entries of the message buffer
(see [`Juleana.message_entries`](@ref)) and `at` the current UTC time.

A line at the top shows the number of workers and the countdown to the cancel of idle
allocations (`idle cancel in mm:ss`, or `no idle cancel`). Two columns follow. The left one
lists the allocations (number, backend, state, SLURM job name and job IDs, run time or the
time it ran, the exit code of a failed one) with the output of the script of the selected
allocation below, the newest line at the bottom. The right one lists the workers (process
ID, host, the item a busy worker runs or `idle`) with the lines the selected worker wrote
below. If the overview has SLURM output, the right pane can show it instead (`squeue`, then
`sinfo -t idle`) over the whole column. The focused pane has the heavy border.

While the start script is edited the editor fills the whole area. A message about the
start script and the question before a cancel are drawn over the page.
"""
function render_workers(page::WorkersPage, snap, busy, entries, area::Tachikoma.Rect, buf::Tachikoma.Buffer;
        at::DateTime = now(UTC))
    page.alloc_list = page.worker_list = page.alloc_out = page.worker_out = Tachikoma.Rect(area.x, area.y, 0, 0)
    if !isnothing(page.editor)
        workers_render_editor(page, area, buf)
        return nothing
    end
    (area.width < 20 || area.height < 7) && return nothing
    info, body = Tachikoma.split_layout(Tachikoma.Layout(Tachikoma.Vertical, [Tachikoma.Fixed(1), Tachikoma.Fill()]), area)
    put_spans!(buf, info.x, info.y, Tachikoma.right(info), workers_info_spans(page, snap, busy, at))
    left, right = Tachikoma.split_layout(Tachikoma.Layout(Tachikoma.Horizontal, [Tachikoma.Fill(), Tachikoma.Fill()]), body)
    message(inner, text, color) = Tachikoma.set_string!(buf, inner.x, inner.y, text, Tachikoma.tstyle(color); max_x = Tachikoma.right(inner))
    top, bottom = Tachikoma.split_layout(Tachikoma.Layout(Tachikoma.Vertical, [Tachikoma.Percent(40), Tachikoma.Fill()]), left)

    allocations = workers_allocations(page)
    selected = workers_index(allocations, :id, page.alloc_id)
    inner = Tachikoma.render(pane_block("Allocations", page.focus == 1), top, buf)
    page.alloc_list = inner
    if isnothing(page.overview)
        message(inner, isnothing(page.error) ? "Reading the allocations…" : page.error, isnothing(page.error) ? :text_dim : :error)
    elseif isempty(allocations)
        message(inner, "No allocations. `a` starts workers.", :text_dim)
    else
        page.alloc_top = workers_draw_list!(buf, inner, [workers_allocation_spans(a, at) for a in allocations], selected, page.alloc_top, page.focus == 1)
    end
    alloc = workers_selected_allocation(page)
    title = isnothing(alloc) ? "Output of the allocation" : "Output of allocation $(alloc.id)"
    lines = isnothing(alloc) ? Tuple{String,Tachikoma.Style}[] : [(replace(l, '\t' => "    "), Tachikoma.tstyle(:text)) for l in alloc.output]
    page.alloc_back, page.alloc_out = workers_draw_output!(buf, bottom, title, lines, page.alloc_back, page.focus == 1)

    has_slurm = workers_has_slurm(page)
    slurm = workers_tab(page) === :slurm
    tab_title = !has_slurm ? "Workers" : slurm ? "Workers │ [SLURM]" : "[Workers] │ SLURM"
    if slurm
        inner = Tachikoma.render(pane_block(tab_title, page.focus == 2), right, buf)
        page.worker_list = inner
        text = [split(chomp(page.overview.slurm.queue), '\n'); ""; split(chomp(page.overview.slurm.idle), '\n')]
        page.slurm_top = clamp(page.slurm_top, 1, max(1, length(text) - inner.height + 1))
        for (r, line) in enumerate(text[page.slurm_top:min(end, page.slurm_top + inner.height - 1)])
            Tachikoma.set_string!(buf, inner.x, inner.y + r - 1, replace(line, '\t' => " "), Tachikoma.tstyle(:text); max_x = Tachikoma.right(inner))
        end
        return workers_render_modals(page, area, buf)
    end
    wtop, wbottom = Tachikoma.split_layout(Tachikoma.Layout(Tachikoma.Vertical, [Tachikoma.Percent(40), Tachikoma.Fill()]), right)
    inner = Tachikoma.render(pane_block(tab_title, page.focus == 2), wtop, buf)
    page.worker_list = inner
    workers = workers_list(page)
    if isnothing(page.overview)
        message(inner, "Reading the workers…", :text_dim)
    elseif isempty(workers)
        message(inner, "No workers.", :text_dim)
    else
        items = Dict(b.worker => b for b in busy)
        rows = [workers_worker_spans(w, get(items, w.pid, nothing)) for w in workers]
        page.worker_top = workers_draw_list!(buf, inner, rows, workers_index(workers, :pid, page.worker_pid), page.worker_top, page.focus == 2)
    end
    worker = workers_selected_worker(page)
    title = isnothing(worker) ? "Output of the worker" : "Output of worker $(worker.pid)"
    lines = isnothing(worker) ? Tuple{String,Tachikoma.Style}[] : workers_output_lines(entries, worker.pid)
    page.worker_back, page.worker_out = workers_draw_output!(buf, wbottom, title, lines, page.worker_back, page.focus == 2)
    return workers_render_modals(page, area, buf)
end

# Draw the message about the start script and the question before a cancel over `area`.
function workers_render_modals(page::WorkersPage, area, buf)
    if !isnothing(page.notice)
        Tachikoma.render(Tachikoma.Modal(; title = "Start script", message = page.notice * "\n\nany key: close",
            confirm_label = "", cancel_label = ""), area, buf)
    elseif !isnothing(page.confirm)
        what = page.confirm === :all ? "all running allocations" : "allocation $(page.confirm_id)"
        Tachikoma.render(Tachikoma.Modal(; title = "Cancel workers",
            message = "Cancel $what?\nItems running on these workers fail.\n\ny: cancel   any other key: keep",
            confirm_label = "", cancel_label = ""), area, buf)
    end
    return nothing
end
