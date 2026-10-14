# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

const TUI_PAGES = ("Setup", "Workers", "Reports", "Progress")

# Seconds a new warning or error stays in the status bar.
const ALERT_SECONDS = 10.0

"""
    MessageBuffer(capacity::Integer = 1000)

Logger that keeps the last `capacity` log messages and lines of captured terminal output
as text, for the terminal user interface. Records below `Info` and progress bar records
of ProgressLogging are dropped. The newest warning or error, from a log record or from
an output line containing `Warning:` or `Error:`, is kept as the alert of the buffer.

[`Juleana.message_lines`](@ref) returns the kept lines.
"""
mutable struct MessageBuffer <: AbstractLogger
    const lock::ReentrantLock
    const lines::Vector{String}
    const capacity::Int
    # unfinished last line of each captured stream
    const partial::Dict{Symbol,String}
    alert::Union{Nothing,NamedTuple{(:level, :text, :time),Tuple{LogLevel,String,Float64}}}
end

function MessageBuffer(capacity::Integer = 1000)
    capacity > 0 || throw(ArgumentError("MessageBuffer: capacity must be positive, got $capacity"))
    return MessageBuffer(ReentrantLock(), String[], capacity, Dict{Symbol,String}(), nothing)
end

min_enabled_level(::MessageBuffer) = Logging.Info
shouldlog(::MessageBuffer, level, _module, group, id) = true
catch_exceptions(::MessageBuffer) = true

function push_line!(buf::MessageBuffer, line::AbstractString)
    push!(buf.lines, line)
    length(buf.lines) > buf.capacity && deleteat!(buf.lines, 1:(length(buf.lines) - buf.capacity))
    return nothing
end

function handle_message(buf::MessageBuffer, level, message, _module, group, id, file, line; kwargs...)
    message isa ProgressLogging.Progress && return nothing
    level < Logging.Info && return nothing
    text = string(message)
    for (key, value) in kwargs
        key === :exception && value isa Tuple{Exception,Any} && (value = sprint(showerror, first(value)))
        text *= "\n  $key = $value"
    end
    stamp = Dates.format(now(), dateformat"HH:MM:SS")
    @lock buf.lock begin
        for (i, l) in enumerate(split(text, '\n'))
            push_line!(buf, i == 1 ? "$stamp $(rpad(string(level), 5)) $l" : "               $l")
        end
        level >= Logging.Warn && (buf.alert = (; level = LogLevel(level), text = first(split(text, '\n')), time = time()))
    end
    return nothing
end

"""
    Juleana.append_output!(buf::MessageBuffer, stream::Symbol, text::AbstractString)

Add `text` written to the captured output `stream` (`:stdout` or `:stderr`) to `buf`,
line by line; an unfinished last line waits for the rest of its text.
"""
function append_output!(buf::MessageBuffer, stream::Symbol, text::AbstractString)
    @lock buf.lock begin
        pieces = split(get(buf.partial, stream, "") * text, '\n')
        buf.partial[stream] = pop!(pieces)
        for l in pieces
            l = rstrip(l, '\r')
            isempty(strip(l)) && continue
            push_line!(buf, l)
            m = match(r"(Warning|Error):\s*(.*)$", l)
            isnothing(m) || (buf.alert = (; level = m[1] == "Error" ? Logging.Error : Logging.Warn, text = String(m[2]), time = time()))
        end
    end
    return nothing
end

"""
    Juleana.message_lines(buf::MessageBuffer)

Return a copy of the lines kept in `buf`, oldest first.
"""
message_lines(buf::MessageBuffer) = @lock buf.lock copy(buf.lines)

