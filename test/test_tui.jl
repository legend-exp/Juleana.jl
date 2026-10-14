# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Juleana
using Tachikoma: Tachikoma, KeyEvent, TestBackend, Frame, Rect, GraphicsRegion,
    PixelSnapshot, find_text, row_text
using Test

# Render `m` into a `width` x `height` test backend.
function render_tui(m, width = 100, height = 30)
    tb = TestBackend(width, height)
    frame = Frame(tb.buf, Rect(1, 1, width, height), GraphicsRegion[], PixelSnapshot[])
    Tachikoma.view(m, frame)
    return tb
end

@testset "TUI" begin
    m = Juleana.JuleanaTUI(Dict{String,Any}())
    @test m.page == 1
    @test !Tachikoma.should_quit(m)

    @testset "render" begin
        tb = render_tui(m)
        for name in Juleana.TUI_PAGES
            @test find_text(tb, name) !== nothing
        end
        @test find_text(tb, "This page is not available yet.") !== nothing
        @test find_text(tb, "1-4/Tab: switch page   q: quit") !== nothing
        # Body title on the first row of the bordered block, below the tab bar.
        body_title = find_text(tb, "Setup")
        @test body_title !== nothing
        @test count(r -> occursin("Setup", row_text(tb, r)), 1:30) == 2
    end

    @testset "page switching" begin
        Tachikoma.update!(m, KeyEvent(:tab))
        @test m.page == 2
        Tachikoma.update!(m, KeyEvent(:tab))
        Tachikoma.update!(m, KeyEvent(:tab))
        @test m.page == 4
        Tachikoma.update!(m, KeyEvent(:tab))
        @test m.page == 1
        Tachikoma.update!(m, KeyEvent(:backtab))
        @test m.page == 4
        Tachikoma.update!(m, KeyEvent(:backtab))
        @test m.page == 3
        Tachikoma.update!(m, KeyEvent('1'))
        @test m.page == 1
        Tachikoma.update!(m, KeyEvent('3'))
        @test m.page == 3
        Tachikoma.update!(m, KeyEvent('5'))
        @test m.page == 3
        @test !m.quit
    end

    @testset "render after switching" begin
        Tachikoma.update!(m, KeyEvent('3'))
        tb = render_tui(m)
        @test count(r -> occursin("Reports", row_text(tb, r)), 1:30) == 2
        @test count(r -> occursin("Setup", row_text(tb, r)), 1:30) == 1
        @test find_text(tb, "This page is not available yet.") !== nothing
    end

    @testset "quit" begin
        Tachikoma.update!(m, KeyEvent('q'))
        @test m.quit
        @test Tachikoma.should_quit(m)
        m2 = Juleana.JuleanaTUI(Dict{String,Any}())
        Tachikoma.update!(m2, KeyEvent(:ctrl, 'c'))
        @test Tachikoma.should_quit(m2)
        m3 = Juleana.JuleanaTUI(Dict{String,Any}())
        Tachikoma.update!(m3, KeyEvent(:ctrl_c))
        @test Tachikoma.should_quit(m3)
    end
end # testset
