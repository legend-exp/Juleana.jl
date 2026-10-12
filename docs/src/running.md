# Running the dataflow

## Quick start

Start the processing with the `main.jl` script of the repository:

```bash
julia main.jl -c config/processing_config.json
```

When `julia` runs in the default environment, `main.jl` activates the repository
environment (`Project.toml` and `Manifest.toml` in the repository root); otherwise it
uses the active project. It then calls [`Juleana.main`](@ref) with the command line
arguments, which reads the [processing config](@ref Configuration), starts the workers
and runs all enabled processors.

The same entry point is available from any Julia session:

```julia
using Juleana
session = Juleana.main(["-c", "config/processing_config.json"])
```

## Command line options

`julia main.jl --help` prints all options.

| Option            | Description |
|:------------------|:------------|
| `--config`, `-c`  | Path of the processing config file (required) |
| `--periods`, `-p` | Periods to process, e.g. `-p 3 4` |
| `--runs`, `-r`    | Runs to process within the periods; requires `--periods` |
| `--reprocess`     | Reprocess all detectors, discarding existing results; sets `reprocess` of every processor |
| `--only_runs`, `--or` | Run only the run-level processors |
| `--only_partitions`, `--op` | Run only the partition-level processors |
| `--analysis_runs_only` | Process only runs marked as analysis runs in the metadata |
| `--submit_jobs`   | Start the workers of the selected run mode automatically |
| `--runmode`, `--rm` | Run mode, `local` or `slurm`, replacing `config.runmode` |
| `--ignore_config` | Use only the command line values of the flags above instead of the config |
| `--log_path`, `-o` | Directory for log files |

A flag given on the command line overrides the config value only when it is set; with
`--ignore_config` an absent flag means `false`. Without `--log_path` the logs go to a
new directory in the `jllog` tier, named by the current UTC time.

## Interactive mode

For debugging and testing, start `main.jl` in an interactive session with the `-i`
flag:

```bash
julia -i main.jl -c config/processing_config.json
```

In an interactive session, `main.jl` sets up the configuration, the workers and the
dependency graph and leaves the resulting [`DataflowSession`](@ref) in the variable
`session` instead of starting the processing. Open the menu with

```julia
menu(session)
```

Each call of [`menu`](@ref) performs one of the following actions on the session and
returns:

1. **Execute processors**: select run and partition processors in two sub-menus and run
   them. Options: `reprocess` or `no-reprocess` (override the configured `reprocess`),
   `check_dependencies` (rebuild the dependency graph for the selected processors and
   wait for their dependencies), and `check_report` (only summarize the failures in the
   existing reports of the selected processors, see [`Juleana.check_reports`](@ref)).
2. **Select periods**: select the periods to process.
3. **Select runs**: select the runs to process, taken from the first selected period.
4. **Reload processing config**: read the processing config from disk again with the
   original command line options, for example after changing processor settings,
   without leaving the session.
5. **Reset dependency graph**: rebuild the dependency graph for the enabled processors.
6. **Submit workers**: start new workers for the configured run mode, adding them to the
   running session.
7. **Exit**: leave the menu without action.

`Ctrl+C` leaves the menu. The processors are part of the `Juleana` package; when
[Revise](https://github.com/timholy/Revise.jl) is loaded in the session, edits to the
processor files take effect at the next `menu(session)` call.

## Running on a cluster

Running the dataflow requires a `julia` installation on a login node of a SLURM
cluster with access to the LEGEND data. The `setup/` folder contains `bash` scripts that
help with the setup.

### Production environment

A data production needs a place for its output, which also holds input data such as
`legend-metadata` in a fixed structure. `setup/production.sh` creates it:

```bash
bash setup/production.sh
```

It asks for the name and folder of the new production and creates the structure. It can
link data folders to other locations to avoid copying data.

### Tmux environment

`main.jl` runs on a login node and only manages the production; the processing happens
on the compute nodes. To keep it running when the terminal closes, run it in a `tmux`
session. `setup/tmux.sh` creates one:

```bash
bash setup/tmux.sh
```

It creates a tmux session named `Juleana` with windows for the different tasks. Attach
with `tmux attach -t Juleana` and detach with `Ctrl+b d`. The `monitoring` window shows
the free nodes and your jobs in the SLURM queue.

### SLURM workers

Start the dataflow with `main.jl` in the first tmux window. In the `slurm` run mode
without `--submit_jobs`, the dataflow does not start any SLURM jobs itself: it writes the
script `startjlworkers.sh` to the directory `main.jl` was started from and waits for
workers. Run the script to add workers to the running session:

```bash
bash startjlworkers.sh
```

The script holds the SLURM settings, such as the number of nodes, and can be edited and
run several times to add more workers; the SLURM tab of the tmux session has several
panes for this. With `submit_jobs` set in the config or on the command line, the
dataflow starts the SLURM workers itself.
