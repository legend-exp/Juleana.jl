"""
    Estimate(bytes, files, links, complete)

How much a selection would move. `files` counts individually chosen files; a
chosen directory contributes its bytes but no file count, because the tool has
not enumerated what is inside it. `complete` is `false` when a chosen node's size
has not been fetched yet, which is what the `?` in the status bar means. An
`Estimate` from [`parse_rsync_stats`](@ref) is always complete and counts every
file rsync would actually send.
"""
struct Estimate
    bytes::Int
    files::Int
    links::Int
    complete::Bool
end

"""
    format_bytes(n::Integer)::String

`n` as a short binary-prefixed size, e.g. `27.0 G`.
"""
function format_bytes(n::Integer)
    n < 1024 && return "$n B"
    value = Float64(n)
    for unit in ("K", "M", "G", "T")
        value /= 1024
        value < 1024 && return string(round(value; digits = 1), " ", unit)
    end
    string(round(value / 1024; digits = 1), " P")
end

"""
    running_estimate(root::Node)::Estimate

The total for the current selection, from sizes already cached in the tree.
"""
function running_estimate(root::Node)
    bytes = 0
    files = 0
    links = 0
    complete = true
    pending = Node[root]
    while !isempty(pending)
        node = pop!(pending)
        mode = effective_mode(node)
        parent_mode = node.parent === nothing ? :none : effective_mode(node.parent)
        if mode == :copy && parent_mode != :copy
            # A node's size already covers its subtree, so nothing below it is added.
            node.size === nothing ? (complete = false) : (bytes += node.size)
            node.kind in (:file, :group) && (files += 1)
            continue
        end
        mode == :link && parent_mode != :link && (links += 1)
        node.children === nothing && continue
        append!(pending, node.children)
    end
    Estimate(bytes, files, links, complete)
end

"""
    format_estimate(e::Estimate)::String

The one-line form the status bar shows.
"""
format_estimate(e::Estimate) = string(
    "selected: ", format_bytes(e.bytes), e.complete ? "" : "?",
    " copy (", e.files, " files), ", e.links, " links")

"""
    parse_rsync_stats(out::AbstractString, links::Integer)::Estimate

The totals from `rsync --dry-run --stats`. Digit grouping is stripped; callers
must run rsync with a fixed locale (`LC_ALL=C`) so the grouping character is a
comma.
"""
function parse_rsync_stats(out::AbstractString, links::Integer)
    bytes = match(r"^Total transferred file size:\s+([0-9,]+)"m, out)
    files = match(r"^Number of regular files transferred:\s+([0-9,]+)"m, out)
    (bytes === nothing || files === nothing) && throw(ErrorException(
        "rsync --stats printed no transfer totals; GNU rsync >= 3.1 is required. Output was:\n$out"))
    Estimate(parse(Int, replace(bytes[1], "," => "")),
             parse(Int, replace(files[1], "," => "")), Int(links), true)
end
