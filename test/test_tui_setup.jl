# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Juleana
using Tachikoma: Tachikoma, KeyEvent, MouseEvent, TestBackend, Rect, find_text, row_text
using LegendDataManagement: DataPeriod, DataRun
using Test

# `legend_test_setup`, `legend_test_data`, `TEST_DIRS` and `spec`
isdefined(@__MODULE__, :legend_test_setup) || include("test_config.jl")

# Deliver the events of `m`'s task queue, as the app loop does, until `cond()` holds.
function setup_settle!(cond, m; timeout = 60)
    t_end = time() + timeout
    while time() < t_end
        Tachikoma.drain_tasks!(evt -> Tachikoma.update!(m, evt), m.queue)
        cond() && return true
        sleep(0.02)
    end
    return false
end

# Wait until all commands are answered, then read the controller state anew.
function setup_refreshed!(m)
    setup_settle!(() -> m.pending == 0 && !m.refreshing, m) || return false
    Juleana.refresh!(m)
    return setup_settle!(() -> !m.refreshing, m)
end

render_setup_page(m, width = 140, height = 30) =
    (tb = TestBackend(width, height); Juleana.render_setup(m.setup, m.snap, Rect(1, 1, width, height), tb.buf); tb)

press!(m, keys...) = foreach(k -> Tachikoma.update!(m, KeyEvent(k)), keys)

