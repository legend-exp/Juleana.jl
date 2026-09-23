"""
    SyncModel(host, production, options)

The interface's state. The `Node` tree is the source of truth; the `TreeView` is
rebuilt from it whenever anything changes, because `TreeView` caches its
flattened rows and mutating its nodes in place would leave that cache stale.

Which nodes are open lives in `collapsed`, not in the `TreeNode`s, for the same
reason. `pending` holds the remote paths of listings in flight.
"""
mutable struct SyncModel <: Model
    host::RemoteHost
    production::Production
    options::Options
    root::Node
    collapsed::Set{String}
    pending::Set{String}
    tree::TreeView
    tasks::TaskQueue
    dirty::Bool
    quit::Bool
    status::String
    saved::Union{Nothing,String}
    modal::Union{Nothing,Modal}
    modal_kind::Symbol
    input::Union{Nothing,TextInput}
    estimate::Union{Nothing,Estimate}
    progress::Union{Nothing,Progress}
end

function SyncModel(host::RemoteHost, production::Production, options::Options)
    m = SyncModel(host, production, options, production_tree(host, production),
                  Set{String}(), Set{String}(),
                  # Replaced immediately: rebuild_tree! needs the model to exist.
                  TreeView(TreeNode("")), TaskQueue(),
                  false, false, "", nothing,
                  nothing, :none, nothing, nothing, nothing)
    rebuild_tree!(m)
    m.tree.selected = 1
    m
end

"""
    checkbox(node::Node)::String

The tri-state marker: `[x]` copied, `[~]` linked, `[ ]` untouched, `[-]` for a
node that is untouched itself but has something chosen below it.
"""
function checkbox(node::Node)
    mode = effective_mode(node)
    mode == :copy && return "[x]"
    mode == :link && return "[~]"
    marked_below(node) ? "[-]" : "[ ]"
end

function marked_below(node::Node)
    node.children === nothing && return false
    any(child -> child.mode != :none || marked_below(child), node.children)
end

"""
    node_label(node::Node)::String

The text of one tree row. The size column is padded rather than right-aligned to
the pane, because `TreeView` prepends connectors whose width depends on depth.
"""
node_label(node::Node) = string(checkbox(node), " ", rpad(node.label, 28), " ",
                                node.size === nothing ? "…" : format_bytes(node.size))

"""
    build_tree(m::SyncModel, node::Node = m.root)::TreeNode

The `TreeNode` mirror of the inventory. An unlisted directory gets one
placeholder child so that `TreeView` draws an expand arrow for it.
"""
function build_tree(m::SyncModel, node::Node = m.root)
    children = if node.children !== nothing
        [build_tree(m, child) for child in node.children]
    elseif node.kind in (:section, :dir)
        [TreeNode(node.remote_path in m.pending ? "…listing" : "…")]
    else
        TreeNode[]
    end
    TreeNode(node_label(node); children,
             expanded = node.children !== nothing && !(node.remote_path in m.collapsed),
             content = node)
end

"""
    rebuild_tree!(m::SyncModel)::SyncModel

Rebuild the `TreeView` from the inventory, keeping the cursor where it was.
"""
function rebuild_tree!(m::SyncModel)
    selected = m.tree.selected
    offset = m.tree.offset
    m.tree = TreeView(build_tree(m); selected, offset, focused = true,
                      block = Block(title = "Production: $(m.production.name) @ $(m.options.host)"))
    m
end

"""
    current_node(m::SyncModel)::Union{Nothing,Node}

The inventory node under the cursor, or `nothing` on a placeholder row.
"""
function current_node(m::SyncModel)
    row = selected_node(m.tree)
    row === nothing && return nothing
    row.content isa Node ? row.content : nothing
end

"""
    request_expand!(m::SyncModel, node::Node)::SyncModel

Start listing `node` in the background. The listing is built on a detached node
and linked in by [`attach_listing!`](@ref) on the main thread, so nothing the
renderer is reading changes underneath it.
"""
function request_expand!(m::SyncModel, node::Node)
    (node.children !== nothing || node.remote_path in m.pending) && return m
    node.kind in (:section, :dir) || return m
    push!(m.pending, node.remote_path)
    host = m.host
    production = m.production
    spawn_task!(m.tasks, :listing) do
        scratch = Node(node.label, node.remote_path, node.kind)
        expand!(host, production, scratch)
        (node, scratch.children)
    end
    m.status = "listing $(node.label)…"
    rebuild_tree!(m)
end

"""
    attach_listing!(m::SyncModel, listing)::SyncModel
"""
function attach_listing!(m::SyncModel, listing::Tuple{Node,Vector{Node}})
    node, children = listing
    for child in children
        child.parent = node
    end
    node.children = children
    node.local_state = node_local_state(m.production, node)
    delete!(m.pending, node.remote_path)
    delete!(m.collapsed, node.remote_path)
    m.status = ""
    rebuild_tree!(m)