"""
    mutable struct JuleanaTUI <: Tachikoma.Model

State of the terminal user interface opened by [`Juleana.run_tui`](@ref).

`JuleanaTUI(ctrl::DataflowController, messages::MessageBuffer = MessageBuffer())` shows
the dataflow of `ctrl`. Controller commands run one after another in a background task,
in the order they were sent, and state reads run in background tasks of the interface's
`Tachikoma.TaskQueue`, so the interface never waits for the controller; the latest
state read from it is kept in the fields `snap`, `progress` and `busy`.

A left click on a page's tab opens the page; other mouse events go to the visible page.

Keys: the visible page gets each key first (see [`Juleana.setup_key!`](@ref) for the
Setup page and [`Juleana.progress_key!`](@ref) for the Progress page); otherwise `1` to
`4` switch pages and `q` or Ctrl-C quits. While processing runs, quitting asks first: `s` stops processing after the running items and quits when the
run has ended, `q` quits at once, ending the run and the workers connected to this
process, and `c` or Escape keeps the interface open.
"""
mutable struct JuleanaTUI <: Tachikoma.Model
    const ctrl::DataflowController
    const messages::MessageBuffer
    const queue::Tachikoma.TaskQueue
    const commands::Channel{ControllerCommand}
    const setup::SetupPage
    const progress_page::ProgressPage
    const tabs::Tachikoma.TabBar
    # commands sent and not yet answered, and commands answered so far
    pending::Int
    answered::Int
    page::Int
    quit::Bool
    # `:quit` while the quit dialog is open
    dialog::Union{Nothing,Symbol}
    quit_after_stop::Bool
    refreshing::Bool
    timer::Union{Nothing,Tachikoma.CancelToken}
    snap::Any
    progress::Any
    busy::Vector{BusyItem}
    command_error::Union{Nothing,String}
end

function JuleanaTUI(ctrl::DataflowController, messages::MessageBuffer = MessageBuffer())
    m = JuleanaTUI(ctrl, messages, Tachikoma.TaskQueue(), Channel{ControllerCommand}(Inf), SetupPage(), ProgressPage(),
        Tachikoma.TabBar(collect(TUI_PAGES); focused = true), 0, 0,
        1, false, nothing, false, false, nothing, nothing, nothing, BusyItem[], nothing)
    errormonitor(Threads.@spawn run_commands(m))
    return m
end

# Dispatch the commands of `m` in order; each result comes back as a `:command` event.
function run_commands(m::JuleanaTUI)
    for cmd in m.commands
        result = try
            dispatch!(m.ctrl, cmd)
            nothing
        catch e
            e
        end
        wait(Tachikoma.spawn_task!(() -> result, m.queue, :command))
    end
end

Tachikoma.should_quit(m::JuleanaTUI) = m.quit
Tachikoma.task_queue(m::JuleanaTUI) = m.queue

"""
    Juleana.send_command!(m::JuleanaTUI, cmd::ControllerCommand)

Queue `cmd` for the controller of `m`; the commands are dispatched one after another in
a background task. A rejected command shows its error in the status bar.
"""
function send_command!(m::JuleanaTUI, cmd::ControllerCommand)
    m.pending += 1
    put!(m.commands, cmd)
    return nothing
end

# Read the controller state in a background task, one read at a time. The read carries
# the number of commands answered when it started, so that a read older than an answer
# is recognized.
function refresh!(m::JuleanaTUI)
    m.refreshing && return nothing
    m.refreshing = true
    ctrl, answered = m.ctrl, m.answered
    Tachikoma.spawn_task!(() -> (answered, snapshot(ctrl), progress(ctrl), busy_workers(ctrl)), m.queue, :refresh)
    return nothing
end

# Start the periodic reads of the controller state and load the session if none is loaded.
function start!(m::JuleanaTUI)
    m.timer = Tachikoma.spawn_timer!(m.queue, :tick, 0.5; repeat = true)
    snapshot(m.ctrl).state === :idle && send_command!(m, LoadSession())
    refresh!(m)
    return nothing
end

Tachikoma.init!(m::JuleanaTUI, ::Tachikoma.Terminal) = start!(m)

function Tachikoma.cleanup!(m::JuleanaTUI)
    isnothing(m.timer) || Tachikoma.cancel!(m.timer)
    close(m.commands)
    return nothing
end

processing(m::JuleanaTUI) = !isnothing(m.snap) && m.snap.state in (:running, :stopping)

