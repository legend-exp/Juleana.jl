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

To run the dataflow, clone this repository and install its environment:

```bash
julia --project=. -e 'import Pkg; Pkg.instantiate(); Pkg.precompile()'
```

## Quick start

```bash
julia main.jl -c config/processing_config.json      # run all enabled processors
julia -i main.jl -c config/processing_config.json   # interactive: then call menu(session)
julia main.jl --help                                # command line options
```

`config/` contains example processing configs, and `setup/` contains scripts to set up a
production and a `tmux` session on a cluster.

## Documentation

The [documentation](https://legend-exp.github.io/Juleana.jl/stable) describes the
concepts, the command line options and the interactive menu, running on a cluster, the
processing config, every processor, and the API
([development version](https://legend-exp.github.io/Juleana.jl/dev)).
