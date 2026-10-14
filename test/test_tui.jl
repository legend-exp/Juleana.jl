# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Juleana
using Tachikoma: Tachikoma, KeyEvent, TestBackend, Frame, Rect, GraphicsRegion,
    PixelSnapshot, find_text, row_text
using Logging: Logging, with_logger
using LegendDataManagement: DataPeriod, DataRun, FileKey, ProcessStatus
using ProgressLogging: ProgressLogging
using Test

# `legend_test_setup`, `legend_test_data`, `TEST_DIRS` and `spec`
isdefined(@__MODULE__, :legend_test_setup) || include("test_config.jl")

const TuiLog = NamedTuple{(:Filekey, :Status, :Error)}

# Render `m` into a `width` x `height` test backend.
function render_tui(m, width = 100, height = 30)
    tb = TestBackend(width, height)
    frame = Frame(tb.buf, Rect(1, 1, width, height), GraphicsRegion[], PixelSnapshot[])
    Tachikoma.view(m, frame)
    return tb
end

screen_text(tb, height = 30) = join((row_text(tb, r) for r in 1:height), "\n")

# Deliver the events of `m`'s task queue, as the app loop does, until `cond()` holds.
function settle!(cond, m; timeout = 60)
    t_end = time() + timeout
    while time() < t_end
        Tachikoma.drain_tasks!(evt -> Tachikoma.update!(m, evt), m.queue)
        cond() && return true
        sleep(0.02)
    end
    return false
end

# Read the controller state anew, after any read already under way, and wait for the result.
function refreshed!(m)
    settle!(() -> !m.refreshing, m) || return false
    Juleana.refresh!(m)
    return settle!(() -> !m.refreshing, m)
end

