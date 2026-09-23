"""
    Selection

What the user chose, in a form that survives a restart: remote paths relative to
the remote root, split into the ones to copy and the ones to link. Only the
nodes carrying an explicit mode are listed; the tree is reconstructed by
expanding those paths again.
"""
struct Selection
    host::String
    production::String
    remote_root::String
    local_root::String
    mount_root::Union{Nothing,String}
    copy::Vector{String}
    link::Vector{String}
    created::DateTime
end

"""
    effective_mode(node::Node)::Symbol

The mode that applies to `node`: its own if it has one, otherwise the nearest
ancestor's, otherwise `:none`.
"""
function effective_mode(node::Node)
    current = node
    while current !== nothing
        current.mode == :none || return current.mode
        current = current.parent
    end
    :none
end

"""
    set_mode!(node::Node, mode::Symbol)::Node

Choose `mode` for `node` and drop the explicit modes below it, so that the
subtree follows the new choice. The one survivor is a `:copy` under a `:link`:
that combination is how a few files are pulled out of an otherwise linked
directory.
"""
function set_mode!(node::Node, mode::Symbol)
    mode in (:none, :copy, :link) || throw(ArgumentError(
        "mode must be :none, :copy or :link, got :$mode"))
    node.mode = mode
    clear_descendants!(node, mode)
    node
end

function clear_descendants!(node::Node, mode::Symbol)
    node.children === nothing && return node
    for child in node.children
        (mode == :link && child.mode == :copy) || (child.mode = :none)
        clear_descendants!(child, mode)
    end
    node
end

"""
    exclude!(node::Node)::Node

Take `node` out of the selection it inherits. Every ancestor between the root and
`node` that carries a mode hands that mode to the siblings of the path down to
`node` and keeps none itself, so the rest of those subtrees stay selected while
`node` ends up with no mode at all. A node that carries its own mode simply loses
it, along with the explicit modes below it.
"""
function exclude!(node::Node)
    effective_mode(node) == :none && return node
    node.mode == :none || return set_mode!(node, :none)
    ancestors = Node[]
    current = node
    while current.parent !== nothing
        current = current.parent
        pushfirst!(ancestors, current)
    end
    for (i, level) in pairs(ancestors)
        level.mode == :none && continue
        mode = level.mode
        on_path = i < lastindex(ancestors) ? ancestors[i + 1] : node
        level.mode = :none
        for sibling in level.children
            sibling === on_path || set_mode!(sibling, mode)
        end
    end
    node
end

"""
    first_n_filekeys!(node::Node, n::Integer)::Int

Mark the first `n` filekeys of a listed run directory for copying, in timestamp
order, and return how many were marked.
"""
function first_n_filekeys!(node::Node, n::Integer)
    node.children === nothing && throw(ArgumentError(
        "$(node.label) has not been listed yet; expand it before selecting filekeys"))
    groups = filekey_groups(node)
    isempty(groups) && throw(ArgumentError("$(node.label) contains no filekey groups"))
    count = 0
    for group in groups
        count >= n && break
        set_mode!(group, :copy)
        count += 1
    end
    count
end

"""
    find_node!(h::RemoteHost, p::Production, root::Node, rel::AbstractString)::Node

The node at `rel` (a path relative to the remote root), listing every directory
from `root` down to it, inclusive. Descends into whichever child covers the
longest prefix of `rel`, because a `:section` node stands for a whole configured
directory rather than one path component.
"""
function find_node!(h::RemoteHost, p::Production, root::Node, rel::AbstractString)
    isempty(rel) && return root
    node = root
    while relative(p, node.remote_path) != rel
        node.children === nothing && expand!(h, p, node)
        best = nothing
        best_len = -1
        for child in node.children
            child_rel = relative(p, child.remote_path)
            (child_rel == rel || startswith(rel, child_rel * "/")) || continue
            if length(child_rel) > best_len
                best = child
                best_len = length(child_rel)
            end
        end
        best === nothing && throw(ArgumentError(
            "$rel is not in the production tree below $(node.label)"))
        node = best
    end
    node.children === nothing && node.kind in (:section, :dir) && expand!(h, p, node)
    node
end

function collect_modes!(node::Node, p::Production,
                        copies::Vector{String}, links::Vector{String})
    node.mode == :copy && push!(copies, relative(p, node.remote_path))
    node.mode == :link && push!(links, relative(p, node.remote_path))
    node.children === nothing && return nothing
    for child in node.children
        collect_modes!(child, p, copies, links)
    end
    nothing
end

function Selection(p::Production, host::AbstractString, root::Node)
    copies = String[]
    links = String[]
    collect_modes!(root, p, copies, links)
    # The production's own config.json and its metadata checkout are what make the
    # mirror openable at all, so they are copied whether or not they were picked.
    mandatory = [relative(p, joinpath(p.remote_root, p.name, "config.json"))]
    i = findfirst(kv -> first(kv) == "metadata", p.roots)
    i === nothing || push!(mandatory, relative(p, last(p.roots[i])))
    for path in mandatory
        path in copies || push!(copies, path)
    end
    Selection(host, p.name, p.remote_root, p.local_root, p.mount_root,
              sort!(copies), sort!(links), now())
end

"""
    selection_propdict(sel::Selection)::PropDict

The serialized form. A missing mount root is written as `""`: `readprops` trims
JSON nulls, so a null would come back as an absent key.
"""
selection_propdict(sel::Selection) = PropDict(
    :host => sel.host,
    :production => sel.production,
    :remote_root => sel.remote_root,
    :local_root => sel.local_root,
    :mount_root => sel.mount_root === nothing ? "" : sel.mount_root,
    :copy => sel.copy,
    :link => sel.link,
    :created => string(sel.created),
)

function Selection(props::PropDict)
    mount = String(props.mount_root)
    Selection(String(props.host), String(props.production),
              String(props.remote_root), String(props.local_root),
              isempty(mount) ? nothing : mount,
              String.(props.copy), String.(props.link),
              DateTime(String(props.created)))
end

"""
    save_selection(path::AbstractString, sel::Selection)::String

Write `sel` and return `path`.
"""
function save_selection(path::AbstractString, sel::Selection)
    mkpath(dirname(path))
    writeprops(path, selection_propdict(sel))
    path
end

"""
    load_selection(path::AbstractString, p::Production)::Selection

Read a saved selection and check it belongs to `p`. Variable substitution is off:
a selection holds literal paths, and expanding a `\$` in one would silently point
the transfer somewhere else.
"""
function load_selection(path::AbstractString, p::Production)
    sel = Selection(readprops(path; subst_pathvar = false, subst_env = false))
    sel.production == p.name || throw(ArgumentError(
        "selection $path is for production $(sel.production), not $(p.name)"))
    rstrip(normpath(sel.remote_root), '/') == p.remote_root || throw(ArgumentError(
        "selection $path has remote root $(sel.remote_root), not $(p.remote_root)"))
    sel
end

"""
    apply_selection!(h::RemoteHost, p::Production, root::Node, sel::Selection)::Node

Expand `root` along every path in `sel` and set the modes it records.
"""
function apply_selection!(h::RemoteHost, p::Production, root::Node, sel::Selection)
    for rel in sel.link
        set_mode!(find_node!(h, p, root, rel), :link)
    end
    for rel in sel.copy
        set_mode!(find_node!(h, p, root, rel), :copy)
    end
    root
end
