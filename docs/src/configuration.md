# Configuration

```@meta
DocTestSetup = :(using Juleana)
```

The processing config file sets up the analysis chain. Examples are in the `config/`
folder of the repository: `processing_config.json` and `processing_config.yaml`. The
file is loaded into a [`ProcessingConfig`](@ref); all keys of the `config` and
`processing` sections are required except `idle_timeout_minutes`, and a missing or
unknown key stops the dataflow with an error that names the key.

## `config`

The run mode, the worker settings, environment variables and logging:

1. **`runmode`**: `"local"` or `"slurm"`.
2. **`submit_jobs`**: start the workers of the selected run mode automatically.
3. **`runmode_settings`**: `local.n` (number of local workers) and
   `local.julia_settings`, `slurm.flags` and `slurm.julia_settings`.
   - **`slurm.flags`**: options passed to SLURM, see the
     [SLURM documentation](https://slurm.schedmd.com) and the documentation of the
     cluster you use.
   - **`julia_settings`**: options passed to the `julia` processes of the workers, such
     as `--heap-size-hint`; see the
     [`julia` command line documentation](https://docs.julialang.org/en/v1/manual/command-line-interface/).
4. **`env_variables`**: environment variables set for the dataflow and its workers,
   for example to select a data set. Set `JULIA_WORKER_TIMEOUT` for a stable connection
   of the ParallelProcessingTools workers; `JULIA_DEBUG` enables debug messages of the
   listed packages.
5. **`log_level`**: `"debug"`, `"info"`, `"warn"` or `"error"`, the level of the records
   that every process writes to its log file in the log directory (`head.log` for the
   main process, `worker-<id>-<host>.log` for each worker). `"debug"` adds the debug
   records of the packages listed in `JULIA_DEBUG`.
6. **`idle_timeout_minutes`** (optional, default `20`): when no processing has run for
   this many minutes, the worker allocations started from the terminal user interface
   are cancelled, so that idle workers do not hold a machine or a SLURM allocation. The
   time counts from the end of the last processing run, the start of the newest
   allocation or the last postponement, whichever is latest. `0` never cancels them.

## `processing`

The `periods` and `runs` to process, each either a list of numbers or `"all"`:

```json
"processing": {
    "periods": [3],
    "runs": "all",
    ...
}
```

processes all available runs of period 3. `"periods": "all"` processes all periods
available on disk. The other keys are flags:

1. **`analysis_runs_only`**: process only runs marked as analysis runs in
   `legend-metadata`, i.e. runs that passed the quality criteria for the final analysis.
2. **`only_runs`**: run only the run-level processors.
3. **`only_partitions`**: run only the partition-level processors.

## `processors` and `p_processors`

The run-level processors (`processors`) and partition-level processors (`p_processors`)
of the chain, keyed by processor name. At least one processor must be enabled. An entry
looks like this:

```json
"process_dsp_cal": {
    "enabled": true,
    "category": "cal",
    "rank": 5,
    "kwargs": {
        "reprocess": true,
        "max_wvfs": 1000,
        "timeout": 0,
        "use_partition_pars": true
    },
    "dependencies": ["p_process_aoe_optimization_cal"]
}
```

All fields are required:

1. **`enabled`**: whether the processor runs.
2. **`category`**: `"cal"` or `"phy"`, the data category the processor works on.
3. **`rank`**: position in the processing order; processors run sorted by rank.
4. **`kwargs`**: keyword arguments passed to the processor; the [Processors](@ref) page
   lists the keywords of each processor. Every enabled processor must accept all of its
   configured keywords, plus `reprocess` and, for partition processors,
   `only_first_period`, which the dataflow passes on its own. This is checked when the
   dataflow starts. The `--reprocess` command line flag sets `reprocess` to `true` for
   every processor.
5. **`dependencies`**: processors of the other level that must finish first. A run
   processor that depends on a partition processor starts only when that processor and
   all partition processors ranked before it have finished for the period; a partition
   processor that depends on a run processor waits for it in all runs of the period.
   Every dependency must name a configured processor of the other level, and processor
   names must be unique across `processors` and `p_processors`.

A key or dependency that uses a former processor name from `Juleana.RENAMED_PROCESSORS`
(for example `process_decay_time` for `process_decay_time_cal`) is read as the current
name, and a warning names both once when the config is loaded. A config that contains
both names of one processor is an error.

String lists in the `kwargs` of a processor become Julia symbol vectors when the config
is loaded: YAML `subsystems: [geds, spms, pmts, aux]` is passed as
`[:geds, :spms, :pmts, :aux]`. Use plain strings in YAML and JSON, without a leading
colon. Scalar strings, and lists outside processor `kwargs`, keep their types.

## Building a config in Julia

[`ProcessingConfig`](@ref) can also be built from keywords, which is convenient for
tests. [`run_steps`](@ref) and [`partition_steps`](@ref) return the enabled processors
in processing order:

```jldoctest config
julia> cfg = ProcessingConfig(;
           processors = Dict(
               :process_dsp_cal => ProcessorSpec(; name = :process_dsp_cal, level = :run,
                   category = :cal, rank = 5, dependencies = [:p_process_decay_time_cal]),
               :process_peak_split_cal => ProcessorSpec(; name = :process_peak_split_cal, level = :run,
                   category = :cal, rank = 1)),
           p_processors = Dict(
               :p_process_decay_time_cal => ProcessorSpec(; name = :p_process_decay_time_cal,
                   level = :partition, category = :cal, rank = 2)));

julia> run_steps(cfg)
2-element Vector{Symbol}:
 :process_peak_split_cal
 :process_dsp_cal

julia> partition_steps(cfg)
1-element Vector{Symbol}:
 :p_process_decay_time_cal

julia> check_processor_kwargs(cfg)  # all processors are registered and accept their kwargs
```

An inconsistent config is rejected when it is built:

```jldoctest config
julia> ProcessingConfig(;
           processors = Dict(:process_dsp_cal => ProcessorSpec(; name = :process_dsp_cal,
               level = :run, category = :cal, rank = 5, dependencies = [:p_process_unknown])),
           p_processors = Dict{Symbol,ProcessorSpec}())
ERROR: ArgumentError: processing_config: key `processors.process_dsp_cal.dependencies` names unknown processor `p_process_unknown`
```
