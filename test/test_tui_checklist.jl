# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Juleana
using Tachikoma: Tachikoma, KeyEvent, MouseEvent, TestBackend, Rect, find_text, row_text,
                 style_at
using Test

function render_checklist(w, width = 40, height = 12)
    tb = TestBackend(width, height)
    Tachikoma.render(w, Rect(1, 1, width, height), tb.buf)
    return tb
end

screen(tb) = join((row_text(tb, r) for r in 1:tb.height), "\n")

press!(w, keys...) = [Tachikoma.handle_key!(w, KeyEvent(k)) for k in keys]
type!(w, text) = press!(w, collect(text)...)

function flat_items()
    [
        Juleana.ChecklistItem(:a, "alpha"; tags = ["cal"]),
        Juleana.ChecklistItem(:b, "beta"; tags = ["rank 3", "deps: a"]),
        Juleana.ChecklistItem(:c, "gamma"),
        Juleana.ChecklistItem(:d, "delta")
    ]
end

function grouped_items()
    [
        Juleana.ChecklistGroup(:g1,
            "Energy",
            [
                Juleana.ChecklistItem(:e1, "calibrate"; tags = ["cal"]),
                Juleana.ChecklistItem(:e2, "resolution")
            ]),
        Juleana.ChecklistGroup(:g2,
            "PSD",
            [
                Juleana.ChecklistItem(:p1, "aoe"),
                Juleana.ChecklistItem(:p2, "lq"; tags = ["phy"])
            ];
            tags = ["psd tag"])
    ]
end

