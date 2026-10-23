# API: steps, plots and logging

Functions for the named steps of the processors and their debugging, for saving plots, and
for the log files.

## Steps and failures

```@docs
Juleana.root_exception
Juleana.@process_step
Juleana.ProcessStepError
Juleana.Failure
Juleana.failure
Juleana.failures
Juleana.failure_info
Juleana.failure_variables
Juleana.@locals
Juleana.rerun
```

## Plots

```@docs
Juleana.save_plot
Juleana.@debug_plot
```

## Logging

```@docs
Juleana.processing_logger
Juleana.ProcessorLevelLogger
Juleana.@debug_progress
Juleana.DEBUG_LOG_PACKAGES
Juleana.process_log_file
Juleana.parse_log_level
UnderscoreSafeLogger
Juleana.escape_log_underscores
```
