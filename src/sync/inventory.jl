"""
    Node(label, remote_path, kind; size, children, mode, parent, local_state)

One row of the inventory tree.

`kind` is `:production` (the tree root), `:section` (one configured path key),
`:dir`, `:group` (one filekey or one detector, standing for the files that belong
to it) or `:file`.

`children === nothing` means "not listed yet", which is different from an empty
directory. `mode` is the mode chosen explicitly on this node; the mode that
actually applies is [`effective_mode`](@ref), which falls back to the ancestors.
"""
mutable struct Node
    label::String
    remote_path::String
    kind::Symbol
    size::Union{Nothing,Int}
    children::Union{Nothing,Vector{Node}}
    mode::Symbol
    parent::Union{Nothing,Node}
    local_state::Symbol
end

Node(label::AbstractString, remote_path::AbstractString, kind::Symbol;
     size = nothing, children = nothing, mode::Symbol = :none,
     parent = nothing, local_state::Symbol = :missing) =
    Node(label, remote_path, kind, size, children, mode, parent, local_state)

# A LEGEND tier file name: setup, period, run, category, an id, and the tier.
# The id is either a timestamp (one file per filekey) or a detector name (one
# file per detector); which one decides how the directory is grouped.
const _tier_file_expr = r"^[a-z][a-z0-9]*-p[0-9]{2}-r[0-9]{3}-[a-z]+-(.+)-tier_[a-z0-9]+\.[a-z0-9]+$"

"""
    tier_file_id(name::AbstractString)

`(:filekey, timestamp)` or `(:detector, detector_name)` for a LEGEND tier file
name, and `nothing` for anything else. A name that does not match is not an
error: READMEs and scratch files legitimately sit in a run directory.
"""
function tier_file_id(name::AbstractString)
    m = match(_tier_file_expr, name)
    m === nothing && return nothing
    id = String(m[1])
    LegendDataManagement._can_convert_to(Timestamp, id) && return (:filekey, id)
    LegendDataManagement._can_convert_to(DetectorId, id) && return (:detector, id)
    nothing
end

"""
    group_children(entries, dir)::Vector{Node}

Turn one directory listing into tree rows: directories first, then one `:group`
per filekey in timestamp order, then one `:group` per detector by name, then the
files that carry no LEGEND id.
"""
function group_children(entries::AbstractVector{DirEntry}, dir::AbstractString)
    dirs = Node[]
    filekeys = Node[]
    detectors = Node[]
    plain = Node[]
    for entry in entries
        path = joinpath(dir, entry.name)
        if entry.kind == :dir
            push!(dirs, Node(entry.name, path, :dir))
            continue
        end
        file = Node(entry.name, path, :file; size = entry.size)
        id = tier_file_id(entry.name)
        if id === nothing
            push!(plain, file)
            continue
        end
        # The group holds the single file it stands for, so that groups and files
        # are handled identically everywhere downstream.
        group = Node(id[2], path, :group; size = entry.size, children = [file])
        file.parent = group
        push!(id[1] == :filekey ? filekeys : detectors, group)
    end
    sort!(dirs; by = n -> n.label)
    sort!(filekeys; by = n -> Timestamp(n.label).unixtime)
    sort!(detectors; by = n -> n.label)
    sort!(plain; by = n -> n.label)
    vcat(dirs, filekeys, detectors, plain)
end

"""
    production_tree(h::RemoteHost, p::Production)::Node

The tree root: the production's `config.json` followed by one `:section` per
configured path key, in key order.
"""
function production_tree(h::RemoteHost, p::Production)
    dir = joinpath(p.remote_root, p.name)
    entries = list_dir(h, dir)
    i = findfirst(e -> e.name == "config.json", entries)
    i === nothing && throw(ArgumentError("no config.json in $dir"))
    root = Node("Production: $(p.name)", dir, :production)
    children = Node[Node("config.json", joinpath(dir, "config.json"), :file;
                         size = entries[i].size)]
    for (key, path) in p.roots
        push!(children, Node(key, path, :section))
    end
    for child in children
        child.parent = root
    end
    root.children = children
    root.local_state = node_local_state(p, root)
    root
end

"""
    expand!(h::RemoteHost, p::Production, node::Node)::Node

List `node` if it has not been listed yet, size its directory children with one
call, and refresh its local state. Returns `node`.
"""
function expand!(h::RemoteHost, p::Production, node::Node)
    node.children === nothing || return node
    node.kind in (:section, :dir) || throw(ArgumentError(
        "a :$(node.kind) node cannot be expanded: $(node.label)"))
    children = group_children(list_dir(h, node.remote_path), node.remote_path)
    dirs = [c for c in children if c.kind == :dir]
    if !isempty(dirs)
        sizes = dir_sizes(h, [c.remote_path for c in dirs])
        for i in eachindex(dirs, sizes)
            dirs[i].size = sizes[i]
        end
    end
    for child in children
        child.parent = node
    end
    node.children = children
    node.local_state = node_local_state(p, node)
    node
end

"""
    node_local_state(p::Production, node::Node)::Symbol

`:linked` when a symlink stands at the node's local path, `:present` when the
data is there, `:partial` when a listed directory has some of its children, and
`:missing` otherwise.
"""
function node_local_state(p::Production, node::Node)
    path = to_local(p, node.remote_path)
    islink(path) && return :linked
    isfile(path) && return :present
    isdir(path) || return :missing
    node.children === nothing && return isempty(readdir(path)) ? :missing : :present
    states = map(c -> node_local_state(p, c), node.children)
    all(==(:missing), states) && return :missing
    all(s -> s in (:present, :linked), states) ? :present : :partial
end

"""
    filekey_groups(node::Node)::Vector{Node}

The filekey groups among `node`'s children, in timestamp order. Empty when the
directory has not been listed or holds no filekey-named files.
"""
filekey_groups(node::Node) = node.children === nothing ? Node[] :
    [c for c in node.children
     if c.kind == :group && LegendDataManagement._can_convert_to(Timestamp, c.label)]