function Tachikoma.update!(m::JuleanaTUI, evt::Tachikoma.TaskEvent)
    if evt.id === :tick
        refresh!(m)
    elseif evt.id === :refresh
        m.refreshing = false
        evt.value isa Exception && throw(evt.value)
        answered, m.snap, m.progress, m.busy = evt.value
        # a read from before the last answer may miss its command: keep the page, read again
        answered == m.answered ? sync_setup!(m.setup, m.snap; pending = m.pending > 0) : refresh!(m)
        m.quit_after_stop && !processing(m) && (m.quit = true)
    elseif evt.id === :command
        m.pending -= 1
        m.answered += 1
        m.command_error = evt.value isa Exception ? sprint(showerror, evt.value) : nothing
        refresh!(m)
    end
    return nothing
end

function Tachikoma.update!(m::JuleanaTUI, evt::Tachikoma.KeyEvent)
    ctrl_c = evt.key == :ctrl_c || (evt.key == :ctrl && evt.char == 'c')
    if m.dialog === :quit
        if evt.key == :char && evt.char == 's'
            m.dialog, m.quit_after_stop = nothing, true
            m.snap.state === :running && send_command!(m, StopProcessing())
        elseif evt.key == :char && evt.char == 'q'
            m.quit = true
        elseif evt.key == :escape || (evt.key == :char && evt.char == 'c') || ctrl_c
            m.dialog = nothing
        end
        return nothing
    end
    n = length(TUI_PAGES)
    m.page == 1 && !ctrl_c && setup_key!(m.setup, evt, m.snap, cmd -> send_command!(m, cmd)) && return nothing
    m.page == 4 && !ctrl_c && progress_key!(m.progress_page, evt, m.progress) && return nothing
    if ctrl_c || (evt.key == :char && evt.char == 'q')
        processing(m) ? (m.dialog = :quit) : (m.quit = true)
    elseif evt.key == :char && '1' <= evt.char <= '0' + n
        m.page = evt.char - '0'
    end
    return nothing
end

function Tachikoma.update!(m::JuleanaTUI, evt::Tachikoma.MouseEvent)
    if isnothing(m.dialog)
        if Tachikoma.handle_mouse!(m.tabs, evt) === :changed
            m.page = m.tabs.active
            return nothing
        end
        m.page == 1 && setup_mouse!(m.setup, evt, m.snap, cmd -> send_command!(m, cmd))
        m.page == 4 && progress_mouse!(m.progress_page, evt, m.progress)
    end
    return nothing
end

format_duration(seconds::Real) = (s = round(Int, seconds); join(lpad.((s ÷ 3600, (s % 3600) ÷ 60, s % 60), 2, '0'), ":"))

# Spans of the status bar: controller state, last run, workers, progress and elapsed time
# on the left; on the right a rejected command, else the latest alert, else the error of
# the last load or run.
function status_spans(m::JuleanaTUI)
    left = Tachikoma.Span[]
    push!(left, Tachikoma.Span(" " * (isnothing(m.snap) ? "starting" : string(m.snap.state)) * " ", Tachikoma.tstyle(:accent, bold = true)))
    if !isnothing(m.snap)
        snap = m.snap
        isnothing(snap.outcome) || push!(left, Tachikoma.Span(" last run: $(snap.outcome) ", Tachikoma.tstyle(:text)))
        abandoned = count(b -> b.abandoned, m.busy)
        workers = " workers: $(snap.nworkers), $(length(m.busy)) busy" * (abandoned > 0 ? ", $abandoned abandoned" : "") * " "
        push!(left, Tachikoma.Span(workers, Tachikoma.tstyle(:text)))
        if !isnothing(snap.started) && !isnothing(m.progress)
            push!(left, Tachikoma.Span(" $(round(Int, 100 * m.progress.fraction))% ", Tachikoma.tstyle(:text)))
            stop_time = something(snap.finished, now(UTC))
            push!(left, Tachikoma.Span(" " * format_duration((stop_time - snap.started) / Millisecond(1000)) * " ", Tachikoma.tstyle(:text_dim)))
        end
    end
    right = Tachikoma.Span[]
    if !isnothing(m.command_error)
        push!(right, Tachikoma.Span(" " * first(split(m.command_error, '\n')) * " ", Tachikoma.tstyle(:error, bold = true)))
    else
        alert = @lock m.messages.lock m.messages.alert
        if !isnothing(alert) && time() - alert.time < ALERT_SECONDS
            style = alert.level >= Logging.Error ? Tachikoma.tstyle(:error, bold = true) : Tachikoma.tstyle(:warning)
            push!(right, Tachikoma.Span(" " * alert.text * " ", style))
        elseif !isnothing(m.snap) && !isnothing(m.snap.last_error)
            # stays until the next load or run, so that a failed load does not look like a hang
            push!(right, Tachikoma.Span(" " * first(split(m.snap.last_error, '\n')) * " ", Tachikoma.tstyle(:error, bold = true)))
        end
    end
    return left, right
