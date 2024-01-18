# LEGEND Julia Analysis Dataflow
This package contains the main dataflow scripts to run the analysis for LEGEND-200 data in julia.
It consists of the `main.jl` to run an analysis on a single server node or cluster and several utils as well as example configuration file in the `utils/`
folder. 
To start the processing just execute the `main.jl` script with the julia interpreter.
``` bash
julia main.jl -c utils/processing_config.json
```
You can also make the script executable and run it directly. You might need to edit the first line of the script to point to your julia installation and `Project.toml` of your environment.
``` bash
./main.jl -c utils/processing_config.json
```
You should consider all necessary packages in a single environment. You can create a new environment with the `Project.toml` and `Manifest.toml` files in the corresponding data production folder on each processing node which is currently used. If you create a new environment from an existing `Project.toml` file, you have to first instantiate the environment with the `instantiate` command in the julia package manager.
``` julia
import Pkg; Pkg.instantiate()
```

# Configuration File
The `processing_config.json` file can be used to set up your own specific analysis chain in a simple JSON format. The file contains the following fields:
## `config`
In the config section, you can pass `debug` and `precompile` flags as well as environemnt variables which should be used for the analysis. The `debug` flag will print out more information during the analysis and the `precompile` flag will precompile all necessary functions before the analysis. This can be useful for debugging and testing purposes. The `env` field can be used to pass environment variables to the analysis. This can be useful to set up the analysis for different data sets. For a stable analysis, you should always set the `JULIA_DEPOT_PATH` variable to the correct path of your julia environment. 
Depending on your machine, it can be also useful to set the `QT_QPA_PLATFORM` variable to `xcb` or `offscreen` to avoid problems with the Qt backend as well as set the `JULIA_CPU_TARGET` variable to the correct CPU architecture of your machine to avoid problems with the LLVM compiler during precompilation.
## `processing`
In the processing section, you can set which `periods`, `runs` and `partitions` you wanna process in your chain. You can either pass an array with the corresponding run, period and partition numbers in any combination or just use the `"all"` keyword to process all available data such as e.g.
``` json
"processing": {
    "periods": [3],
    "runs": ["all"],
    "partitions": [1]
}
```
which will process all available runs in period 3 and only partition 1. You can also use the `"all"` keyword for all fields to process all available data.
The `"analysis_run_only`" flag can be used to only process runs which are set as `analysis_run` in the `run_info.json` file. This can be useful to only process runs which have passed quality criteria and are accepted as to be used in the final analysis.

## `processors` and `p_processors`
In the processors section, you can set which processors should be used in the analysis chain. it is necessary to have at least a `'default"` section with the following layout
``` json
"default": {
    "n_workers": 30,
    "reprocess": false,
}
```
The `n_workers` field can be used to set the default number of workers which should be used in the analysis of each process step. This can be useful to limit the number of workers on a single machine or to use all available workers on a cluster. The `reprocess` flag can be used to reprocess already processed data and deleting old pars and file outputs. Please be aware that settting this flag to `true` will delete all old data and reprocess it. 
Furthermore, you can then configure the `processors` section with the following layout
``` json
"process_decay_time": {
            "enabled": true,
            "n_workers": 2,
            "reprocess": false,
            "timeout": 300,
            "rank": 2
        },
```
which will result in processing the `process_decay_time` processor. Each processor can be enabled and disabled in the chain with the `enabled` flag. You can also indivdually overwrite the `n_workers` as well as the `reprocess`. Also you can pass additional `kwargs` in here such as timeouts etc. to be passed to the function. The `rank` field can be used to set the rank of the processor in the chain. This can be useful if the order of the processing matters. The processors will be sorted by the rank and then processed in this order. \\
The `p_processors` work in a similar manner as the `processor` with the one difference that they act on partitions rather then runs.

# Command line options
The script also offers command line options to have a handy way of processing things in the command line. A help menu is available in the command line with the `--help` flag. The following options are availbale at the moment:

| Command           | Description         |
|-------------------|---------------------|
| `--config`, `-c`  | Path to config file |
|`--reprocess`      | Reprocess all channels while deleting old data, overwrite all `reprocess` flags |
| `--only_runs`     | Process only runs ignoring periods and partitions |
| `--only_partitions` | Process only partitions ignoring periods and runs |
| `--analysis_runs_only` | Process only runs which are marked as analysis runs |
| `--periods`, `-p` | Periods to process |
| `--runs`, `-r`    | Runs to process |
| `--partitions` | Partitions to process |