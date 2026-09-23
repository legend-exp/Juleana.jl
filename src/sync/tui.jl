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

Rebuild the `TreeView` from the inventory, keeping the cursor where it was. The
cursor is pulled back to the last row when the tree shrank under it, because a
`TreeView` whose `selected` points past the rows has no selected node at all.
"""
function rebuild_tree!(m::SyncModel)
    selected = m.tree.selected
    offset = m.tree.offset
    m.tree = TreeView(build_tree(m); selected, offset, focused = true,
                      block = Block(title = "Production: $(m.production.name) @ $(m.options.host)"))
    m.tree.selected = min(selected, tree_visible_count(m.tree))
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

The background task carries `node.remote_path` in its own id, `listing:<path>`,
so that a listing which fails only clears its own entry from `m.pending` and
never disturbs a second listing still in flight.
"""
function request_expand!(m::SyncModel, node::Node)
    (node.children !== nothing || node.remote_path in m.pending) && return m
    node.kind in (:section, :dir) || return m
    push!(m.pending, node.remote_path)
    host = m.host
    production = m.production
    spawn_task!(m.tasks, Symbol("listing:", node.remote_path)) do
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
    open_estimate!(m::SyncModel; confirm::Bool)::SyncModel

Ask rsync what the selection would actually move, in the background. `confirm`
decides which button the modal opens on: `e` looks, `t` intends to sync.
"""
function open_estimate!(m::SyncModel; confirm::Bool)
    host = m.host
    production = m.production
    selection = Selection(production, m.options.host, m.root)
    m.modal_kind = :estimating
    m.status = "estimating…"
    spawn_task!(m.tasks, :estimate) do
        (apply!(host, production, selection; dry_run = true), confirm)
    end
    m
end

"""
    start_transfer!(m::SyncModel)::SyncModel

Run the transfer in the background. The progress callback runs on that task and
never touches the model: it pushes a `TaskEvent` like every other result.
"""
function start_transfer!(m::SyncModel)
    host = m.host
    production = m.production
    selection = Selection(production, m.options.host, m.root)
    queue = m.tasks
    m.modal = Modal(title = "Transferring", message = "starting rsync…",
                    confirm_label = "", cancel_label = "")
    m.modal_kind = :transfer
    m.progress = Progress(0, 0.0, "", "")
    spawn_task!(queue, :transfer) do
        apply!(host, production, selection;
               progress = reading -> put!(queue.channel, TaskEvent(:progress, reading)))
    end
    m
end

"""
    open_prompt!(m::SyncModel, node::Node)::SyncModel

Open the "first N filekeys" prompt for a listed run directory.
"""
function open_prompt!(m::SyncModel, node::Node)
    isempty(filekey_groups(node)) && return show_error!(m, ArgumentError(
        "$(node.label) has no filekey groups; expand a run directory first"))
    m.input = TextInput(label = "N: ", text = "")
    m.modal_kind = :firstn
    m.status = ""
    m
end

"""
    open_message!(m::SyncModel, title, message)::SyncModel

Show a dialog that only has to be dismissed.
"""
function open_message!(m::SyncModel, title::AbstractString, message::AbstractString)
    m.modal = Modal(; title, message, confirm_label = "", cancel_label = "Close")
    m.modal_kind = :message
    m.status = ""
    m
end

"""
    show_error!(m::SyncModel, err)::SyncModel

Report a failure and leave the tool usable.
"""
show_error!(m::SyncModel, err) =
    (open_message!(m, "Error", sprint(showerror, err)); m.modal_kind = :error; m)

"""
    apply_prompt!(m::SyncModel)::SyncModel

Read the number from the prompt and mark that many filekeys. A number that
cannot be used is reported and the prompt stays open.
"""
function apply_prompt!(m::SyncModel)
    node = current_node(m)
    typed = strip(Tachikoma.text(m.input))
    count = tryparse(Int, typed)
    if node === nothing || count === nothing || count < 1
        m.status = "expected a positive number of filekeys, got \"$typed\""
        return m
    end
    first_n_filekeys!(node, count)
    m.input = nothing
    m.modal_kind = :none
    m.dirty = true
    m.status = ""
    rebuild_tree!(m)
end

"""
    refresh_local_state!(m::SyncModel, node::Node = m.root)::SyncModel

Recompute what is on disk for every listed node, children first so a directory
sees its children's final states.
"""
function refresh_local_state!(m::SyncModel, node::Node = m.root)
    if node.children !== nothing
        for child in node.children
            refresh_local_state!(m, child)
        end
    end
    node.local_state = node_local_state(m.production, node)
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

"""
    toggle_mode!(m::SyncModel, node::Node, mode::Symbol)::SyncModel

