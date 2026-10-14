# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

const TUI_PAGES = ("Setup", "Workers", "Reports", "Progress")

"""
    mutable struct JuleanaTUI <: Tachikoma.Model

State of the terminal user interface opened by [`Juleana.run_tui`](@ref).

Fields:
- `args::Dict{String,Any}`: parsed command line options.
- `page::Int`: index of the visible page in `Juleana.TUI_PAGES`.
- `quit::Bool`: whether the interface exits after the current event.
"""
mutable struct JuleanaTUI <: Tachikoma.Model
    const args::Dict{String,Any}
    page::Int
    quit::Bool
end

JuleanaTUI(args::AbstractDict) = JuleanaTUI(Dict{String,Any}(args), 1, false)

Tachikoma.should_quit(m::JuleanaTUI) = m.quit

function Tachikoma.update!(m::JuleanaTUI, evt::Tachikoma.KeyEvent)
    n = length(TUI_PAGES)
    if evt.key == :tab
        m.page = mod1(m.page + 1, n)
    elseif evt.key == :backtab
        m.page = mod1(m.page - 1, n)
    elseif evt.key == :ctrl_c || (evt.key == :ctrl && evt.char == 'c')
        m.quit = true
    elseif evt.key == :char && evt.char == 'q'
        m.quit = true
    elseif evt.key == :char && '1' <= evt.char <= '0' + n
        m.page = evt.char - '0'
    end
    return nothing
end

function Tachikoma.view(m::JuleanaTUI, f::Tachikoma.Frame)
    tabs = Tachikoma.TabBar(collect(TUI_PAGES); active = m.page, focused = true)
    tab_h = Tachikoma.tab_height(tabs.tab_style.decoration)
    layout = Tachikoma.Layout(
        Tachikoma.Vertical, [Tachikoma.Fixed(tab_h), Tachikoma.Fill(), Tachikoma.Fixed(1)]
    )
    tab_area, body_area, footer_area = Tachikoma.split_layout(layout, f.area)

    Tachikoma.render(tabs, tab_area, f.buffer)
    body = Tachikoma.Paragraph(
        "This page is not available yet.";
        block = Tachikoma.Block(
            title = TUI_PAGES[m.page],
            border_style = Tachikoma.tstyle(:border),
            title_style = Tachikoma.tstyle(:title),
        ),
    )
    Tachikoma.render(body, body_area, f.buffer)
    Tachikoma.set_string!(
        f.buffer, footer_area.x, footer_area.y,
        "1-4/Tab: switch page   q: quit", Tachikoma.tstyle(:text_dim),
    )
    return nothing
end

"""
    Juleana.run_tui(parsed_args::AbstractDict)

Open the terminal user interface with the pages Setup, Workers, Reports and Progress.
`parsed_args` are the parsed command line options, as returned by
[`Juleana.parse_commandline`](@ref). Tab and Shift-Tab or the keys `1` to `4` switch
pages, and `q` or Ctrl-C quits. Returns `nothing` when the user quits.
"""
function run_tui(parsed_args::AbstractDict)
    Tachikoma.app(JuleanaTUI(parsed_args))
    return nothing
end