@testset "Checklist" begin
    @testset "construction" begin
        dup = [Juleana.ChecklistItem(:a, "x"), Juleana.ChecklistItem(:a, "y")]
        @test_throws "duplicate item key :a" Juleana.Checklist(dup)
        dup_groups = [
            Juleana.ChecklistGroup(:g1, "G1", [Juleana.ChecklistItem(:a, "x")]),
            Juleana.ChecklistGroup(:g2, "G2", [Juleana.ChecklistItem(:a, "y")])
        ]
        @test_throws "duplicate item key :a" Juleana.Checklist(dup_groups)
        @test_throws "unknown item keys :zz" Juleana.Checklist(flat_items(); checked = [
            :a, :zz])
        @test_throws "all ChecklistItem or all ChecklistGroup" Juleana.Checklist(Any[flat_items()[1], grouped_items()[1]])
        w = Juleana.Checklist(flat_items(); checked = [:c, :a])
        @test Juleana.checked(w) == [:a, :c]
        item = Juleana.ChecklistItem(:k, "label"; tags = ("t1", "t2"))
        @test item.tags == ["t1", "t2"]
        @test isempty(Juleana.ChecklistItem(:k, "label").tags)
    end

    @testset "colors" begin
        marked = Tachikoma.Style(; fg = Tachikoma.ColorRGB(1, 2, 3), bold = true)
        w = Juleana.Checklist(flat_items(); checked = [:a], tag_style = tag -> tag ==
                                                                               "cal" ?
                                                                               marked :
                                                                               nothing)
        tb = render_checklist(w)
        # tags are right-aligned in the last three cells inside the border
        @test style_at(tb, 38, 2) == marked
        # a tag without a style is dim
        dim = Tachikoma.tstyle(:text_dim)
        @test style_at(tb, 38, 3) == dim
        @test style_at(tb, 3, 2).fg == Tachikoma.tstyle(:success).fg
        @test style_at(tb, 3, 3).fg == dim.fg
        g = Juleana.Checklist(grouped_items(); title = "G", focused = false)
        tb = render_checklist(g)
        @test style_at(tb, 9, 2) == Tachikoma.tstyle(:primary, bold = true)
    end

    @testset "rendering" begin
        w = Juleana.Checklist(flat_items(); title = "Processors", checked = [:a, :b])
        tb = render_checklist(w)
        @test find_text(tb, "Processors  2/4 selected") !== nothing
        @test find_text(tb, "[x] alpha") !== nothing
        @test find_text(tb, "[x] beta") !== nothing
        @test find_text(tb, "[ ] gamma") !== nothing
        @test find_text(tb, "cal") !== nothing
        @test find_text(tb, "rank 3  deps: a") !== nothing
        # tags are right-aligned; a focused checklist has a heavy border and a marked title
        @test occursin(r"cal┃$", row_text(tb, 2))
        @test find_text(tb, "▶ Processors") !== nothing
        w.focused = false
        tb = render_checklist(w)
        @test occursin(r"cal│$", row_text(tb, 2)) && find_text(tb, "▶") === nothing
        @test Juleana.current(w).key == :a

        # no title
        tb = render_checklist(Juleana.Checklist(flat_items()))
        @test find_text(tb, "0/4 selected") !== nothing

        # tags are dropped before a short label would be truncated
        tb = render_checklist(w, 16, 8)
        @test find_text(tb, "[x] alpha") !== nothing
        @test find_text(tb, "rank 3") === nothing
        for r in 1:8
            @test textwidth(row_text(tb, r)) == 16
        end

        # a long label is shortened to fit
        long = Juleana.Checklist([Juleana.ChecklistItem(:a, "a very long label that cannot fit")])
        tb = render_checklist(long, 20, 4)
        @test find_text(tb, "…") !== nothing
        @test find_text(tb, "cannot fit") === nothing

        # too small to draw
        @test render_checklist(w, 2, 2) isa TestBackend
    end

    @testset "group checkboxes" begin
        w = Juleana.Checklist(grouped_items(); title = "T")
        tb = render_checklist(w)
        @test find_text(tb, "▾ [ ] Energy") !== nothing
        @test find_text(tb, "  [ ] calibrate") !== nothing
        @test find_text(tb, "psd tag") !== nothing
        Juleana.set_checked!(w, [:e1])
        @test find_text(render_checklist(w), "▾ [~] Energy") !== nothing
        Juleana.set_checked!(w, [:e1, :e2])
        @test find_text(render_checklist(w), "▾ [x] Energy") !== nothing
        @test find_text(render_checklist(w), "T  2/4 selected") !== nothing
        press!(w, :left)
        @test find_text(render_checklist(w), "▸ [x] Energy") !== nothing
        @test find_text(render_checklist(w), "calibrate") === nothing
    end

    @testset "navigation keys" begin
        w = Juleana.Checklist(flat_items())
        render_checklist(w, 40, 8)
        @test press!(w, :down) == [true]
        @test Juleana.current(w).key == :b
        @test press!(w, :down, :down, :down) == [true, true, true]
        @test Juleana.current(w).key == :d
        @test press!(w, :up) == [true]
        @test Juleana.current(w).key == :c
        press!(w, :home)
        @test Juleana.current(w).key == :a
        press!(w, :up)
        @test Juleana.current(w).key == :a
        press!(w, :end_key)
        @test Juleana.current(w).key == :d

        # pages are as long as the displayed list
        many = Juleana.Checklist([Juleana.ChecklistItem(i, "item $i") for i in 1:30])
        render_checklist(many, 30, 7)  # 5 rows
        press!(many, :pagedown)
        @test Juleana.current(many).key == 6
        press!(many, :pagedown, :pagedown)
        @test Juleana.current(many).key == 16
        press!(many, :pageup)
        @test Juleana.current(many).key == 11
        press!(many, :pageup, :pageup, :pageup)
        @test Juleana.current(many).key == 1
        press!(many, :end_key, :pagedown)
        @test Juleana.current(many).key == 30
    end

    @testset "unused keys" begin
        w = Juleana.Checklist(flat_items())
        @test press!(w, :tab, :enter, :left, :right, :escape, :delete) == fill(false, 6)
        @test Tachikoma.handle_key!(w, KeyEvent('q')) == false
        @test Tachikoma.handle_key!(w, KeyEvent('1')) == false
        @test Tachikoma.handle_key!(w, KeyEvent(:char, ' ', Tachikoma.key_release)) == false
        @test isempty(Juleana.checked(w))
        g = Juleana.Checklist(grouped_items())
        press!(g, :down)  # item row
        @test press!(g, :enter, :right) == [false, false]
    end

    @testset "toggling" begin
        w = Juleana.Checklist(flat_items())
        @test press!(w, ' ') == [true]
        @test Juleana.checked(w) == [:a]
        press!(w, :down, ' ', ' ')
        @test Juleana.checked(w) == [:a]
        @test press!(w, 'a') == [true]
        @test Juleana.checked(w) == [:a, :b, :c, :d]
        @test press!(w, 'n') == [true]
        @test isempty(Juleana.checked(w))

        g = Juleana.Checklist(grouped_items())
        press!(g, ' ')  # group row selects its items
        @test Juleana.checked(g) == [:e1, :e2]
        press!(g, ' ')
        @test isempty(Juleana.checked(g))
        press!(g, :down, ' ')
        press!(g, :up, ' ')  # some selected: select all
        @test Juleana.checked(g) == [:e1, :e2]
        # collapsing does not change what the group toggles
        press!(g, :left, ' ')
        @test isempty(Juleana.checked(g))
        press!(g, ' ')
        @test Juleana.checked(g) == [:e1, :e2]

        empty = Juleana.Checklist(flat_items())
        type!(empty, "/zzz")
        press!(empty, :enter)
        @test press!(empty, ' ') == [true]
        @test isempty(Juleana.checked(empty))
    end

    @testset "collapse and expand" begin
        w = Juleana.Checklist(grouped_items())
        render_checklist(w)
        press!(w, :down, :down)  # e2
        @test Juleana.current(w).key == :e2
        @test press!(w, :left) == [true]
        @test Juleana.current(w) isa Juleana.ChecklistGroup
        @test Juleana.current(w).key == :g1
        @test !Juleana.current(w).expanded
        @test find_text(render_checklist(w), "resolution") === nothing
        press!(w, :down)
        @test Juleana.current(w).key == :g2
        @test press!(w, :up, :right) == [true, true]
        @test Juleana.current(w).expanded
        @test find_text(render_checklist(w), "resolution") !== nothing
        @test press!(w, :enter) == [true]
        @test !Juleana.current(w).expanded
        press!(w, :enter)
        @test Juleana.current(w).expanded
        press!(w, :left, :left)  # already collapsed
        @test !Juleana.current(w).expanded
    end

    @testset "filter" begin
        w = Juleana.Checklist(grouped_items(); title = "T")
        render_checklist(w)
        @test press!(w, '/') == [true]
        # every key is used while editing, including normal mode keys
        @test type!(w, "Cal") == [true, true, true]
        @test w.filter == "Cal"
        tb = render_checklist(w)
        @test find_text(tb, "/Cal▏") !== nothing
        @test find_text(tb, "calibrate") !== nothing
        @test find_text(tb, "resolution") === nothing  # sibling of the match
        @test find_text(tb, "aoe") === nothing
        @test press!(w, :backspace, :tab, :down, :up, :left) == fill(true, 5)
        @test w.filter == "Ca"
        @test press!(w, :enter) == [true]
        tb = render_checklist(w)
        @test find_text(tb, "/Ca") !== nothing
        @test find_text(tb, "▏") === nothing
        # a non-empty filter is cleared by Escape in normal mode
        @test press!(w, :escape) == [true]
        @test isempty(w.filter)
        @test find_text(render_checklist(w), "aoe") !== nothing
        @test press!(w, :escape) == [false]
        # Escape while editing clears the filter and leaves editing
        press!(w, '/')
        type!(w, "lq")
        @test press!(w, :escape) == [true]
        @test isempty(w.filter) && !w.editing
        @test press!(w, 'q') == [false]

        # tags and group labels match; a matching group shows all its items
        w = Juleana.Checklist(grouped_items())
        press!(w, '/')
        type!(w, "PHY")
        tb = render_checklist(w)
        @test find_text(tb, "PSD") !== nothing
        @test find_text(tb, "lq") !== nothing
        @test find_text(tb, "aoe") === nothing
        @test find_text(tb, "Energy") === nothing
        press!(w, :escape)
        press!(w, '/')
        type!(w, "psd")
        tb = render_checklist(w)
        @test find_text(tb, "aoe") !== nothing
        @test find_text(tb, "lq") !== nothing
        @test find_text(tb, "Energy") === nothing

        # items of a flat list match on label and tag
        f = Juleana.Checklist(flat_items())
        press!(f, '/')
        type!(f, "rank")
        tb = render_checklist(f)
        @test find_text(tb, "beta") !== nothing
        @test find_text(tb, "alpha") === nothing
    end

    @testset "filter and selection" begin
        w = Juleana.Checklist(flat_items(); checked = [:d])
        press!(w, '/')
        type!(w, "l")  # alpha, delta
        press!(w, :enter)
        press!(w, 'a')
        @test Juleana.checked(w) == [:a, :d]
        press!(w, 'n')
        @test isempty(Juleana.checked(w))
        press!(w, ' ')
        @test Juleana.checked(w) == [:a]
        # selection outside the filter is kept
        Juleana.set_checked!(w, [:b, :c])
        press!(w, 'a')
        @test Juleana.checked(w) == [:a, :b, :c, :d]
        press!(w, 'n')
        @test Juleana.checked(w) == [:b, :c]
        @test find_text(render_checklist(w), "2/4 selected") !== nothing

        # collapsed groups still take part in a/n
        g = Juleana.Checklist(grouped_items())
        press!(g, :left, 'a')
        @test Juleana.checked(g) == [:e1, :e2, :p1, :p2]
        press!(g, '/')
        type!(g, "lq")
        press!(g, :enter, 'n')
        @test Juleana.checked(g) == [:e1, :e2, :p1]
    end

    @testset "cursor clamping" begin
        w = Juleana.Checklist(flat_items())
        render_checklist(w)
        press!(w, :end_key)
        @test Juleana.current(w).key == :d
        press!(w, '/')
        type!(w, "l")  # alpha, delta
        press!(w, :enter)
        @test Juleana.current(w).key == :d
        render_checklist(w)
        @test Juleana.current(w).key == :d
        press!(w, :down)
        @test Juleana.current(w).key == :d
        press!(w, :home)
        @test Juleana.current(w).key == :a
        press!(w, '/')
        type!(w, "zzz")
        press!(w, :enter)
        @test Juleana.current(w) === nothing
        @test all(==(true), press!(w, :down, :end_key, :home, :up))
        press!(w, '/', :backspace, :backspace, :backspace)
        @test Juleana.current(w).key == :a
        render_checklist(w)
        @test Juleana.current(w).key == :a
    end

    @testset "scrolling" begin
        w = Juleana.Checklist([Juleana.ChecklistItem(i, "item $i") for i in 1:20])
        tb = render_checklist(w, 30, 5)  # 3 rows
        @test find_text(tb, "item 3") !== nothing
        @test find_text(tb, "item 4") === nothing
        press!(w, :down, :down, :down)
        tb = render_checklist(w, 30, 5)
        @test Juleana.current(w).key == 4
        @test find_text(tb, "item 4") !== nothing
        @test find_text(tb, "item 1 ") === nothing
        press!(w, :end_key)
        tb = render_checklist(w, 30, 5)
        @test find_text(tb, "item 20") !== nothing
        @test find_text(tb, "item 18") !== nothing
        @test find_text(tb, "item 17") === nothing
        press!(w, :home)
        tb = render_checklist(w, 30, 5)
        @test find_text(tb, "item 1 ") !== nothing
        # the filter line takes a row of the list
        press!(w, '/')
        type!(w, "item")
        tb = render_checklist(w, 30, 5)
        @test find_text(tb, "/item▏") !== nothing
        @test find_text(tb, "item 2 ") !== nothing
        @test find_text(tb, "item 3") === nothing
        press!(w, :enter, :down, :down)
        tb = render_checklist(w, 30, 5)
        @test find_text(tb, "item 3") !== nothing
        @test find_text(tb, "/item") !== nothing
    end

    @testset "set_checked! and current" begin
        w = Juleana.Checklist(grouped_items(); checked = [:e1])
        @test Juleana.set_checked!(w, [:p2, :e2]) === w
        @test Juleana.checked(w) == [:e2, :p2]
        @test_throws "unknown item keys :nope, :g1" Juleana.set_checked!(w, [
            :e1, :nope, :g1])
        @test Juleana.checked(w) == [:e2, :p2]  # unchanged
        Juleana.set_checked!(w, Symbol[])
        @test isempty(Juleana.checked(w))
        @test Juleana.set_checked!(w) do item
            item.label == "aoe" || :cal in Symbol.(item.tags)
        end === w
        @test Juleana.checked(w) == [:e1, :p1]

        @test Juleana.current(w) isa Juleana.ChecklistGroup
        press!(w, :down)
        @test Juleana.current(w) isa Juleana.ChecklistItem
        @test Juleana.current(w).label == "calibrate"
        press!(w, '/')
        type!(w, "nothing matches")
        @test Juleana.current(w) === nothing
    end

    @testset "mouse" begin
        click(x, y) = MouseEvent(
            x, y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false)
        wheel(x, y, button) = MouseEvent(
            x, y, button, Tachikoma.mouse_press, false, false, false)
        w = Juleana.Checklist(grouped_items(); title = "T")
        render_checklist(w)  # rows start at y = 2
        @test Tachikoma.handle_mouse!(w, click(5, 3)) == true
        @test Juleana.current(w).key == :e1
        @test Juleana.checked(w) == [:e1]
        @test Tachikoma.handle_mouse!(w, click(5, 3)) == true
        @test isempty(Juleana.checked(w))
        # a group row toggles its items
        @test Tachikoma.handle_mouse!(w, click(5, 2)) == true
        @test Juleana.checked(w) == [:e1, :e2]
        @test Tachikoma.handle_mouse!(w, click(5, 2)) == true
        @test isempty(Juleana.checked(w))
        # outside the rows, border, release and other buttons are not used
        @test Tachikoma.handle_mouse!(w, click(5, 10)) == false
        @test Tachikoma.handle_mouse!(w, click(5, 1)) == false
        @test Tachikoma.handle_mouse!(w, click(100, 3)) == false
        @test Tachikoma.handle_mouse!(w,
            MouseEvent(
                5, 3, Tachikoma.mouse_left, Tachikoma.mouse_release, false, false, false)) ==
              false
        @test Tachikoma.handle_mouse!(w,
            MouseEvent(
                5, 3, Tachikoma.mouse_right, Tachikoma.mouse_press, false, false, false)) ==
              false
        @test isempty(Juleana.checked(w))
        # wheel
        @test Juleana.current(w).key == :g1
        @test Tachikoma.handle_mouse!(w, wheel(5, 3, Tachikoma.mouse_scroll_down)) == true
        @test Juleana.current(w).key == :e1
        Tachikoma.handle_mouse!(w, wheel(5, 3, Tachikoma.mouse_scroll_down))
        @test Juleana.current(w).key == :e2
        @test Tachikoma.handle_mouse!(w, wheel(5, 3, Tachikoma.mouse_scroll_up)) == true
        @test Juleana.current(w).key == :e1
        @test Tachikoma.handle_mouse!(w, wheel(100, 3, Tachikoma.mouse_scroll_up)) == false
        @test Juleana.current(w).key == :e1
        Tachikoma.handle_mouse!(w, wheel(5, 3, Tachikoma.mouse_scroll_up))
        Tachikoma.handle_mouse!(w, wheel(5, 3, Tachikoma.mouse_scroll_up))
        @test Juleana.current(w).key == :g1

        # clicks account for the scroll offset
        many = Juleana.Checklist([Juleana.ChecklistItem(i, "item $i") for i in 1:20])
        render_checklist(many, 30, 5)
        press!(many, :end_key)
        render_checklist(many, 30, 5)  # shows items 18 to 20
        @test Tachikoma.handle_mouse!(many, click(5, 2)) == true
        @test Juleana.checked(many) == [18]
    end
end
