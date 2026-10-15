# Running the dataflow

## Installing the app

Juleana is a Julia app. [`Pkg.Apps`](https://pkgdocs.julialang.org/v1/apps/) installs it
in its own environment and creates the command `juleana`:

```julia
import Pkg
Pkg.Apps.add("Juleana")                              # from the registry
Pkg.Apps.develop(path = "path/to/Juleana.jl")        # or from a checkout
```

The `juleana` command is placed in `~/.julia/bin`, which must be in the `PATH`. It starts
Julia with `--threads=8,1` and `--startup-file=no`, so packages loaded by the `startup.jl`
of the user are not available. Julia options before a `--` replace these defaults:

```bash
juleana --threads=16,1 -- -c config/processing_config.json
```

Processing needs access to the LEGEND data and metadata through the `LEGEND_DATA_CONFIG`
environment variable (see the [overview](index.md)). The data production
named there also holds the `config` folder described [below](@ref "Config folder of the data production").

## Starting

```bash
juleana                                    # config of the data production
juleana -c config/processing_config.json   # a given config
juleana --help                             # all options
```

`juleana` opens a terminal user interface. It reads the [processing config](@ref Configuration),
builds the dependency graph of the enabled processors, and waits on the Setup page.
Processing starts with `s`. The interface never starts workers on its own, see
[Workers](@ref running-workers).

`juleana --no-tui` runs all enabled processors without the interface, shows progress bars,
and exits. The exit code is `0` when processing finished, `1` when it failed and `2` when
it was stopped. The first `Ctrl+C` stops after the running items, the second stops at
once. Unlike the interface, `--no-tui` starts the configured workers itself: local
workers always, SLURM workers when `submit_jobs` is set.

The same session is available from any Julia session:

```julia
using Juleana
session = Juleana.setup_session(["-c", "config/processing_config.json"])
```

## Command line options

| Option            | Description |
|:------------------|:------------|
| `--config`, `-c`  | Path of the processing config file; see [Config folder of the data production](@ref) for the default |
| `--periods`, `-p` | Periods to process, each optionally with runs: `-p 3 4` (all runs of p03 and p04), `-p 6,1` (r001 of p06), `-p 6,1-3` (r001 to r003), `-p 6,1,4-6`; repeatable, e.g. `-p 6,1 -p 7,2-4` |
| `--runs`, `-r`    | Runs to process in the periods given without runs; requires `--periods` and cannot be combined with periods given with runs |
| `--reprocess`     | Reprocess all detectors, discarding existing results; sets `reprocess` of every processor |
| `--only_runs`, `--or` | Run only the run-level processors |
| `--only_partitions`, `--op` | Run only the partition-level processors |
| `--analysis_runs_only` | Process only runs marked as analysis runs in the metadata |
| `--no-tui`        | Run all enabled processors without the terminal user interface and exit |
| `--new-production` | Open the interface on the form for a new data production, see [Creating a data production](@ref) |
| `--submit_jobs`   | Start the workers of the selected run mode automatically (with `--no-tui`) |
| `--runmode`, `--rm` | Run mode, `local` or `slurm`, replacing `config.runmode` |
| `--ignore_config` | Use only the command line values of the flags above instead of the config |
| `--log_path`, `-o` | Directory for log files |

A flag given on the command line overrides the config value only when it is set; with
`--ignore_config` an absent flag means `false`. Without `--log_path` the logs go to a
new directory in the `jllog` tier, named by the current UTC time.

## Config folder of the data production

The `config` folder of the data production is the folder `config` next to the file named
by `LEGEND_DATA_CONFIG`. Without `--config`, Juleana reads
`config/processing_config.json` from it, or the config shipped with Juleana if that file
does not exist. The folder also holds the worker start script `startjlworkers.sh`.

`w` on the Setup page writes the current settings to `config/processing_config.json` of
the data production, after a confirmation; an existing file is kept as
`processing_config.json.bak`. That file is then the default config.

## The interface

The tabs at the top open the pages, also with the keys `1` to `7`. `?` shows all keys of
the visible page, `q` or `Ctrl+C` quits.

1. **Setup**: select the periods, runs and processors, edit the keyword arguments of a
   processor (`e`) and the options, start processing (`s`), stop it (`x` after the
   running items, `X` at once), reload the config (`r`), write the settings to the
   config file (`w`), and create a new data production (`N`).
2. **Graph**: the processors with their dependencies, run-level processors on the left
   and partition-level processors on the right. `Space` selects a processor, `d` adds the
   steps that selected steps wait for, and `v` switches the state icons between the last
   run and the state on disk.
3. **Workers**: the worker allocations and the workers, see [Workers](@ref running-workers).
4. **Progress**: the steps of the processing run by period and run, with their state; `Enter`
   on a step shows its messages.
5. **Log**: the messages of the session, filtered by level (`l`) or text (`/`).
6. **Reports**: the Markdown reports of the steps and the failures they list; `Enter`
   opens a report.
7. **History**: the processing state of every processor in every run on disk.

Every processing run appends a section to `history.md` in the `jllog` tier. The History
page and the `v` view of the Graph page show the state on disk, also from earlier sessions.

## [Workers](@id running-workers)

Processing runs on worker processes, which connect to the running `juleana` process.
The interface starts workers only on request: `a` on the Workers page, or `W` on the
Setup page, starts a worker allocation by running the start script `startjlworkers.sh`
in the config folder of the data production. Juleana regenerates the script for every
session from the processing config; it holds the cookie and the address of the running
process. The Workers page shows and edits the script (`e`, `Ctrl+S` saves); edits apply to
the session.

An allocation is a group of workers started by one run of the script, local or as SLURM
jobs. An allocation runs in its own process group. `c` cancels the selected allocation and
`C` all allocations, after a confirmation; a cancel ends the processes and cancels the
SLURM jobs that carry the job name of the allocation. Quitting `juleana` cancels all
allocations.

Idle allocations are cancelled after `idle_timeout_minutes` of the
[config](@ref Configuration) (default 20, `0` disables) without processing. The status bar
shows the countdown; `p` on the Workers page postpones the cancel.

## Running on a login node

On a cluster, `juleana` runs on a login node and manages the production, while the
processing runs on compute nodes. Start it inside `tmux` or `screen` so that it keeps
running when the SSH connection ends:

```bash
tmux new -s juleana
juleana
```

Detach with `Ctrl+b d` and attach again with `tmux attach -t juleana`.

### SLURM workers

In the `slurm` run mode the start script submits SLURM jobs with the settings of
`runmode_settings.slurm` in the config, such as the number of nodes. Edit the script on
the Workers page to change them for the session, and start further allocations with `a`.

## Creating a data production

A data production is a folder with the metadata, the generated output and a data config
file. `juleana --new-production` opens the interface on a form for a new one, and `N` on the
Setup page opens the same form. Without `--config` and without `LEGEND_DATA_CONFIG`, the
interface opens on the form as well and loads no session.

The form asks for

- the name and the parent folder (by default the folder that holds the current production),
- the URL of the `legend-metadata` repository,
- whether to check out branches in the metadata and which ones: the `jldataprod` branch for
  the `jldataprod` config and overrides submodules and the `dataprod` branch for the
  metadata and its other submodules (both `main` by default),
- extra tier paths, `label` and folder of tiers that are kept elsewhere,
- parameter folders to copy, each with a `rpars` or `ppars` component in its path,
- whether to set the new production as the default in the startup file of the shell
  (`.bashrc` or `.zshrc`, by `$SHELL`), and
- whether to copy the software into the production (yes by default).

`↑`, `↓` and `Tab` move between the fields, typed characters and `Backspace` edit a text
field, `Space` or `Enter` flips a yes/no field, `Ctrl-N` adds a row to the list under the
cursor and `Ctrl-D` removes it, `Ctrl-S` creates the production and `Esc` closes the form.
The input is checked first and the first problem is shown in the form. An existing folder
is refused.

The production folder `<parent>/<name>` then holds

- `legend-metadata`, a recursive clone of the metadata with the chosen branches checked out,
- the folders `generated/{tier,jllog,jlplt,jlreport,jlpar/rpars,jlpar/ppars}`,
- `config.json`, the data config with one `tier/<label>` entry per extra tier path,
- the copied parameters in `generated/jlpar`,
- `software`, a copy of the Juleana checkout and of the other developed packages of the
  running environment with a manifest that refers to the copies, and `PROVENANCE.md` with
  the source folder, commit and uncommitted changes of each package (see
  [`Juleana.snapshot_software`](@ref)), and
- optionally the line `export LEGEND_DATA_CONFIG=<production>/config.json` in the shell
  startup file, replacing earlier lines that export the variable.

The form shows the log of the creation. Afterwards this process uses the new production:
it cancels its worker allocations, sets `LEGEND_DATA_CONFIG` and loads a session from it.

## Updating

Update Juleana and the LEGEND packages in the environment of the app with

```julia
import Pkg
Pkg.Apps.update("Juleana")
```

For an app installed with `Pkg.Apps.develop`, pull the checkout first. The update also
updates the dependencies in the `Project.toml` environment of the checkout.
