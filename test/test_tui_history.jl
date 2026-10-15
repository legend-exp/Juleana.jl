# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Juleana
using Tachikoma: Tachikoma, KeyEvent, TestBackend, Rect, find_text, row_text
using LegendDataManagement: DataPeriod, DataRun
using Dates: DateTime
using Test

# Render the History page of `page` into a `width` x `height` test backend.
function render_history_page(page, width = 100, height = 20)
    tb = TestBackend(width, height)
    Juleana.render_history(page, Rect(1, 1, width, height), tb.buf)
    return tb
end

history_text(tb) = join((row_text(tb, r) for r in 1:tb.height), "\n")
detail_text(page) = join(first.(Juleana.history_detail(page)))

@testset "History page" begin
    p2, p3 = DataPeriod(2), DataPeriod(3)
    runs2 = DataRun.(6:15)
    r0 = DataRun(0)
    t(h) = DateTime(2026, 10, 15, h)
    processors = [(; name = :process_dsp_cal, level = :run, category = :cal),
        (; name = :process_hit_cal, level = :run, category = :cal),
        (; name = :p_process_energy_cal, level = :partition, category = :cal)]
    report(period, run, state, date) = (; period, run, path = "/rep/$period-$(something(run, "")).md", state, date)
    overview = [
        (; name = "dsp_cal", level = :run, category = "cal", reports = [report("p02", "r006", :ok, t(10)), report("p02", "r007", :warning, t(10)),
            report("p02", "r008", :failed, t(10))]),
        (; name = "energy", level = :partition, category = "cal", reports = [report("p02", nothing, :ok, t(10))])]
    step(process, level, period, run, outcome, started, finished) = (; process, level, category = :cal, period, run, outcome,
        started, finished, done = 0, failed = 0, notrun = 0)
    history = [(; started = t(11), finished = t(13), user = "u", host = "h", outcome = :failed, log_path = "/log/a",
        steps = [step(:process_dsp_cal, :run, p2, DataRun(6), :failed, t(11), t(12)),
            step(:process_dsp_cal, :run, p2, DataRun(9), :stopped, t(11), t(12)),
            step(:process_dsp_cal, :run, p3, r0, :cancelled, nothing, nothing),
            step(:p_process_energy_cal, :partition, p3, nothing, :failed, t(11), t(12))])]
    grid = Juleana.history_grid(processors, [p2 => runs2, p3 => [r0]], overview, history)

    # a page that has read `grid`
    function loaded_page()
        page = Juleana.HistoryPage()
        Juleana.history_visit!(page, (; state = :ready, outcome = nothing, started = nothing, finished = nothing))
        (request,) = Juleana.take_requests!(page)
        Juleana.history_result!(page, (; request, value = grid))
        return page
    end

    @testset "reading the grid" begin
        page = Juleana.HistoryPage()
        @test find_text(render_history_page(page), "No session loaded.") !== nothing
        Juleana.history_visit!(page, nothing)
        Juleana.history_visit!(page, (; state = :loading, outcome = nothing, started = nothing, finished = nothing))
        @test isempty(Juleana.take_requests!(page))
        ready = (; state = :ready, outcome = nothing, started = nothing, finished = nothing)
        Juleana.history_visit!(page, ready)
        Juleana.history_visit!(page, ready)
        requests = Juleana.take_requests!(page)
        @test length(requests) == 1 && requests[1].kind === :grid
        @test find_text(render_history_page(page), "Reading history…") !== nothing
        # a stale answer is dropped, the current one is taken
        Juleana.history_result!(page, (; request = (; kind = :grid, generation = requests[1].generation - 1), value = grid))
        @test isnothing(page.grid)
        Juleana.history_result!(page, (; request = requests[1], value = grid))
        @test page.grid === grid && !page.reading
        # a new processing run triggers a new read; an older answer to the first read is dropped
        Juleana.history_visit!(page, merge(ready, (; state = :running, started = t(14))))
        Juleana.history_result!(page, (; request = requests[1], value = (; periods = [], rows = [])))
        @test page.grid === grid
        (request,) = Juleana.take_requests!(page)
        Juleana.history_result!(page, (; request, error = "boom"))
        @test find_text(render_history_page(page), "boom") !== nothing
        Juleana.history_visit!(page, nothing)
        Juleana.history_result!(page, (; request, value = grid))
        @test isnothing(page.grid) && isnothing(page.error)
        # `r` reads again
        page = loaded_page()
        @test Juleana.history_key!(page, KeyEvent('r'))
        @test only(Juleana.take_requests!(page)).kind === :grid
        @test !Juleana.history_key!(page, KeyEvent('x')) && !Juleana.history_key!(page, KeyEvent('7'))
    end

    @testset "cursor and details" begin
        page = loaded_page()
        @test length(page.columns) == 11
        @test detail_text(page) == "dsp cal  p02-r006  failed  2026-10-15 12:00 UTC  history, log folder /log/a"
        Juleana.history_key!(page, KeyEvent(:right))
        @test detail_text(page) == "dsp cal  p02-r007  warning  2026-10-15 10:00 UTC  report"
        Juleana.history_key!(page, KeyEvent(:left))
        Juleana.history_key!(page, KeyEvent(:left))
        @test page.col == 1
        Juleana.history_key!(page, KeyEvent(:up))
        @test page.row == 1
        Juleana.history_key!(page, KeyEvent(:down))
        @test detail_text(page) == "hit cal  p02-r006  never processed"
        # on a partition row, the arrows move by period
        Juleana.history_key!(page, KeyEvent(:down))
        @test detail_text(page) == "energy cal  p02  ok  2026-10-15 10:00 UTC  report"
        Juleana.history_key!(page, KeyEvent(:right))
        @test page.col == 11 && detail_text(page) == "energy cal  p03  failed  2026-10-15 12:00 UTC  history, log folder /log/a"
        Juleana.history_key!(page, KeyEvent(:right))
        @test page.col == 11
        Juleana.history_key!(page, KeyEvent(:left))
        @test page.col == 1
        Juleana.history_key!(page, KeyEvent(:down))
        @test page.row == 3
        Juleana.history_key!(page, KeyEvent(:end_key))
        @test page.col == 11
        Juleana.history_key!(page, KeyEvent(:up))
        Juleana.history_key!(page, KeyEvent(:up))
        @test detail_text(page) == "dsp cal  p03-r000  cancelled  2026-10-15 13:00 UTC  history, log folder /log/a"
        Juleana.history_key!(page, KeyEvent(:home))
        @test page.col == 1
        render_history_page(page)
        Juleana.history_key!(page, KeyEvent(:pagedown))
        @test page.row == 3
        Juleana.history_key!(page, KeyEvent(:pageup))
        @test page.row == 1
    end

    @testset "opening reports" begin
        page = loaded_page()
        # a history cell does nothing
        Juleana.history_key!(page, KeyEvent(:enter))
        @test isempty(Juleana.take_requests!(page)) && isnothing(page.viewer_path)
        # a never processed cell does nothing
        page.row = 2
        Juleana.history_key!(page, KeyEvent(:enter))
        @test isempty(Juleana.take_requests!(page))
        page.row, page.col = 1, 2
        Juleana.history_key!(page, KeyEvent(:enter))
        @test Juleana.take_requests!(page) == [(; kind = :open, path = "/rep/p02-r007.md")]
        @test page.viewer_path == "/rep/p02-r007.md"
        @test find_text(render_history_page(page), "Reading report…") !== nothing
        # an answer for another report is dropped
        Juleana.history_result!(page, (; request = (; kind = :open, path = "/rep/other.md"), value = "# Other"))
        @test isnothing(page.viewer)
        Juleana.history_result!(page, (; request = (; kind = :open, path = page.viewer_path), value = "# Report\n\nbody"))
        @test page.viewer isa Tachikoma.MarkdownPane
        @test find_text(render_history_page(page), "p02-r007.md") !== nothing
        # the viewer takes the keys; Escape closes it
        @test Juleana.history_key!(page, KeyEvent(:down)) && page.row == 1
        @test Juleana.history_key!(page, KeyEvent('x'))
        @test Juleana.history_key!(page, KeyEvent(:escape)) && isnothing(page.viewer_path)
        Juleana.history_key!(page, KeyEvent(:enter))
        Juleana.take_requests!(page)
        Juleana.history_result!(page, (; request = (; kind = :open, path = page.viewer_path), value = nothing))
        @test find_text(render_history_page(page), "No report file: /rep/p02-r007.md") !== nothing
        Juleana.history_key!(page, KeyEvent('q'))
        @test isnothing(page.viewer_path)
    end

    @testset "rendering" begin
        page = loaded_page()
        text = history_text(render_history_page(page))
        @test occursin("dsp cal", text) && occursin("hit cal", text) && occursin("p energy cal", text)
        @test occursin("p02", text) && occursin("p03", text)
        @test occursin("✓", text) && occursin("!", text) && occursin("✗", text) && occursin("–", text)
        @test occursin("■", text) && occursin("[", text) && occursin("[■]", text) && occursin("history:", text)
        @test occursin("dsp cal  p02-r006  failed", text)
        @test find_text(render_history_page(page, 100, 20), "History") !== nothing
        # a history cell looks different from a report cell of the same state
        tb = render_history_page(page)
        # the icon of run 6 in the first row is the middle character of its cell
        @test collect(row_text(tb, page.cells.y))[page.cells.x + 1] == '■'
        @test Tachikoma.style_at(tb, page.cells.x + 1, page.cells.y).fg == Tachikoma.tstyle(Juleana.HISTORY_COLORS.failed).fg
        @test Tachikoma.style_at(tb, page.cells.x + 5, page.cells.y).fg == Tachikoma.tstyle(Juleana.REPORT_COLORS.warning).fg
    end

    @testset "scrolling" begin
        page = loaded_page()
        # room for the names and six run columns
        width = 40
        render_history_page(page, width, 12)
        @test page.left == 1
        Juleana.history_key!(page, KeyEvent(:end_key))
        tb = render_history_page(page, width, 12)
        @test page.left > 1
        text = history_text(tb)
        # the cursor column is shown with its run number, the names stay
        @test occursin("dsp cal", text) && occursin("p03", text)
        offsets = page.offsets
        @test offsets[page.col] - offsets[page.left] + Juleana.HISTORY_CELL_WIDTH <= page.cells.width
        Juleana.history_key!(page, KeyEvent(:home))
        render_history_page(page, width, 12)
        @test page.left == 1
        # rows scroll too
        render_history_page(page, width, 8)
        page.row = 3
        render_history_page(page, width, 8)
        @test page.top <= 3 <= page.top + page.height - 1
        # a tiny area draws nothing and does not throw
        render_history_page(page, 2, 2)
        render_history_page(page, 30, 4)
    end

    @testset "mouse" begin
        page = loaded_page()
        render_history_page(page)
        press(x, y, button = Tachikoma.mouse_left) = Tachikoma.MouseEvent(x, y, button, Tachikoma.mouse_press, false, false, false)
        cells = page.cells
        # third run column of the second row
        @test Juleana.history_mouse!(page, press(cells.x + 2 * 4 + 1, cells.y + 1))
        @test (page.row, page.col) == (2, 3)
        # the gap between two cells is no cell
        @test !Juleana.history_mouse!(page, press(cells.x + 3, cells.y))
        @test (page.row, page.col) == (2, 3)
        @test Juleana.history_mouse!(page, press(cells.x, cells.y, Tachikoma.mouse_scroll_down))
        @test page.row == 3
        @test Juleana.history_mouse!(page, press(cells.x, cells.y, Tachikoma.mouse_scroll_up))
        @test page.row == 2
        # the viewer gets the events while a report is open
        page.row, page.col = 1, 2
        Juleana.history_key!(page, KeyEvent(:enter))
        @test !Juleana.history_mouse!(page, press(1, 1))
    end
end
