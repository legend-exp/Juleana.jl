# ![JuLeAna](logo/juleana.png)

[![Documentation for stable version](https://img.shields.io/badge/docs-stable-blue.svg)](https://legend-exp.github.io/Juleana.jl/stable)
[![Documentation for development version](https://img.shields.io/badge/docs-dev-blue.svg)](https://legend-exp.github.io/Juleana.jl/dev)
[![Version](https://img.shields.io/github/v/release/legend-exp/Juleana.jl)](https://github.com/legend-exp/Juleana.jl/releases)
[![License](http://img.shields.io/badge/license-MIT-brightgreen.svg?style=flat)](LICENSE.md)
[![Build Status](https://github.com/legend-exp/Juleana.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/legend-exp/Juleana.jl/actions/workflows/CI.yml)
[![Codecov](https://codecov.io/gh/legend-exp/Juleana.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/legend-exp/Juleana.jl)
[![Aqua QA](https://juliatesting.github.io/Aqua.jl/dev/assets/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)

Juleana is the Julia dataflow of the LEGEND-200 analysis. It processes LEGEND-200 data
from the `raw` tier up to the event level, on a single machine or on a
[SLURM](https://slurm.schedmd.com) cluster:

- parallel processing with [ParallelProcessingTools](https://github.com/oschulz/ParallelProcessingTools.jl),
  which connects local or SLURM worker processes to a running `julia` session;
- run- and partition-level processors, ordered by rank and dependencies;
- a Markdown report for every processing step, monitoring and analysis plots, and
  parameter files with `validity` entries.

## Installation

Juleana and the other LEGEND packages are registered in the
[LegendJuliaRegistry](https://github.com/legend-exp/LegendJuliaRegistry):

```julia
import Pkg
Pkg.Registry.add("General")
Pkg.Registry.add(url = "https://github.com/legend-exp/LegendJuliaRegistry.git")
```

To run the dataflow, install Juleana as a Julia app, which creates the `juleana`
command (add `~/.julia/bin` to the `PATH`):

```julia
import Pkg
Pkg.Apps.add("Juleana")                            # or Pkg.Apps.develop(path = "path/to/Juleana.jl")
```

## Quick start

```bash
juleana                                    # terminal user interface, config of the data production
juleana -c config/processing_config.json   # a given processing config
juleana --no-tui                           # run all enabled processors without the interface
juleana --new-production                   # create a new data production
juleana --help                             # command line options
```

`config/` contains example processing configs, and `setup/` contains a script to set the
permissions of a production.

## Documentation

The [documentation](https://legend-exp.github.io/Juleana.jl/stable) describes the
concepts, the command line options and the terminal user interface, running on a cluster, the
processing config, every processor, and the API
([development version](https://legend-exp.github.io/Juleana.jl/dev)).
