# ![JuLeAna](logo/juleana.png)

[![Documentation for stable version](https://img.shields.io/badge/docs-stable-blue.svg)](https://legend-exp.github.io/Juleana.jl/stable)
[![Documentation for development version](https://img.shields.io/badge/docs-dev-blue.svg)](https://legend-exp.github.io/Juleana.jl/dev)
[![License](http://img.shields.io/badge/license-MIT-brightgreen.svg?style=flat)](LICENSE.md)
[![Build Status](https://github.com/legend-exp/Juleana.jl/workflows/CI/badge.svg)](https://github.com/legend-exp/Juleana.jl/actions/workflows/CI.yml)
[![Codecov](https://codecov.io/gh/legend-exp/Juleana.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/legend-exp/Juleana.jl)
[![Aqua QA](https://juliatesting.github.io/Aqua.jl/dev/assets/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)

## Documentation

* [Documentation for stable version](https://legend-exp.github.io/Juleana.jl/stable)
* [Documentation for development version](https://legend-exp.github.io/Juleana.jl/dev)

# Dataflow
This package contains the main dataflow scripts to run the analysis for LEGEND-200 data in julia.
It consists of a dataflow implementation to run an analysis on a [SLURM](https://slurm.schedmd.com)-based cluster system including following features:
- Parallel processing of data based on [ParalellProcessingTools](https://github.com/oschulz/ParallelProcessingTools.jl) to interactively connect new SLURM processes to a running `julia` session.
- Data processing of all `tier` up to the `evt` level.
- Automated report generation based on Markdown files with high level overview of each processing step.
- Automated plot generation of monitoring and analysis plots.
- Automated `pars` generation with `validity` flagging
- Partition and run based processing with automated dataflow control.

# Quick Start
To start the processing just execute the `main.jl` script with the julia interpreter.
``` bash
julia main.jl -c config/processing_config.json
```
You should consider to put all necessary packages in a single environment. The current standard environment is found in the `Project.toml` and `Manifest.toml` files in the dataflow folder and will be automatically activated if no other project is specified. 

# Command line options
The script also offers command line options to have a handy way of processing things in the command line. A help menu is available in the command line with the `--help` flag. The following options are available at the moment:

| Command           | Description         |
|-------------------|---------------------|
| `--config`, `-c`  | Path to config file |
| `--periods`, `-p` | Periods to process |
| `--runs`, `-r`    | Runs to process |
|`--reprocess`      | Reprocess all channels while deleting old data, overwrite all `reprocess` flags |
| `--only_runs`     | Process only runs ignoring periods and partitions |
| `--only_partitions` | Process only partitions ignoring periods and runs |
| `--analysis_runs_only` | Process only runs which are marked as analysis runs |
| `--submit_jobs` | Start the workers of the selected run mode automatically |
| `--runmode`, `--rm` | Run mode, `local` or `slurm`, overriding `config.runmode` |
| `--ignore_config` | Use only the command line values of the flags above instead of the config |
| `--log_path`, `-o` | Directory for log files |

Flags given on the command line override the corresponding config value only when set;
with `--ignore_config` an absent flag means `false`. `--runs` requires `--periods`.

# Debug mode
To enable the `debug` mode for fast and interactive dataflow debugging and testing, the `-i` flag for `interactive` has to be passed as argument upfront the `main.jl` script.
``` bash
julia -i main.jl -c config/processing_config.json
```
In an interactive session, `main.jl` sets up the configuration, the workers and the dependency graph and leaves the resulting `DataflowSession` in the variable `session` instead of starting the processing. Open the `debug` menu with
``` julia
menu(session)
```
Each call performs one of the following actions on the session and returns:
1. **Execute processors**: Execute individual processors which can be selected from two sub-menus consisting of `processors` and `p-processors`. Additionally, the `reprocess`/`no-reprocess` flags, a `check_dependencies` flag, and `check_report` (only summarize the failures in the existing reports of the selected processors) can be set.
2. **Select periods**: Select periods which should be processed.
3. **Select runs**: Select runs which should be processed (taken from the first selected period).
4. **Reload processing config**: Read the processing config again from disk with the original command line options. Good to modify `processor` and `p-processor` settings without exiting session.
5. **Reset dependency graph**: Reset the dependency graph and restore initial graph before any processing happened and recheck all dependencies.
6. **Submit workers**: Start new workers for the configured run mode. This can be useful to add new workers to the session without exiting the session.
7. **Exit**: Leave the menu without action.

The menu can be left with `Ctrl+c`. The processors are part of the `Juleana` package; when [Revise](https://github.com/timholy/Revise.jl) is loaded in the session, edits to the processor files take effect at the next `menu(session)` call.

The same entry point is available from any Julia session as `using Juleana; session = Juleana.main(["-c", "config/processing_config.json"])`.

# Processors
Each processor is a function in its own file in `src/processors/`, included by `src/Juleana.jl`. Run processors have the signature `process_xxx(processing_config, l200, period, run; kwargs...)` and partition processors `p_process_xxx(processing_config, l200, period; kwargs...)`; a partition processor returns `true` when its period must wait for the same processor to finish for the previous period. Every processor file ends with a registration call, which adds the function to the processor registry `Juleana.PROCESSORS` under the name used in the processing config.

To add a processor:
1. Write the function in a new file `src/processors/process_xxx.jl` (or `p_process_xxx.jl` for a partition processor). Add explicit `using` imports to `src/Juleana.jl` for any new names it uses.
2. Add `include("processors/process_xxx.jl")` to `src/Juleana.jl`.
3. End the file with `register_processor!(process_xxx)`.
4. Add an entry `process_xxx` to the `processors` (or `p_processors`) section of the processing config, see below.

When the dataflow starts, every enabled processor of the config must be registered and accept all of its configured `kwargs`, otherwise it stops with an error naming the processor.

# Setup
To set up the dataflow, you need to have a running `julia` configuration on a login node of a SLURM based cluster with the corresponding access to the *LEGEND data*. To help you set this up, the folder `setup/` contains helper scripts based on `bash` to guide you through the setup process. 

## Installation
To install your own julia on a cluster and do all necessary pre-steps to be able to process data, you can find a more detailed introduction to Juleana and the setup process in the [How-to-Legend](https://github.com/LisaSchlueter/HowTo-Legend/tree/main) repository including detailed instructions on how to setup things on different clusters. 

**Important**: Before you can run any of the code, you need to make sure that you activated the production environment once and installed all necessary packages. You can do this by running the following command:
``` julia
import Pkg; Pkg.activate("path/to/Juleana.jl")
Pkg.instantiate()
Pkg.precompile()
```

## Production environment
If you want to run the dataflow, you a need a place to store the output of your data production. This is called a production environment. Since it does not only contains your generated data, but also input data like e.g. `legend-metadata`, it requires a certain structure. To help you guide through that process, a bash script is provided `setup/production.sh` to guide you through that process. You can run it with the following command:
``` bash
bash setup/production.sh
```
It will ask for the new production name and folder and then create the necessary structure for you. It is sometimes necessary to link certain data folders to different locations to avoid copying the data multiple times. This can be done within the setup process automatically.

## Tmux environment
To run the dataflow, the `main.jl` script will be executed on a login node providing only simple production management functionality while the actual processing happens on the compute nodes. To avoid the script from stopping when you close the terminal, it is recommended to use a `tmux` session. To help you set up a tmux session, a bash script is provided in the `setup/` folder. You can run it with the following command:
``` bash
bash setup/tmux.sh
```
It will create a new tmux session with the name `Juleana` and several windows for the different tasks. You can then attach to the session with `tmux attach -t Juleana` and detach with `Ctrl+b d`. In the `monitoring` window, you will find a current overview of free nodes and jobs in the SLURM queue from your user. This will help you monitor the progress of your jobs and check how many free resources are available and can be accessed by you.

## SLURM integration
After you set up a tmux session, you can start the dataflow by running the `main.jl` script with the julia interpreter in the first window. This will start the dataflow and give you information about the running steps in the terminal. However, this will not start any SLURM processes for you. So to say, the script will wait at the beginning for new workers which the user has to add manually. This can be done with the `startjlworkers.sh` which the dataflow writes to the directory you started `main.jl` from. Here, you can find the slurm settings to add workers to the running julia session. You can run the script with the following command:
``` bash
bash startjlworkers.sh
```
Feel free to edit the settings in the script e.g. the number of nodes etc. It is also possible to run the script multiple times to add more workers to the running julia session. This is why the SLURM tab in the tmux session has multiple panes.

**Info** If you activate the `submit_jobs` option, the script will automatically add a new SLURM process to the running julia session. This can be useful to automate the process of adding new workers to the session.

# Configuration File
To communicate with the dataflow, you need to set up a configuration file. An example can be found in the `config/` folder.
The `processing_config.json` file can be used to set up your own specific analysis chain in a simple JSON format. The file contains the following fields:
## `config`
In the config section, you set the run mode, the worker settings and `ENV` environment variables.
1. **`runmode`**: `"local"` or `"slurm"`.
2. **`submit_jobs`**: flag to start the workers of the selected run mode automatically.
3. **`runmode_settings`**: `local.n` (number of local workers) and `local.julia_settings`, `slurm.flags` and `slurm.julia_settings`.
4. **`env_variables`**: field can be used to pass environment variables to the analysis. This can be useful to set up the analysis for different data sets. For a stable analysis, you should always set the `JULIA_WORKER_TIMEOUT` variable for `ParallelProcessingTools`. In addition, it can be useful to set the `JULIA_DEBUG` variable to enable debugging information for different packages.
5. **`slurm.flags`**: field can be used to pass options to the slurm processors. All available options can found in the [SLURM documentation](https://slurm.schedmd.com). Please also refer to the documentation of the specific cluster you are using and adapt the settings appropriately.
6. **`julia_settings`**: field can be used to pass options to the julia interpreter. This can be useful to set additional settings for the julia interpreter such as `--heap-size-hint` etc. Please refer to the [`julia` documentation](https://docs.julialang.org/en/v1/manual/command-line-interface/) for all available options.

## `processing`
In the processing section, you can set which `periods` and `runs` you wanna process in your chain as well as different general settings. You can either pass an array with the corresponding period and run numbers or just use the `"all"` keyword to process all available data such as e.g.
``` json
"processing": {
    "periods": [3],
    "runs": "all",
    ...
}
```
which will process all available runs in period 3. Setting `"periods"` to `"all"` processes all periods available on disk.

Other options are:
1. **`analysis_runs_only`**: flag can be used to only process runs which are set as `analysis_run` in the `legend-metadata`. This can be useful to only process runs which have passed quality criteria and are accepted as to be used in the final analysis.
2. **`only_runs`**: flag can be used to only process runs ignoring partitions processors.
3. **`only_partitions`**: flag can be used to only process partitions ignoring runs processors.

All keys of the `config` and `processing` sections are required; missing or unknown keys
stop the dataflow with an error naming the key.

## `processors` and `p_processors`
In the processors section, you can set which processors should be used in the analysis chain.

**Info**: It is necessary to have at least one entry.

You can configure the `processors` section with the following layout
``` json
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
            "dependencies": ["p_process_aoe_optimization"]
        },
```
which will result in adding the `process_dsp_cal` processor to the list and process it according to its settings. 

**Info**: The `p_processors` work in a similar manner as the `processor` with the one difference that they act on partitions rather then runs.

The following fields are required:
1. **`enabled`**: flag can be used to enable or disable the processor in the chain.
2. **`rank`**: field can be used to set the rank of the processor in the chain. This can be useful if the order of the processing matters. The processors will be sorted by the rank and then processed in this order.
3. **`category`**: `"cal"` or `"phy"`, tells the dataflow if the processor is acting on `cal` or `phy` data.
4. **`kwargs`**: keyword arguments passed to the processor. Every enabled processor must accept all of its configured keywords, plus `reprocess` and, for partition processors, `only_first_period`, which the dataflow passes on its own; this is checked when the dataflow starts. The `--reprocess` command line flag sets `reprocess` to `true` for every processor.
5. **`dependencies`**: field can be used to set dependencies to other processors. This can be useful if the processor needs to wait for a *partition* processor to finish before it can start. The processor will only start if the *partition* processor (and all lower ranks) has finished successfully. Every dependency must name a configured processor of the other level (a *run* processor can depend on *partition* processors and vice versa), and processor names must be unique across `processors` and `p_processors`.

String lists in `processors.*.kwargs` and `p_processors.*.kwargs` are converted to
Julia symbol vectors when the processing config is loaded. For example, YAML
`subsystems: [geds, spms, pmts, aux]` is passed as `[:geds, :spms, :pmts, :aux]`.
Use ordinary strings in YAML/JSON, without a leading colon. Scalar strings and
lists outside processor `kwargs` keep their original types.
