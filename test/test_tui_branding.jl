# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Juleana
using Tachikoma: Tachikoma, KeyEvent, TestBackend, Frame, Rect, GraphicsRegion, PixelSnapshot,
    find_text, row_text, style_at
using Logging: Logging, with_logger
using LegendDataManagement: DataPeriod
using Test

# `legend_test_setup`, `legend_test_data`, `TEST_DIRS` and `spec`
isdefined(@__MODULE__, :legend_test_setup) || include("test_config.jl")

function branding_render(m, width = 120, height = 36)
    tb = TestBackend(width, height)
    Tachikoma.view(m, Frame(tb.buf, Rect(1, 1, width, height), GraphicsRegion[], PixelSnapshot[]))
    return tb
end

branding_text(tb, height = 36) = join((row_text(tb, r) for r in 1:height), "\n")

function branding_settle!(cond, m; timeout = 60)
    t_end = time() + timeout
    while time() < t_end
        Tachikoma.drain_tasks!(evt -> Tachikoma.update!(m, evt), m.queue)
        cond() && return true
        sleep(0.02)
    end
    return false
end

# Read the controller state anew and wait for the result.
function branding_refreshed!(m)
    branding_settle!(() -> !m.refreshing, m) || return false
    Juleana.refresh!(m)
    return branding_settle!(() -> !m.refreshing, m)
end

