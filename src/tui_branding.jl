# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

const DOCS_URL = "https://legend-exp.github.io/Juleana.jl/stable/"

# Keys listed by the help overlay as `(keys, description)`: Setup page, Graph page, Progress page, Log page, Reports page, History page, all pages.
const HELP_KEYS = (
    setup = (
        ("Tab  Shift-Tab", "next, previous pane"),
        ("↑ ↓ PgUp PgDn Home End", "move in a pane"),
        ("← → Enter", "fold, unfold a period"),
        ("Space", "check or uncheck the item"),
        ("a  n", "check all, none"),
        ("/", "filter the list (Enter keeps, Esc clears)"),
        ("c  p", "check the cal, phy processors"),
        ("d", "add the steps that checked steps wait for"),
        ("e", "edit the keyword arguments of the processor"),
        ("Space  Enter", "cycle the option in the Options pane"),
        ("s", "start processing"),
        ("x  X", "stop after the running items, stop at once"),
        ("r", "reload the config"),
        ("g", "rebuild the dependency graph"),
        ("W", "start workers"),
        ("N", "create a new data production"),
        ("w", "write the settings to the config file"),
        ("Mouse", "click to check, fold or focus; wheel scrolls"),
    ),
    graph = (
        ("↑ ↓ PgUp PgDn Home End", "move the cursor"),
        ("Space", "select or deselect the processor"),
        ("d", "add the steps that selected steps wait for"),
        ("h", "show or hide unselected processors"),
        ("v", "state icons of the last run or on disk"),
        ("Mouse", "click a row, wheel moves the cursor"),
    ),
    workers = (
        ("Tab", "switch between the allocations and the workers"),
        ("↑ ↓", "select an allocation or worker; scroll SLURM"),
        ("PgUp PgDn End", "scroll the output; End: newest line"),
        ("s", "show the workers or SLURM (with SLURM only)"),
        ("a", "start workers (a new allocation)"),
        ("c", "cancel the selected running allocation (asks)"),
        ("C", "cancel all allocations (asks; y confirms)"),
        ("p", "postpone the cancel of idle allocations"),
        ("r", "read the overview again"),
        ("e", "edit the start script (Ctrl-S saves, Esc closes)"),
        ("Mouse", "click a row, wheel scrolls the output"),
    ),
    progress = (
        ("↑ ↓ PgUp PgDn Home End", "move the cursor"),
        ("Enter  ← →", "fold, unfold a group"),
        ("Enter on a step", "messages of the step (again: close)"),
        ("PgUp PgDn", "scroll the messages while they are open"),
        ("End", "newest message while they are open"),
        ("Esc", "close the messages"),
        ("f", "follow the running step"),
        ("Mouse", "click a row, wheel moves the cursor"),
    ),
    log = (
        ("↑ ↓ PgUp PgDn Home", "scroll; turns following off"),
        ("End", "jump to the newest line and follow"),
        ("f", "follow the newest line"),
        ("l", "cycle the level: all, warnings, errors"),
        ("/", "filter the lines (Enter keeps, Esc clears)"),
        ("Mouse", "wheel scrolls"),
    ),
    reports = (
        ("↑ ↓ PgUp PgDn Home End", "move the cursor; scroll the failures"),
        ("Enter  ← →", "fold, unfold a group"),
        ("Enter on a report", "open the report"),
        ("Tab", "switch between the reports and the failures"),
        ("a", "all reports on disk or those of the current run"),
        ("r", "read the reports again"),
        ("↑ ↓ PgUp PgDn Home End", "scroll an open report"),
        ("Esc  q", "close the open report"),
        ("Mouse", "click a row, wheel moves the cursor or scrolls"),
    ),
    history = (
        ("↑ ↓ ← →", "move the cursor; on a partition row ← → move by period"),
        ("PgUp PgDn Home End", "move by a page of rows; first, last run"),
        ("Enter on a report", "open the report (history cells have none)"),
        ("r", "read the grid again"),
        ("↑ ↓ PgUp PgDn Home End", "scroll an open report"),
        ("Esc  q", "close the open report"),
        ("Mouse", "click a cell, wheel moves the cursor"),
    ),
    common = (
        ("1-7", "open a page"),
        ("q  Ctrl-C", "quit"),
        ("?", "show these keys"),
        ("Ctrl-G", "toggle mouse reporting (off allows selecting text)"),
    ),
)

# Version of this package as `v1.2.3`, read once.
const VERSION_TEXT = Ref("")
function juleana_version()
    isempty(VERSION_TEXT[]) && (VERSION_TEXT[] = "v" * string(pkgversion(Juleana)))
    return VERSION_TEXT[]
end

# Color of a palette character of the logo art: the outline takes the text color of the theme.
function logo_color(char::Char)
    char == 'k' && return Tachikoma.theme().text
    char == 'r' && return TITLE_COLORS[1]
    char == 'g' && return TITLE_COLORS[2]
    char == 'p' && return TITLE_COLORS[3]
    throw(ArgumentError("logo art: unknown palette character $(repr(char))"))
end

