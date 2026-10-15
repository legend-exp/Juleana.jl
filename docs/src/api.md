# API

```@docs
Juleana
```

## Running the dataflow

```@docs
Juleana.main
Juleana.setup_session
Juleana.run_no_tui
Juleana.run_tui
Juleana.JuleanaTUI
Juleana.send_command!
Juleana.MessageBuffer
Juleana.append_output!
Juleana.message_lines
Juleana.message_entries
Juleana.Checklist
Juleana.ChecklistItem
Juleana.ChecklistGroup
Juleana.Tachikoma.handle_key!(::Juleana.Checklist, ::Juleana.Tachikoma.KeyEvent)
Juleana.Tachikoma.handle_mouse!(::Juleana.Checklist, ::Juleana.Tachikoma.MouseEvent)
Juleana.Tachikoma.render(::Juleana.Checklist, ::Juleana.Tachikoma.Rect, ::Juleana.Tachikoma.Buffer)
Juleana.checked
Juleana.set_checked!
Juleana.current
Juleana.SetupPage
Juleana.sync_setup!
Juleana.setup_key!
Juleana.setup_mouse!
Juleana.render_setup
Juleana.ProgressPage
Juleana.progress_key!
Juleana.progress_mouse!
Juleana.render_progress
Juleana.LogPage
Juleana.log_key!
Juleana.log_mouse!
Juleana.render_log
Juleana.GraphPage
Juleana.graph_key!
Juleana.graph_mouse!
Juleana.render_graph
Juleana.ReportsPage
Juleana.reports_key!
Juleana.reports_mouse!
Juleana.render_reports
Juleana.reports_result!
Juleana.reports_visit!
Juleana.take_requests!
Juleana.read_reports
Juleana.HistoryPage
Juleana.history_key!
Juleana.history_mouse!
Juleana.render_history
Juleana.history_result!
Juleana.history_visit!
Juleana.history_selection
Juleana.read_history_page
Juleana.WorkersPage
Juleana.workers_key!
Juleana.workers_mouse!
Juleana.render_workers
Juleana.workers_result!
Juleana.workers_visit!
Juleana.workers_stale!
Juleana.workers_selected_allocation
Juleana.workers_selected_worker
Juleana.read_workers_page
Juleana.strip_span_tags
Juleana.tables_as_code
Juleana.logo_size
Juleana.render_logo
Juleana.bar_segments
Juleana.KwargsEditor
Juleana.kwargs_key!
Juleana.render_kwargs
Juleana.parse_kwarg_value
Juleana.parse_commandline
Juleana.production_config_dir
Juleana.default_config_file
Juleana.parse_period_runs
Juleana.init_process
DataflowSession
menu
Juleana.check_reports
Juleana.report_path
Juleana.read_report
Juleana.report_index
Juleana.failure_summary
Juleana.report_overview
Juleana.dataset_summary
Juleana.period_summary
Juleana.history_path
Juleana.history_section
Juleana.append_history
Juleana.read_history
Juleana.history_grid
Juleana.disk_counts
Juleana.disk_state
run_processing
ProcessingStopped
Juleana.wait_for
```

## Controller

```@docs
DataflowController
dispatch!
snapshot
wait(::DataflowController)
progress
busy_workers
step_messages
ProgressStore
show_progress
Juleana.effective_config
ControllerCommand
LoadSession
ReloadConfig
SelectPeriods
SelectRuns
SelectSteps
SetReprocess
SetAnalysisRunsOnly
SetCheckDependencies
SetKwarg
ResetKwargs
ResetDependencyGraph
StartProcessing
StopProcessing
WriteConfig
AddWorkers
CancelAllocation
CancelAll
PostponeIdleCancel
EditStartScript
Juleana.check_idle!(::DataflowController)
```

## Workers

```@docs
Juleana.WorkerManager
Juleana.WorkerAllocation
Juleana.set_worker_config!
Juleana.start_script!
Juleana.edit_start_script!
Juleana.add_workers!
Juleana.update_job_ids!
Juleana.cancel_allocation!
Juleana.cancel_all!
Juleana.allocations
Juleana.mark_activity!
Juleana.idle_deadline
Juleana.check_idle!(::Juleana.WorkerManager)
Juleana.workers_overview
```

## Processing config

```@docs
ProcessingConfig
ProcessorSpec
run_steps
ProcessorGraph
processor_graph
topological_order
required_processors
dependent_processors
layered_layout
partition_steps
check_processor_kwargs
Juleana.PROCESSORS
Juleana.register_processor!
Juleana.display_name
Juleana.RENAMED_PROCESSORS
```

## Helpers for processors

```@docs
parallel
failure_log
master_status
detector_status
truncate_string
truncate_error
load_qc_evaluator
```

## Logging

```@docs
Juleana.processing_logger
Juleana.process_log_file
Juleana.parse_log_level
UnderscoreSafeLogger
Juleana.escape_log_underscores
```
