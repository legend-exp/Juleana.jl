module JuleanaSync

using ArgParse
using Dates
using PropDicts

# LegendDataManagement exports a wide surface and Tachikoma exports names such as
# `text`, `value`, `right` and `Table` that would collide with it. Both are imported
# by name, so a collision shows up here as a load error rather than at a call site.
# Loading LegendDataManagement is also what brings in JSON, which PropDicts needs
# for the extension that reads and writes the config files.
import LegendDataManagement
import Tachikoma
using LegendDataManagement: DetectorId, Timestamp
using Tachikoma: Model, Frame, Buffer, Rect, Span,
                 KeyEvent, TaskEvent, TaskQueue, spawn_task!,
                 TreeView, TreeNode, selected_node, handle_key!,
                 Block, StatusBar, Paragraph, Modal, TextInput, Gauge,
                 Layout, Constraint, Vertical, Horizontal, Fill, Fixed, Percent,
                 split_layout, render, tstyle, center, word_wrap, BOX_HEAVY, app
import Tachikoma: view, update!, should_quit, task_queue

include("remote.jl")
include("production.jl")
include("inventory.jl")
include("selection.jl")
include("estimate.jl")
include("transfer.jl")
include("options.jl")

# Later tasks add: tui.jl.

end # module
