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
Juleana.parse_commandline
Juleana.init_process
DataflowSession
menu
Juleana.check_reports
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
SetCheckDependencies
SetKwarg
ResetKwargs
ResetDependencyGraph
StartProcessing
StopProcessing
WriteConfig
SubmitWorkers
```

## Processing config

```@docs
ProcessingConfig
ProcessorSpec
run_steps
partition_steps
check_processor_kwargs
Juleana.PROCESSORS
Juleana.register_processor!
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