"""
    Juleana.logo_size(art)

Width and height in terminal cells of the logo `art`, which is a size name (`:large`,
`:medium`, `:mark`, `:mark_small` or `:corner`) or the rows of an art as in
[`Juleana.render_logo`](@ref).
"""
logo_size(rows::AbstractVector{<:AbstractString}) = (maximum(textwidth, rows; init = 0), cld(length(rows), 2))
logo_size(name::Symbol) = logo_size(LOGO_ART[name])

"""
    Juleana.render_logo(art, x, y, buf::Tachikoma.Buffer; max_x, max_y)

Draw the logo `art` with its top left cell at column `x` and row `y` of `buf`, clipped at
column `max_x` and row `max_y` (default: the edges of `buf`). `art` is a size name
(`:large`, `:medium`, `:mark`, `:mark_small` or `:corner`) or a vector of rows of palette
characters, one per pixel:
a space is transparent, `k` is the outline in the text color of the theme, and `r`, `g`
and `p` are the red, green and purple of the logo. Two pixel rows make one row of cells,
drawn with half-block characters; transparent pixels leave the cell as it is.
"""
function render_logo(rows::AbstractVector{<:AbstractString}, x::Integer, y::Integer, buf::Tachikoma.Buffer;
        max_x::Integer = Tachikoma.right(buf.area), max_y::Integer = Tachikoma.bottom(buf.area))
    pixel(j, i) = j <= length(rows) && i <= ncodeunits(rows[j]) ? rows[j][i] : ' '
    width, height = logo_size(rows)
    for cj in 1:height, ci in 1:width
        cx, cy = x + ci - 1, y + cj - 1
        (cx <= max_x && cy <= max_y) || continue
        top, bottom = pixel(2cj - 1, ci), pixel(2cj, ci)
        if top == ' ' && bottom == ' '
            continue
        elseif bottom == ' '
            Tachikoma.set_char!(buf, cx, cy, '▀', Tachikoma.Style(; fg = logo_color(top)))
        elseif top == ' '
            Tachikoma.set_char!(buf, cx, cy, '▄', Tachikoma.Style(; fg = logo_color(bottom)))
        elseif top == bottom
            Tachikoma.set_char!(buf, cx, cy, '█', Tachikoma.Style(; fg = logo_color(top)))
        else
            Tachikoma.set_char!(buf, cx, cy, '▀', Tachikoma.Style(; fg = logo_color(top), bg = logo_color(bottom)))
        end
    end
    return nothing
end

render_logo(name::Symbol, x::Integer, y::Integer, buf::Tachikoma.Buffer; kwargs...) =
    render_logo(LOGO_ART[name], x, y, buf; kwargs...)

# Logos in the order of preference for a free area: the full logos, then the circles alone
# with the name below them.
const LOGO_CHOICES = (:large, :medium, :mark, :mark_small)
const LOGO_CAPTION = "Juleana"

# Width and height in cells of the logo `name` of `LOGO_CHOICES` with its caption.
function logo_block_size(name::Symbol)
    w, h = logo_size(name)
    return (w, name in (:mark, :mark_small) ? h + 1 : h)
end

# The first of `LOGO_CHOICES` whose block fits `width` x `height` cells, or `nothing`.
function fitting_logo(width::Integer, height::Integer)
    for name in LOGO_CHOICES
        w, h = logo_block_size(name)
        w <= width && h <= height && return name
    end
    return nothing
end

# Draw the logo `name` of `LOGO_CHOICES` with its caption, with the top left cell of the
# block at `(x, y)`.
function render_logo_block(name::Symbol, x::Integer, y::Integer, buf::Tachikoma.Buffer; max_x::Integer, max_y::Integer)
    render_logo(name, x, y, buf; max_x, max_y)
    w, h = logo_size(name)
    if name in (:mark, :mark_small)
        Tachikoma.set_string!(buf, x + (w - textwidth(LOGO_CAPTION)) ÷ 2, y + h, LOGO_CAPTION, Tachikoma.tstyle(:text, bold = true); max_x)
    end
    return nothing
end

# `nothing` while the session loads, `:loaded` once it is loaded and `:failed` if loading failed.
function load_outcome(snap)
    isnothing(snap) && return nothing
    snap.state in (:idle, :loading) || return :loaded
    return isnothing(snap.last_error) ? nothing : :failed
end

# Whether the startup screen is shown: from `start!` until the session has loaded and
# `splash_seconds` have passed.
function splash_active(m::JuleanaTUI)
    m.splash || return false
    # with the new-production form open and no session to load, the screen ends after `splash_seconds`
    waiting = isnothing(load_outcome(m.snap)) && !(!isnothing(m.production) && !isnothing(m.snap) && m.snap.state === :idle)
    return waiting || time() - m.started_at < m.splash_seconds
end