@testset "Setup page" begin
    root = mktempdir()
    l200 = legend_test_data(legend_test_setup(root, TEST_DIRS))
    p2, p3 = DataPeriod.((2, 3))
    r0, r6, r7 = DataRun.((0, 6, 7))
    args = Dict{String,Any}("config" => joinpath(dirname(@__DIR__), "config", "processing_config.json"))
    cfg = ProcessingConfig(;
        processors = Dict(
            :process_energy_calibration => spec(:process_energy_calibration, :run, 1),
            :process_dsp_cal => spec(:process_dsp_cal, :run, 2; enabled = false)),
        p_processors = Dict(:p_process_aoe_cut => spec(:p_process_aoe_cut, :partition, 1;
            dependencies = [:process_dsp_cal])))
    function new_session()
        periods, run_status, partition_status = Juleana.setup_dependency_graph(
            l200, cfg, [p2, p3], nothing, run_steps(cfg), partition_steps(cfg))
        return DataflowSession(; args, l200, config = cfg, periods,
            run_steps = run_steps(cfg), partition_steps = partition_steps(cfg), run_status, partition_status)
    end
    run_stub(cfg, l200, period, run; reprocess = false) = nothing
    part_stub(cfg, l200, period; reprocess = false, only_first_period = false) = false
    processors = Dict{Symbol,Any}(:process_energy_calibration => run_stub, :process_dsp_cal => run_stub,
        :p_process_aoe_cut => part_stub)
    new_tui() = Juleana.JuleanaTUI(DataflowController(new_session(); processors))

    @testset "checklists follow the controller" begin
        m = new_tui()
        @test setup_refreshed!(m)
        page = m.setup
        @test Juleana.checked(page.periods) == [(p2, r6), (p2, r7), (p3, r0)]
        @test Juleana.checked(page.run_procs) == [:process_energy_calibration]
        @test Juleana.checked(page.part_procs) == [:p_process_aoe_cut]
        @test [i.key for i in page.run_procs.groups[1].items] == [:process_energy_calibration, :process_dsp_cal]
        dsp = page.run_procs.groups[1].items[2]
        @test dsp.tags == ["cal", "rank 2", "disabled"]
        @test page.part_procs.groups[1].items[1].tags == ["cal", "rank 1", "deps: process_dsp_cal"]

        tb = render_setup_page(m)
        for text in ("Periods / runs", "Run processors", "Partition processors", "Reprocess: config",
                "Check dependencies: yes", "Periods: 2 (p02, p03)", "Runs: 3", "Run steps: 1 × 3 runs",
                "Partition steps: 1 × 2 periods", "s: start")
            @test find_text(tb, text) !== nothing
        end

        # a change in the controller shows up in the checklists
        dispatch!(m.ctrl, SelectRuns(Dict(2 => [7])))
        @test setup_refreshed!(m)
        @test Juleana.checked(page.periods) == [(p2, r7)]
    end

    @testset "selections become controller commands" begin
        m = new_tui()
        @test setup_refreshed!(m)
        # rows: p02, r006, r007, p03, r000
        press!(m, :down, :down, ' ')
        @test setup_refreshed!(m)
        @test m.snap.runs == Dict(p2 => [r6])
        @test m.snap.periods == [p2, p3]
        press!(m, :down, ' ')
        @test setup_refreshed!(m)
        @test m.snap.periods == [p2]
        @test isnothing(m.command_error)

        press!(m, :tab)
        @test m.setup.focus == 2 && m.setup.run_procs.focused && !m.setup.periods.focused
        press!(m, ' ')
        @test setup_refreshed!(m)
        @test isempty(m.snap.run_steps)
        press!(m, 'c')
        @test setup_refreshed!(m)
        @test m.snap.run_steps == [:process_energy_calibration, :process_dsp_cal]
        press!(m, 'p')
        @test setup_refreshed!(m)
        @test isempty(m.snap.run_steps)

        # `d` adds the dependency of the partition step and the run steps ranked before it
        press!(m, :tab, 'n', 'd')
        @test setup_refreshed!(m)
        @test isempty(m.snap.partition_steps) && isempty(m.snap.run_steps)
        press!(m, 'a', 'd')
        @test setup_refreshed!(m)
        @test m.snap.partition_steps == [:p_process_aoe_cut]
        @test m.snap.run_steps == [:process_energy_calibration, :process_dsp_cal]

        # options pane
        press!(m, :tab)
        @test m.setup.focus == 4 && !m.setup.part_procs.focused
        press!(m, ' ')
        @test setup_refreshed!(m)
        @test m.snap.reprocess === true
        press!(m, ' ')
        @test setup_refreshed!(m)
        @test m.snap.reprocess === false
        press!(m, :down, :enter)
        @test setup_refreshed!(m)
        @test !m.snap.check_dependencies
        press!(m, :down, ' ')
        @test setup_refreshed!(m)
        @test m.snap.analysis_runs_only == !cfg.analysis_runs_only
        press!(m, :tab)
        @test m.setup.focus == 1 && m.setup.periods.focused
        press!(m, :backtab)
        @test m.setup.focus == 4

        # start
        press!(m, 's')
        @test setup_refreshed!(m)
        wait(m.ctrl)
        @test setup_refreshed!(m)
        @test m.snap.outcome === :finished
    end

    @testset "action keys" begin
        page = Juleana.SetupPage()
        sent = ControllerCommand[]
        for (key, expected) in (('s', StartProcessing), ('x', StopProcessing), ('X', StopProcessing),
                ('r', ReloadConfig), ('g', ResetDependencyGraph))
            @test Juleana.setup_key!(page, KeyEvent(key), nothing, cmd -> push!(sent, cmd))
            @test last(sent) isa expected
        end
        @test !sent[2].force && sent[3].force
        # keys the page does not use go to the interface
        @test !Juleana.setup_key!(page, KeyEvent('q'), nothing, cmd -> push!(sent, cmd))
        @test !Juleana.setup_key!(page, KeyEvent('2'), nothing, cmd -> push!(sent, cmd))
        @test length(sent) == 5
    end

    @testset "pending commands keep the local selection" begin
        m = new_tui()
        @test setup_refreshed!(m)
        snap = m.snap
        Juleana.set_checked!(m.setup.periods, [(p3, r0)])
        Juleana.sync_setup!(m.setup, snap; pending = true)
        @test Juleana.checked(m.setup.periods) == [(p3, r0)]
        Juleana.sync_setup!(m.setup, snap)
        @test Juleana.checked(m.setup.periods) == [(p2, r6), (p2, r7), (p3, r0)]
    end

    @testset "a read older than an answered command is not shown" begin
        m = new_tui()
        @test setup_refreshed!(m)
        snap, prog, busy = m.snap, m.progress, m.busy
        Juleana.set_checked!(m.setup.periods, [(p3, r0)])
        # a command was answered after this read had started
        m.answered += 1
        m.refreshing = true
        Tachikoma.update!(m, Tachikoma.TaskEvent(:refresh, (m.answered - 1, snap, prog, busy)))
        @test Juleana.checked(m.setup.periods) == [(p3, r0)]
        # and the page reads again
        @test m.refreshing
        @test setup_settle!(() -> !m.refreshing, m)
        @test Juleana.checked(m.setup.periods) == [(p2, r6), (p2, r7), (p3, r0)]
    end

    @testset "selected runs that are not on disk" begin
        session = new_session()
        session.runs = Dict(p2 => [r6, DataRun(9)])
        m = Juleana.JuleanaTUI(DataflowController(session; processors))
        @test setup_refreshed!(m)
        @test Juleana.checked(m.setup.periods) == [(p2, r6), (p3, r0)]
    end

    @testset "mouse" begin
        m = new_tui()
        @test setup_refreshed!(m)
        press!(m, :tab)
        render_setup_page(m)
        # first row of the periods pane: the p02 group
        list = m.setup.periods.list
        Tachikoma.update!(m, MouseEvent(list.x + 2, list.y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
        @test m.setup.focus == 1 && m.setup.periods.focused
        @test setup_refreshed!(m)
        @test m.snap.periods == [p3]
    end
end