Turn `mode` on or off for `node`. A node that carries `mode` itself loses it; one
that only inherits it is excluded from the ancestor's choice by
[`exclude!`](@ref); anything else takes `mode` on. Every branch changes a mode,
which is why the selection is dirty afterwards.
"""
function toggle_mode!(m::SyncModel, node::Node, mode::Symbol)
    if node.mode == mode
        set_mode!(node, :none)
    elseif effective_mode(node) == mode
        exclude!(node)
    else
        set_mode!(node, mode)
    end
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

The running estimate and whatever the tool last had to say on the left, and the
selection file on the right. The right span keeps only the part of the path that
tells the files apart (the name under the default selection directory), because
`StatusBar` gives the left span priority and clips the right one away.
"""
function status_bar(m::SyncModel)
    out = m.options.out
    name = startswith(out, DEFAULT_SELECTION_DIR * "/") ?
           relpath(out, DEFAULT_SELECTION_DIR) : basename(out)
    StatusBar(
        left = [Span(format_estimate(running_estimate(m.root)), tstyle(:text_bright)),
                Span(isempty(m.status) ? "" : "   " * m.status)],
        right = [Span((m.saved === nothing ? "unsaved: " : "saved: ") * name)])
end

"""
    render_prompt(m::SyncModel, area::Rect, buf::Buffer)

The "first N filekeys" prompt. `Modal` holds static text and cannot host a
widget, so the prompt is a `Block` with a `TextInput` drawn inside it.
"""
function render_prompt(m::SyncModel, area::Rect, buf::Buffer)
    rect = center(area, 46, 5)
    inner = render(Block(title = "First N filekeys",
                         border_style = tstyle(:accent, bold = true),
                         box = BOX_HEAVY), rect, buf)
    render(m.input, inner, buf)
    nothing
end

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
    if m.progress === nothing
        render(status_bar(m), rows[2], buf)
    else
        render(Gauge(m.progress.fraction;
                     label = string(format_bytes(m.progress.bytes), "  ",
                                    m.progress.rate, "  ETA ", m.progress.eta)),
               rows[2], buf)
    end
    m.modal_kind == :firstn && return render_prompt(m, area, buf)
    m.modal === nothing || render(m.modal, area, buf)
    nothing
end

view(m::SyncModel, f::Frame) = render_sync(m, f.area, f.buffer)
should_quit(m::SyncModel) = m.quit
task_queue(m::SyncModel) = m.tasks

function update!(m::SyncModel, e::KeyEvent)
    # The transfer dialog has no buttons to answer, and Modal.handle_key!
    # returns :cancel on :escape unconditionally regardless of what labels
    # the modal carries; letting any key reach it would dismiss the dialog
    # while apply! keeps running underneath, opening the door to a second,
    # concurrent transfer.
    m.modal_kind == :transfer && return m

    # The prompt owns the keyboard while it is up; TextInput handles neither
    # :enter nor :escape, so those two are decided here.
    if m.modal_kind == :firstn
        e.key == :enter && return apply_prompt!(m)
        if e.key == :escape
            m.input = nothing
            m.modal_kind = :none
            return m
        end
        handle_key!(m.input, e)
        return m
    end

    if m.modal !== nothing
        answer = handle_key!(m.modal, e)
        answer === false && return m
        answer == :none && return m
        if m.modal_kind == :estimate && answer == :confirm
            return start_transfer!(m)
        end
        if m.modal_kind == :quit
            answer == :confirm && save!(m)
            m.quit = true
        end
        m.modal = nothing
        m.modal_kind = :none
        return m
    end

    m.modal_kind == :estimating && return m   # waiting on the dry run

    # Ctrl+C is the terminal's own way of asking to leave, and leaves the same
    # way q does, unsaved-selection question included.
    e.key == :ctrl_c && (e = KeyEvent('q'))

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
    elseif e.char == 'n'
        node === nothing || open_prompt!(m, node)
    elseif e.char == 'e'
        open_estimate!(m; confirm = false)
    elseif e.char == 't'
        open_estimate!(m; confirm = true)
    elseif e.char == 's'
        save!(m)
    elseif e.char == 'q'
        if m.dirty
            # Opens on "Save and quit": Modal defaults to :cancel, which here
            # means leaving the selection behind.
            m.modal = Modal(title = "Unsaved selection",
                            message = "Save the selection to\n$(m.options.out)\nbefore leaving?",
                            confirm_label = "Save and quit",
                            cancel_label = "Quit without saving",
                            selected = :confirm)
            m.modal_kind = :quit
        else
            m.quit = true
        end
    end
    m
end

function update!(m::SyncModel, e::TaskEvent)
    id = String(e.id)
    if startswith(id, "listing:")
        path = chopprefix(id, "listing:")
        if e.value isa Exception
            delete!(m.pending, path)
            return show_error!(m, e.value)
        end
        return attach_listing!(m, e.value)
    end

    if e.value isa Exception
        m.progress = nothing
        return show_error!(m, e.value)
    end

    if e.id == :estimate
        estimate, confirm = e.value
        m.estimate = estimate
        m.modal = Modal(title = "Estimate",
                        message = string(format_estimate(estimate), "\n",
                                         "from ", m.options.host, ":", m.production.remote_root, "\n",
                                         "into ", m.production.local_root),
                        confirm_label = "Sync", cancel_label = "Close",
                        selected = confirm ? :confirm : :cancel)
        m.modal_kind = :estimate
        m.status = ""
        return m
    elseif e.id == :progress
        m.progress = e.value
        return m
    elseif e.id == :transfer
        m.progress = nothing
        refresh_local_state!(m)
        rebuild_tree!(m)
        return open_message!(m, "Transfer complete", summary_text(e.value))
    end
    error("unexpected background result :$(e.id); every task this model spawns " *
          "must be handled here")
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