end

function Tachikoma.view(m::JuleanaTUI, f::Tachikoma.Frame)
    tabs = m.tabs
    tabs.active = m.page
    tab_h = Tachikoma.tab_height(tabs.tab_style.decoration)
    layout = Tachikoma.Layout(
        Tachikoma.Vertical, [Tachikoma.Fixed(tab_h), Tachikoma.Fill(), Tachikoma.Fixed(1), Tachikoma.Fixed(1)]
    )
    tab_area, body_area, help_area, status_area = Tachikoma.split_layout(layout, f.area)

    Tachikoma.render(tabs, tab_area, f.buffer)
    if m.page == 1
        render_setup(m.setup, m.snap, body_area, f.buffer)
    elseif m.page == 4
        render_progress(m.progress_page, m.progress, m.busy, body_area, f.buffer)
    else
        body = Tachikoma.Paragraph(
            "This page is not available yet.";
            block = Tachikoma.Block(
                title = TUI_PAGES[m.page],
                border_style = Tachikoma.tstyle(:border),
                title_style = Tachikoma.tstyle(:title),
            ),
        )
        Tachikoma.render(body, body_area, f.buffer)
    end
    Tachikoma.set_string!(
        f.buffer, help_area.x, help_area.y,
        m.page == 4 ? "↑↓ PgUp PgDn: move   Enter ←→: fold   f: follow   1-4: switch page   q: quit" :
            "1-4: switch page   q: quit", Tachikoma.tstyle(:text_dim),
    )
    left, right = status_spans(m)
    Tachikoma.render(Tachikoma.StatusBar(; left, right), status_area, f.buffer)

    if m.dialog === :quit
        modal = Tachikoma.Modal(;
            title = "Processing runs",
            message = "s: stop after the running items, then quit\n" *
                "q: quit now, ending the run and its workers\n" *
                "c: cancel, keep processing",
            confirm_label = "", cancel_label = "",
        )
        Tachikoma.render(modal, f.area, f.buffer)
    end
    return nothing
end

"""
    Juleana.run_tui(parsed_args::AbstractDict; processors = PROCESSORS, loader)

Open the terminal user interface with the pages Setup, Workers, Reports and Progress on
a [`DataflowController`](@ref) for the parsed command line options `parsed_args`, as
returned by [`Juleana.parse_commandline`](@ref). Returns `nothing` when the user quits.

The interface opens at once and loads the session in the background with
`loader(parsed_args)`. The default loader is [`setup_session`](@ref) without terminal
output and without starting workers: it reads the config and the LEGEND data and builds
the dependency graph. Log
messages of this process and the output of its workers are kept in a
[`Juleana.MessageBuffer`](@ref) instead of being printed; the newest warning or error is shown
in the status bar, and the error of a failed load stays there. This process also writes
its log file as in [`setup_session`](@ref). The previous global logger is restored when
the interface closes. See [`Juleana.JuleanaTUI`](@ref) for the keys.
"""
function run_tui(parsed_args::AbstractDict; processors::AbstractDict{Symbol} = PROCESSORS,
        loader = args -> setup_session(args; console = false, start_workers = false))
    messages = MessageBuffer()
    function load(args)
        session = loader(args)
        # `setup_session` installs the file logger; keep the messages for the interface too
        global_logger() === messages || global_logger(TeeLogger(global_logger(), messages))
        return session
    end
    ctrl = DataflowController(parsed_args; processors, loader = load)
    # a logger made before the interface writes to the terminal and would garble it
    previous = global_logger(messages)
    try
        Tachikoma.app(JuleanaTUI(ctrl, messages);
            on_stdout = text -> append_output!(messages, :stdout, text),
            on_stderr = text -> append_output!(messages, :stderr, text))
    finally
        global_logger(previous)
    end
    return nothing
end
