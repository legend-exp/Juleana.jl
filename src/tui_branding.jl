# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

const DOCS_URL = "https://legend-exp.github.io/Juleana.jl/stable/"

# Keys listed by the help overlay as `(keys, description)`: Setup page, Progress page, Log page, all pages.
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
        ("w", "write the settings to the config file"),
        ("Mouse", "click to check, fold or focus; wheel scrolls"),
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
    common = (
        ("1-6", "open a page"),
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
`:medium` or `:small`) or the rows of an art as in [`Juleana.render_logo`](@ref).
"""
logo_size(rows::AbstractVector{<:AbstractString}) = (maximum(textwidth, rows; init = 0), cld(length(rows), 2))
logo_size(name::Symbol) = logo_size(LOGO_ART[name])

"""
    Juleana.render_logo(art, x, y, buf::Tachikoma.Buffer; max_x, max_y)

Draw the logo `art` with its top left cell at column `x` and row `y` of `buf`, clipped at
column `max_x` and row `max_y` (default: the edges of `buf`). `art` is a size name
(`:large`, `:medium` or `:small`) or a vector of rows of palette characters, one per pixel:
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
    return isnothing(load_outcome(m.snap)) || time() - m.started_at < m.splash_seconds
end

# Draw the startup screen into `area`: the logo, version, docs link and load state, centered.
# The logo is the largest size that fits above the text.
function render_splash(m::JuleanaTUI, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    dim = Tachikoma.tstyle(:text_dim)
    outcome = load_outcome(m.snap)
    spinner = string(Tachikoma.SPINNER_BRAILLE[mod1(m.ticks, length(Tachikoma.SPINNER_BRAILLE))])
    state = isnothing(outcome) ? [(spinner * " ", Tachikoma.tstyle(:warning)), ("Loading the session…", Tachikoma.tstyle(:text))] :
        outcome === :loaded ? [("Session loaded", Tachikoma.tstyle(:success))] :
        [("Loading the session failed", Tachikoma.tstyle(:error, bold = true))]
    lines = [[(juleana_version(), dim)], [(DOCS_URL, Tachikoma.tstyle(:accent; underline = true, hyperlink = DOCS_URL))], [("", dim)], state]
    fits(name) = (size = logo_size(name); size[1] <= area.width && size[2] + 1 + length(lines) <= area.height)
    name = fits(:large) ? :large : fits(:medium) ? :medium : nothing
    logo_h = isnothing(name) ? 0 : logo_size(name)[2] + 1
    y = area.y + max(0, (area.height - logo_h - length(lines)) ÷ 2)
    if !isnothing(name)
        w, h = logo_size(name)
        render_logo(name, area.x + (area.width - w) ÷ 2, y, buf; max_x = Tachikoma.right(area), max_y = Tachikoma.bottom(area))
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

# Draw the small logo and the version at the right end of the tab row `area`, if they fit
# right of the tabs.
function render_corner_logo(m::JuleanaTUI, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    used = isempty(m.tabs._tab_rects) ? area.x - 1 : maximum(Tachikoma.right, m.tabs._tab_rects)
    w, h = logo_size(:small)
    version = juleana_version()
    x = Tachikoma.right(area) - (w + 1 + textwidth(version))
    (x > used + 1 && h <= area.height) || return nothing
    render_logo(:small, x, area.y, buf; max_x = Tachikoma.right(area), max_y = Tachikoma.bottom(area))
    Tachikoma.set_string!(buf, x + w + 1, area.y + (h - 1) ÷ 2, version, Tachikoma.tstyle(:text_dim); max_x = Tachikoma.right(area))
    return nothing
end

# Draw the key help of the visible page of `m` as a panel centered in `area`.
function render_help(m::JuleanaTUI, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    sections = Tuple{String,Any}[]
    m.page == 1 && push!(sections, ("Setup page", HELP_KEYS.setup))
    m.page == 4 && push!(sections, ("Progress page", HELP_KEYS.progress))
    m.page == 5 && push!(sections, ("Log page", HELP_KEYS.log))
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
