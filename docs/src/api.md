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
Juleana.parse_commandline
Juleana.data_config_files
Juleana.with_production_config
Juleana.production_config_dir
Juleana.default_config_file
Juleana.install_default_config
Juleana.parse_period_runs
Juleana.init_process
DataflowSession
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
run_step
Juleana.ReportPlot
Juleana.display_report
Juleana.StepOutput
Juleana.@using_packages
ProcessingStopped
Juleana.partition_periods
Juleana.rank_order_dependencies
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
SetRunmode
SetRunmodeSettings
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
CreateProduction
SelectProduction
SelectDataset
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

## Data productions

```@docs
Juleana.ProductionSpec
Juleana.check_production
Juleana.create_production
Juleana.data_config_text
Juleana.running_manifest
Juleana.snapshot_software
Juleana.software_version
Juleana.production_log
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
waited_processors
layered_layout
partition_steps
check_processor_kwargs
Juleana.PROCESSORS
Juleana.register_processor!
Juleana.PROCESSOR_TRAITS
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
Juleana.redo_detector
Juleana.detector_selected
Juleana.write_pars
Juleana.write_validity
Juleana.make_par_dir
Juleana.write_report
```

## Logging

```@docs
Juleana.processing_logger
Juleana.process_log_file
Juleana.parse_log_level
UnderscoreSafeLogger
Juleana.escape_log_underscores
```