@testset "Branding" begin
    @testset "logo art" begin
        # `(width, height)` in cells
        sizes = Dict(:large => (64, 16), :medium => (48, 12), :mark => (32, 14), :mark_small => (24, 10), :corner => (9, 3))
        for (name, size) in sizes
            rows = Juleana.LOGO_ART[name]
            @test Juleana.logo_size(name) == size
            @test length(rows) == 2 * size[2] && all(r -> length(r) == size[1], rows)
            @test all(r -> all(c -> c in " kgpr", r), rows)
        end
        @test sort(collect(keys(Juleana.LOGO_ART))) == sort(collect(keys(sizes)))
        @test_throws KeyError Juleana.logo_size(:huge)
    end

    @testset "fitting logo" begin
        @test Juleana.fitting_logo(64, 16) == :large
        @test Juleana.fitting_logo(63, 16) == :medium
        @test Juleana.fitting_logo(64, 15) == :medium
        @test Juleana.fitting_logo(48, 11) == :mark_small
        @test Juleana.fitting_logo(47, 15) == :mark
        @test Juleana.fitting_logo(47, 30) == :mark
        @test Juleana.fitting_logo(32, 15) == :mark
        @test Juleana.fitting_logo(32, 14) == :mark_small
        @test Juleana.fitting_logo(31, 30) == :mark_small
        @test Juleana.fitting_logo(24, 11) == :mark_small
        @test isnothing(Juleana.fitting_logo(24, 10)) && isnothing(Juleana.fitting_logo(23, 30))
        @test Juleana.logo_block_size(:medium) == (48, 12) && Juleana.logo_block_size(:mark) == (32, 15)
        tb = TestBackend(40, 20)
        Juleana.render_logo_block(:mark, 3, 2, tb.buf; max_x = 40, max_y = 20)
        @test find_text(tb, "Juleana") == (; x = 3 + (32 - 7) ÷ 2, y = 2 + 14)
        tb = TestBackend(60, 20)
        Juleana.render_logo_block(:medium, 3, 2, tb.buf; max_x = 60, max_y = 20)
        @test find_text(tb, "Juleana") === nothing
    end

    @testset "half-block mapping" begin
        art = ["k r ", "  rg", "kp  ", " k  "]
        @test Juleana.logo_size(art) == (4, 2)
        tb = TestBackend(10, 5)
        Juleana.render_logo(art, 2, 2, tb.buf)
        text = Tachikoma.theme().text
        red, green, purple = Juleana.TITLE_COLORS
        # cells from (top, bottom) pixels: outline over nothing, nothing, red over red, nothing over green
        @test rstrip(row_text(tb, 2)) == " ▀ █▄"
        @test style_at(tb, 2, 2).fg == text
        @test style_at(tb, 4, 2).fg == red
        @test style_at(tb, 5, 2).fg == green
        # outline over nothing, purple over outline
        @test rstrip(row_text(tb, 3)) == " ▀▀"
        @test style_at(tb, 2, 3).fg == text
        @test style_at(tb, 3, 3).fg == purple && style_at(tb, 3, 3).bg == text
        # cells without pixels stay empty
        @test isempty(strip(row_text(tb, 1))) && isempty(strip(row_text(tb, 4)))
        # clipping at `max_x` and `max_y`
        tb = TestBackend(10, 5)
        Juleana.render_logo(art, 2, 2, tb.buf; max_x = 3, max_y = 2)
        @test rstrip(row_text(tb, 2)) == " ▀" && isempty(strip(row_text(tb, 3)))
        @test_throws "unknown palette character" Juleana.render_logo(["x"], 1, 1, TestBackend(3, 3).buf)
        # parts outside of the buffer are dropped
        tb = TestBackend(5, 3)
        Juleana.render_logo(:large, -24, -4, tb.buf)
        @test any(r -> !isempty(strip(row_text(tb, r))), 1:3)
    end

    root = mktempdir()
    l200 = legend_test_data(legend_test_setup(root, TEST_DIRS))
    args = Dict{String,Any}("config" => joinpath(dirname(@__DIR__), "config", "processing_config.json"))
    cfg = ProcessingConfig(;
        processors = Dict(:process_energy_calibration => spec(:process_energy_calibration, :run, 1)),
        p_processors = Dict{Symbol,ProcessorSpec}())
    function new_session(parsed_args = args)
        periods, run_status, partition_status = Juleana.setup_dependency_graph(
            l200, cfg, [DataPeriod(2)], nothing, run_steps(cfg), partition_steps(cfg))
        return DataflowSession(; args = parsed_args, l200, config = cfg, periods,
            run_steps = run_steps(cfg), partition_steps = partition_steps(cfg), run_status, partition_status)
    end
    quick_step(cfg, l200, period, run; reprocess = false) = nothing
    processors = Dict{Symbol,Any}(:process_energy_calibration => quick_step)
    docs_url = "https://legend-exp.github.io/Juleana.jl/stable/"

    @testset "startup screen" begin
        function slow_loader(parsed_args)
            sleep(0.3)
            return new_session(parsed_args)
        end
        m = Juleana.JuleanaTUI(DataflowController(args; processors, loader = slow_loader); splash_seconds = 5.0)
        # not started: the page is shown
        @test !m.splash && find_text(branding_render(m), "Periods / runs") !== nothing
        Juleana.start!(m)
        tb = branding_render(m)
        @test find_text(tb, "Loading the session…") !== nothing
        @test find_text(tb, docs_url) !== nothing
        @test find_text(tb, Juleana.juleana_version()) !== nothing
        @test find_text(tb, "Periods / runs") === nothing
        # frame, tabs and key row stay
        @test find_text(tb, "JuLeAna") !== nothing && find_text(tb, "1 Setup") !== nothing && find_text(tb, "q quit") !== nothing
        # the link carries the hyperlink
        link = find_text(tb, docs_url)
        @test style_at(tb, link.x, link.y).hyperlink == docs_url
        # the large logo is drawn
        @test count(r -> occursin("█", row_text(tb, r)) || occursin("▀", row_text(tb, r)), 1:36) >= 16
        @test branding_settle!(() -> !isnothing(m.snap) && m.snap.state === :ready, m)
        # loaded, but the minimum time has not passed
        @test find_text(branding_render(m), "Session loaded") !== nothing
        m.started_at -= 5.0
        tb = branding_render(m)
        @test find_text(tb, docs_url) === nothing && find_text(tb, "Periods / runs") !== nothing
        Tachikoma.update!(m, Tachikoma.TaskEvent(:tick, nothing))
        @test !m.splash
        Tachikoma.cleanup!(m)
    end

    @testset "a key ends the startup screen and is not passed on" begin
        m = Juleana.JuleanaTUI(DataflowController(args; processors, loader = new_session); splash_seconds = 60.0)
        Juleana.start!(m)
        @test branding_settle!(() -> !isnothing(m.snap) && m.snap.state === :ready, m)
        @test Juleana.splash_active(m)
        Tachikoma.update!(m, KeyEvent('3'))
        @test m.page == 1 && !m.splash && !Juleana.splash_active(m)
        Tachikoma.update!(m, KeyEvent('3'))
        @test m.page == 3
        # a quit key ends the screen without quitting
        m2 = Juleana.JuleanaTUI(DataflowController(args; processors, loader = new_session); splash_seconds = 60.0)
        Juleana.start!(m2)
        Tachikoma.update!(m2, KeyEvent('q'))
        @test !m2.quit && !m2.splash
        Tachikoma.cleanup!(m)
        Tachikoma.cleanup!(m2)
    end

    @testset "a failed load ends the startup screen" begin
        m = Juleana.JuleanaTUI(DataflowController(args; processors, loader = _ -> error("no data config")); splash_seconds = 0.2)
        with_logger(Logging.NullLogger()) do
            Juleana.start!(m)
            @test branding_settle!(() -> !isnothing(m.snap) && !isnothing(m.snap.last_error), m)
            @test find_text(branding_render(m), "Loading the session failed") !== nothing || !Juleana.splash_active(m)
            sleep(0.25)
            @test !Juleana.splash_active(m)
        end
        Tachikoma.cleanup!(m)
    end

    @testset "startup screen sizes" begin
        m = Juleana.JuleanaTUI(DataflowController(args; processors, loader = new_session); splash_seconds = 60.0)
        m.splash, m.started_at = true, time()
        count_logo(tb, h) = count(r -> any(c -> c in "▀▄█", row_text(tb, r)), 5:h)
        # large logo (16 rows), medium (12 rows), the mark (14 rows and a caption), text only
        @test count_logo(branding_render(m, 120, 36), 36) == 16
        @test count_logo(branding_render(m, 70, 26), 26) == 12
        @test count_logo(branding_render(m, 70, 20), 20) == 0
        @test count_logo(branding_render(m, 40, 28), 28) == 14 && find_text(branding_render(m, 40, 28), "Juleana") !== nothing
        @test count_logo(branding_render(m, 40, 25), 25) == 10
        @test find_text(branding_render(m, 70, 20), docs_url) !== nothing
        text_only = branding_render(m, 70, 10)
        @test find_text(text_only, docs_url) !== nothing && count_logo(text_only, 10) == 0
        Tachikoma.cleanup!(m)
    end

    @testset "corner logo" begin
        m = Juleana.JuleanaTUI(DataflowController(new_session(); processors))
        version = Juleana.juleana_version()
        wide = branding_render(m, 120, 36)
        @test find_text(wide, version) !== nothing
        pos = find_text(wide, version)
        @test pos.y == 3 && pos.x > 80
        @test any(c -> c in "▀▄█", row_text(wide, 2)) && any(c -> c in "▀▄█", row_text(wide, 4))
        # the tab bar line ends one cell before the logo and leaves nothing under its cells
        w, h = Juleana.logo_size(:corner)
        version_col = length(SubString(row_text(wide, 3), 1, pos.x - 1)) + 1
        left = version_col - 1 - w
        bottom = collect(row_text(wide, 4))
        @test h == 3 && !any(c -> c in "─╯╰", bottom[(left - 1):(end - 1)])
        @test bottom[left - 2] == '─'
        @test all(c -> !(c in "─╯╰"), collect(row_text(wide, 2))[left:(end - 1)])
        narrow = branding_render(m, 60, 36)
        @test find_text(narrow, version) === nothing
        @test find_text(narrow, "4 Progress") !== nothing
        @test count(==('─'), row_text(narrow, 4)) > 40 && !any(c -> c in "▀▄█", row_text(narrow, 4))
        Tachikoma.cleanup!(m)
    end

    @testset "Setup page logo" begin
        m = Juleana.JuleanaTUI(DataflowController(new_session(); processors))
        @test branding_refreshed!(m)
        logo_rows(tb, h = 36) = [r for r in 6:h if any(c -> c in "▀▄█", row_text(tb, r))]
        # the mark with its caption ends on the last row inside the pane
        tall = branding_render(m, 120, 36)
        @test find_text(tall, "s: start") === nothing && find_text(tall, "Runs: ") !== nothing
        rows = logo_rows(tall)
        @test length(rows) == 14 && last(rows) == 31 && find_text(tall, "Juleana").y == 32
        # a wider pane takes the medium logo, which has the lettering in its art
        wide = branding_render(m, 180, 44)
        rows = logo_rows(wide, 44)
        @test length(rows) == 12 && last(rows) == 40 && find_text(wide, "Juleana") === nothing
        # a narrower pane takes the small mark
        small = branding_render(m, 100, 30)
        @test length(logo_rows(small, 30)) == 10 && find_text(small, "Juleana").y == 26
        # a pane without room for the logo gets none
        short = branding_render(m, 120, 20)
        @test isempty(logo_rows(short, 20))
        narrow = branding_render(m, 80, 36)
        @test isempty(logo_rows(narrow))
        Tachikoma.cleanup!(m)
    end

    @testset "key help" begin
        m = Juleana.JuleanaTUI(DataflowController(new_session(); processors))
        @test branding_refreshed!(m)
        Tachikoma.update!(m, KeyEvent('?'))
        @test m.help
        tb = branding_render(m)
        for text in ("Keys", "start workers", "start processing", "Ctrl-G", "Setup page", "All pages", docs_url)
            @test find_text(tb, text) !== nothing
        end
        @test find_text(tb, "follow the running step") === nothing
        link = find_text(tb, docs_url)
        @test style_at(tb, link.x, link.y).hyperlink == docs_url
        # other keys do nothing while it is open; `q` closes it without quitting
        Tachikoma.update!(m, KeyEvent('3'))
        @test m.page == 1 && m.help
        Tachikoma.update!(m, KeyEvent('q'))
        @test !m.help && !m.quit
        for key in (KeyEvent(:escape), KeyEvent('?'))
            Tachikoma.update!(m, KeyEvent('?'))
            Tachikoma.update!(m, key)
            @test !m.help
        end
        @test find_text(branding_render(m), "start workers") === nothing

        # the Progress page lists its own keys
        Tachikoma.update!(m, KeyEvent('4'))
        Tachikoma.update!(m, KeyEvent('?'))
        tb = branding_render(m)
        @test find_text(tb, "follow the running step") !== nothing && find_text(tb, "start workers") === nothing
        Tachikoma.update!(m, KeyEvent('?'))
        @test !m.help

        # the Log page lists its own keys
        Tachikoma.update!(m, KeyEvent('5'))
        Tachikoma.update!(m, KeyEvent('?'))
        tb = branding_render(m)
        @test find_text(tb, "Log page") !== nothing && find_text(tb, "cycle the level") !== nothing &&
            find_text(tb, "follow the running step") === nothing
        Tachikoma.update!(m, KeyEvent('?'))
        @test !m.help

        # a small screen clips the panel
        Tachikoma.update!(m, KeyEvent('1'))
        Tachikoma.update!(m, KeyEvent('?'))
        @test find_text(branding_render(m, 40, 12), "Keys") !== nothing
        Tachikoma.update!(m, KeyEvent(:escape))

        # the filter and the kwargs editor receive `?` as text
        Tachikoma.update!(m, KeyEvent('/'))
        Tachikoma.update!(m, KeyEvent('?'))
        @test !m.help && m.setup.periods.filter == "?"
        Tachikoma.update!(m, KeyEvent(:escape))
        Tachikoma.update!(m, KeyEvent(:tab))
        Tachikoma.update!(m, KeyEvent('e'))
        @test !isnothing(m.setup.editor)
        Tachikoma.update!(m, KeyEvent('?'))
        @test !m.help
        Tachikoma.cleanup!(m)
    end

    @testset "key row lists the help key" begin
        m = Juleana.JuleanaTUI(DataflowController(new_session(); processors))
        Tachikoma.update!(m, KeyEvent('3'))
        @test occursin("? help", row_text(branding_render(m, 120, 36), 35))
        Tachikoma.cleanup!(m)
    end
end # testset