@testset "TUI" begin
    root = mktempdir()
    l200 = legend_test_data(legend_test_setup(root, TEST_DIRS))
    p2 = DataPeriod(2)
    args = Dict{String,Any}("config" => joinpath(dirname(@__DIR__), "config", "processing_config.json"))
    cfg = ProcessingConfig(;
        processors = Dict(:process_energy_calibration => spec(:process_energy_calibration, :run, 1)),
        p_processors = Dict{Symbol,ProcessorSpec}())
    function new_session(parsed_args = args)
        periods, run_status, partition_status = Juleana.setup_dependency_graph(
            l200, cfg, [p2], nothing, run_steps(cfg), partition_steps(cfg))
        return DataflowSession(; args = parsed_args, l200, config = cfg, periods,
            run_steps = run_steps(cfg), partition_steps = partition_steps(cfg), run_status, partition_status)
    end
    quick_step(cfg, l200, period, run; reprocess = false) = nothing
    processors = Dict{Symbol,Any}(:process_energy_calibration => quick_step)

    @testset "render before the first read" begin
        m = Juleana.JuleanaTUI(DataflowController(args; processors, loader = new_session))
        @test m.page == 1 && !Tachikoma.should_quit(m)
        tb = render_tui(m)
        for name in Juleana.TUI_PAGES
            @test find_text(tb, name) !== nothing
        end
        @test find_text(tb, "Loading the session") !== nothing
        @test find_text(tb, "1-4: switch page   q: quit") !== nothing
        @test find_text(tb, "starting") !== nothing
        Tachikoma.update!(m, KeyEvent('2'))
        @test find_text(render_tui(m), "This page is not available yet.") !== nothing
    end

    @testset "page switching" begin
        m = Juleana.JuleanaTUI(DataflowController(new_session(); processors))
        Tachikoma.update!(m, KeyEvent('3'))
        @test m.page == 3
        Tachikoma.update!(m, KeyEvent('5'))
        @test m.page == 3
        # Tab moves between the panes of a page, not between pages
        Tachikoma.update!(m, KeyEvent(:tab))
        @test m.page == 3
        tb = render_tui(m)
        @test count(r -> occursin("Reports", row_text(tb, r)), 1:30) == 2
        Tachikoma.update!(m, KeyEvent('1'))
        @test m.page == 1
        @test !m.quit
        # a click on a tab opens its page
        tb = render_tui(m)
        y = findfirst(r -> occursin("Progress", row_text(tb, r)), 1:30)
        x = findfirst("Progress", row_text(tb, y)).start
        Tachikoma.update!(m, Tachikoma.MouseEvent(x + 1, y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
        @test m.page == 4
        @test find_text(render_tui(m), "No processing run yet.") !== nothing
    end

    @testset "start! loads the session in the background" begin
        loaded = Threads.Atomic{Bool}(false)
        function slow_loader(parsed_args)
            sleep(0.5)
            loaded[] = true
            return new_session(parsed_args)
        end
        ctrl = DataflowController(args; processors, loader = slow_loader)
        m = Juleana.JuleanaTUI(ctrl)
        t0 = time()
        Juleana.start!(m)
        # start! returns before the session is loaded
        @test time() - t0 < 0.4 && !loaded[]
        @test settle!(() -> !isnothing(m.snap) && m.snap.state === :ready, m)
        @test loaded[]
        tb = render_tui(m)
        @test find_text(tb, " ready ") !== nothing
        @test find_text(tb, "workers: 0, 0 busy") !== nothing
        Tachikoma.cleanup!(m)
        @test m.timer.cancelled[]
        # the app calls `start!` through Tachikoma's `init!`
        @test which(Tachikoma.init!, Tuple{Juleana.JuleanaTUI,Tachikoma.Terminal}).module === Juleana
    end

    @testset "a failed load stays visible" begin
        m = Juleana.JuleanaTUI(DataflowController(args; processors, loader = _ -> error("no data config")))
        with_logger(Logging.NullLogger()) do
            Juleana.start!(m)
            @test settle!(() -> !isnothing(m.snap) && m.snap.state === :idle && !isnothing(m.snap.last_error), m)
        end
        Tachikoma.cleanup!(m)
        @test find_text(render_tui(m, 120), "no data config") !== nothing
    end

    @testset "commands and their errors" begin
        m = Juleana.JuleanaTUI(DataflowController(new_session(); processors))
        Juleana.send_command!(m, StopProcessing())
        @test settle!(() -> !isnothing(m.command_error), m)
        @test occursin("StopProcessing is not possible while the controller is :ready", m.command_error)
        @test settle!(() -> !m.refreshing, m)
        @test find_text(render_tui(m, 120), "StopProcessing is not possible") !== nothing
        # a successful command clears the error
        Juleana.send_command!(m, StartProcessing())
        @test settle!(() -> isnothing(m.command_error), m)
        wait(m.ctrl)
        @test refreshed!(m)
        @test m.snap.outcome === :finished
        text = screen_text(render_tui(m, 120))
        @test occursin("last run: finished", text) && occursin("100%", text)
    end

    @testset "quit" begin
        for key in (KeyEvent('q'), KeyEvent(:ctrl, 'c'), KeyEvent(:ctrl_c))
            m = Juleana.JuleanaTUI(DataflowController(new_session(); processors))
            @test refreshed!(m)
            Tachikoma.update!(m, key)
            @test Tachikoma.should_quit(m) && isnothing(m.dialog)
        end
    end

    @testset "quit while processing" begin
        started = Threads.Atomic{Int}(0)
        filekeys = [FileKey("l200-p02-r006-cal-20230101T00000$(i)Z") for i in 1:4]
        slow_step(cfg, l200, period, run; reprocess = false) = parallel(filekeys, TuiLog) do fk
            Threads.atomic_add!(started, 1)
            sleep(0.5)
            (processed = true, log = TuiLog((fk, ProcessStatus(1), "")))
        end
        ctrl = DataflowController(new_session(); processors = Dict{Symbol,Any}(:process_energy_calibration => slow_step))
        dispatch!(ctrl, SelectRuns([6]))
        m = Juleana.JuleanaTUI(ctrl)
        dispatch!(ctrl, StartProcessing())
        @test timedwait(() -> started[] >= 1, 60) === :ok
        @test refreshed!(m) && m.snap.state === :running

        Tachikoma.update!(m, KeyEvent('q'))
        @test m.dialog === :quit && !m.quit
        @test find_text(render_tui(m), "s: stop after the running items, then quit") !== nothing
        # page keys do nothing while the dialog is open
        Tachikoma.update!(m, KeyEvent(:tab))
        @test m.page == 1
        Tachikoma.update!(m, KeyEvent('c'))
        @test isnothing(m.dialog) && !m.quit
        Tachikoma.update!(m, KeyEvent(:ctrl_c))
        @test m.dialog === :quit
        Tachikoma.update!(m, KeyEvent(:escape))
        @test isnothing(m.dialog)

        Tachikoma.update!(m, KeyEvent('q'))
        Tachikoma.update!(m, KeyEvent('s'))
        @test isnothing(m.dialog) && !m.quit
        # quits once the run has stopped
        @test settle!(() -> (Juleana.refresh!(m); m.quit), m)
        @test snapshot(ctrl).outcome === :stopped

        # `q` in the dialog quits at once
        m2 = Juleana.JuleanaTUI(ctrl)
        m2.snap = merge(snapshot(ctrl), (; state = :running))
        Tachikoma.update!(m2, KeyEvent('q'))
        Tachikoma.update!(m2, KeyEvent('q'))
        @test m2.quit
    end

    @testset "MessageBuffer" begin
        buf = Juleana.MessageBuffer(3)
        with_logger(buf) do
            @debug "dropped"
            @info "first\nsecond line"
            @info ProgressLogging.Progress(Juleana.uuid4(), 0.5; name = "bar")
        end
        lines = Juleana.message_lines(buf)
        @test length(lines) == 2
        @test occursin(r"^\d\d:\d\d:\d\d Info  first$", lines[1]) && strip(lines[2]) == "second line"
        @test isnothing(buf.alert)
        with_logger(() -> (@warn "careful" n = 1), buf)
        lines = Juleana.message_lines(buf)
        # the capacity keeps the newest lines
        @test length(lines) == 3 && occursin("Warn  careful", lines[2]) && strip(lines[3]) == "n = 1"
        @test buf.alert.level == Logging.Warn && buf.alert.text == "careful"

        Juleana.append_output!(buf, :stdout, "      From worker 2:\tpartial")
        @test !any(contains("partial"), Juleana.message_lines(buf))
        Juleana.append_output!(buf, :stdout, " line\n      From worker 2:\t┌ Error: fit failed\n")
        lines = Juleana.message_lines(buf)
        @test lines[end-1] == "      From worker 2:\tpartial line"
        @test buf.alert.level == Logging.Error && buf.alert.text == "fit failed"
        @test_throws "capacity must be positive" Juleana.MessageBuffer(0)

        m = Juleana.JuleanaTUI(DataflowController(new_session(); processors), buf)
        @test find_text(render_tui(m), "fit failed") !== nothing
    end
end # testset