# Draw the startup screen into `area`: the logo, version, docs link and load state, centered.
# The logo is the largest one that fits above the text.
function render_splash(m::JuleanaTUI, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    dim = Tachikoma.tstyle(:text_dim)
    outcome = load_outcome(m.snap)
    spinner = string(Tachikoma.SPINNER_BRAILLE[mod1(m.ticks, length(Tachikoma.SPINNER_BRAILLE))])
    state = isnothing(outcome) ? [(spinner * " ", Tachikoma.tstyle(:warning)), ("Loading the session…", Tachikoma.tstyle(:text))] :
        outcome === :loaded ? [("Session loaded", Tachikoma.tstyle(:success))] :
        [("Loading the session failed", Tachikoma.tstyle(:error, bold = true))]
    lines = [[(juleana_version(), dim)], [(DOCS_URL, Tachikoma.tstyle(:accent; underline = true, hyperlink = DOCS_URL))], [("", dim)], state]
    name = fitting_logo(area.width, area.height - 1 - length(lines))
    logo_h = isnothing(name) ? 0 : logo_block_size(name)[2] + 1
    y = area.y + max(0, (area.height - logo_h - length(lines)) ÷ 2)
    if !isnothing(name)
        w, h = logo_block_size(name)
        render_logo_block(name, area.x + (area.width - w) ÷ 2, y, buf; max_x = Tachikoma.right(area), max_y = Tachikoma.bottom(area))
        y += h + 1
    end
    for spans in lines
        y > Tachikoma.bottom(area) && break
        width = sum(s -> textwidth(s[1]), spans)
        put_spans!(buf, area.x + max(0, (area.width - width) ÷ 2), y, Tachikoma.right(area), spans)
        y += 1
    end
    return nothing
end

# Draw the corner logo and the version at the right end of the tab row `area`, if they fit
# right of the tabs. The bottom line of the tab bar ends one cell before the logo.
function render_corner_logo(m::JuleanaTUI, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    used = isempty(m.tabs._tab_rects) ? area.x - 1 : maximum(Tachikoma.right, m.tabs._tab_rects)
    w, h = logo_size(:corner)
    version = juleana_version()
    x = Tachikoma.right(area) - (w + 1 + textwidth(version))
    (x > used + 1 && h <= area.height) || return nothing
    for col in (x - 1):Tachikoma.right(area)
        Tachikoma.set_char!(buf, col, Tachikoma.bottom(area), ' ', Tachikoma.RESET)
    end
    render_logo(:corner, x, area.y, buf; max_x = Tachikoma.right(area), max_y = Tachikoma.bottom(area))
    Tachikoma.set_string!(buf, x + w + 1, area.y + (h - 1) ÷ 2, version, Tachikoma.tstyle(:text_dim); max_x = Tachikoma.right(area))
    return nothing
end

# Draw the key help of the visible page of `m` as a panel centered in `area`.
function render_help(m::JuleanaTUI, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    sections = Tuple{String,Any}[]
    m.page == 1 && push!(sections, ("Setup page", HELP_KEYS.setup))
    m.page == 2 && push!(sections, ("Graph page", HELP_KEYS.graph))
    m.page == 3 && push!(sections, ("Workers page", HELP_KEYS.workers))
    m.page == 4 && push!(sections, ("Progress page", HELP_KEYS.progress))
    m.page == 5 && push!(sections, ("Log page", HELP_KEYS.log))
    m.page == 6 && push!(sections, ("Reports page", HELP_KEYS.reports))
    m.page == 7 && push!(sections, ("History page", HELP_KEYS.history))
    push!(sections, ("All pages", HELP_KEYS.common))
    key_width = maximum(textwidth(k) for (_, entries) in sections for (k, _) in entries) + 2
    lines = Vector{Tuple{String,Tachikoma.Style}}[]
    for (title, entries) in sections
        push!(lines, [(title, Tachikoma.tstyle(:accent, bold = true))])
        for (keys, description) in entries
            push!(lines, [("  " * rpad(keys, key_width), Tachikoma.tstyle(:warning, bold = true)),
                (description, Tachikoma.tstyle(:text))])
        end
        push!(lines, [("", Tachikoma.tstyle(:text))])
    end
    push!(lines, [(juleana_version() * "  ", Tachikoma.tstyle(:text_dim)),
        (DOCS_URL, Tachikoma.tstyle(:accent; underline = true, hyperlink = DOCS_URL))])
    push!(lines, [("Esc, ? or q closes this panel", Tachikoma.tstyle(:text_dim))])
    width = maximum(sum(s -> textwidth(s[1]), spans) for spans in lines) + 4
    rect = Tachikoma.center(area, min(width + 2, area.width), min(length(lines) + 2, area.height))
    for row in rect.y:Tachikoma.bottom(rect), col in rect.x:Tachikoma.right(rect)
        Tachikoma.set_char!(buf, col, row, ' ', Tachikoma.RESET)
    end
    inner = Tachikoma.render(Tachikoma.Block(; title = "Keys", border_style = Tachikoma.tstyle(:accent),
        title_style = Tachikoma.tstyle(:title)), rect, buf)
    for (i, spans) in pairs(lines)
        y = inner.y + i - 1
        y > Tachikoma.bottom(inner) && break
        put_spans!(buf, inner.x + 1, y, Tachikoma.right(inner), spans)
    end
    return nothing
end