end

"""
    show_error!(m::SyncModel, err)::SyncModel

Report a failure and leave the tool usable.
"""
function show_error!(m::SyncModel, err)
    m.status = "error: " * sprint(showerror, err)
    m
end

"""
    save!(m::SyncModel)::String

Write the selection to the configured path and return it.
"""
function save!(m::SyncModel)
    path = save_selection(m.options.out, Selection(m.production, m.options.host, m.root))
    m.saved = path
    m.dirty = false
    m.status = ""
    path
end

function toggle_mode!(m::SyncModel, node::Node, mode::Symbol)
    set_mode!(node, effective_mode(node) == mode ? :none : mode)
    m.dirty = true
    m.status = ""
    rebuild_tree!(m)
end

"""
    details(m::SyncModel)::Paragraph

The right-hand pane: what the cursor is on, and the keys.
"""
function details(m::SyncModel)
    node = current_node(m)
    lines = node === nothing ? String[] : [
        node.label,
        node.remote_path,
        "local: $(node.local_state)",
        "size: " * (node.size === nothing ? "…" : format_bytes(node.size)),
        "",
    ]
    append!(lines, ["space copy   l link   n first N",
                    "enter expand/collapse   s save",
                    "e estimate   t sync   q quit"])
    Paragraph(join(lines, "\n"); block = Block(title = "Details"), wrap = word_wrap)
end

"""
    status_bar(m::SyncModel)::StatusBar

The running estimate on the left, and whatever the tool last had to say — or the
selection file — on the right.
"""
status_bar(m::SyncModel) = StatusBar(
    left = [Span(format_estimate(running_estimate(m.root)), tstyle(:text_bright))],
    right = [Span(isempty(m.status) ?
                  (m.saved === nothing ? "unsaved" : "saved: $(m.saved)") : m.status)])

"""
    render_sync(m::SyncModel, area::Rect, buf::Buffer)

Draw the interface into `area`. The area is explicit and nothing assumes it owns
the terminal, so the future Juleana app can host this as one screen.
"""
function render_sync(m::SyncModel, area::Rect, buf::Buffer)
    rows = split_layout(Layout(Vertical, Constraint[Fill(1), Fixed(1)]), area)
    panes = split_layout(Layout(Horizontal, Constraint[Percent(55), Fill(1)]), rows[1])
    render(m.tree, panes[1], buf)
    render(details(m), panes[2], buf)
    render(status_bar(m), rows[2], buf)
    m.modal === nothing || render(m.modal, area, buf)
    nothing
end

view(m::SyncModel, f::Frame) = render_sync(m, f.area, f.buffer)
should_quit(m::SyncModel) = m.quit
task_queue(m::SyncModel) = m.tasks

function update!(m::SyncModel, e::KeyEvent)
    node = current_node(m)

    # :up, :down, :home and :end_key are the only keys TreeView gets. It also
    # binds space, enter, left and right to expand/collapse, which would flip
    # TreeNode.expanded behind the model's back.
    if e.key in (:up, :down, :home, :end_key)
        handle_key!(m.tree, e)
        return m
    end

    if e.key == :enter || e.key == :right
        node === nothing && return m
        if node.children === nothing
            request_expand!(m, node)
        elseif e.key == :enter && !(node.remote_path in m.collapsed)
            push!(m.collapsed, node.remote_path)
            rebuild_tree!(m)
        else
            delete!(m.collapsed, node.remote_path)
            rebuild_tree!(m)
        end
        return m
    end

    if e.key == :left
        node === nothing && return m
        push!(m.collapsed, node.remote_path)
        return rebuild_tree!(m)
    end

    e.key == :char || return m

    if e.char == ' '
        node === nothing || toggle_mode!(m, node, :copy)
    elseif e.char == 'l'
        if m.production.mount_root === nothing
            m.status = "link mode needs a mount root; restart with --mount-root PATH"
        elseif node !== nothing
            toggle_mode!(m, node, :link)
        end
    elseif e.char == 's'
        save!(m)
    elseif e.char == 'q'
        m.quit = true
    end
    m
end

function update!(m::SyncModel, e::TaskEvent)
    e.value isa Exception && return show_error!(m, e.value)
    e.id == :listing && return attach_listing!(m, e.value)
    m
end

"""
    run_tui(options::Options, host::RemoteHost)::Int

Open the interface for `options` and return the exit code once it closes.
"""
function run_tui(options::Options, host::RemoteHost)
    production = Production(host, options.production, options.remote_root,
                            options.local_root; mount_root = options.mount_root)
    app(SyncModel(host, production, options))
    0
end
