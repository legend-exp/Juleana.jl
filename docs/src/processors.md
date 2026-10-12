# Processors

A processor is one step of the dataflow. Run-level processors (`process_*`) are called
once per period and run, partition-level processors (`p_process_*`) once per period for
the partitions that contain it. All of them take the [`ProcessingConfig`](@ref) as
`processing_config`, the `LegendData` as `l200`, and the keyword arguments from their
`kwargs` entry in the [processing config](@ref Configuration). They distribute their
work over the worker pool with [`parallel`](@ref): a detector or file that fails is
recorded as a failure in the report, and the processor continues with the others.

Each partition processor returns `true` when it skipped a detector whose partition
starts in an earlier period (with `only_first_period`); [`run_processing`](@ref) then
waits for the same processor to finish for the previous period.

The processors are documented by topic:

- [HPGe calibration](processors_hpge.md): peak splitting, DSP, quality cuts, decay
  time, filter optimization and energy calibration;
- [Pulse shape discrimination](processors_psd.md): A/E, LQ and PSD efficiencies;
- [SiPMs, events and stability](processors_phy.md): SiPM optimization and calibration,
  event building, skims and stability plots.

## Adding a processor

Each processor is a function in its own file in `src/processors/`, included by
`src/Juleana.jl` and registered in [`Juleana.PROCESSORS`](@ref) under the name used in
the processing config. To add one:

1. Write the function in a new file `src/processors/process_xxx.jl` (or
   `p_process_xxx.jl` for a partition processor), with the signature
   `process_xxx(processing_config, l200, period, run; reprocess::Bool = false, kwargs...)`
   or `p_process_xxx(processing_config, l200, period; reprocess::Bool = false,
   only_first_period::Bool = true, kwargs...)`. Add explicit `using` imports to
   `src/Juleana.jl` for any new names it uses.
2. Add `include("processors/process_xxx.jl")` to `src/Juleana.jl`.
3. End the file with `register_processor!(process_xxx)`.
4. Add an entry `process_xxx` to the `processors` (or `p_processors`) section of the
   processing config.
5. Add the function to the processor page of its topic.

When the dataflow starts, every enabled processor of the config must be registered and
accept all of its configured `kwargs` (see [`check_processor_kwargs`](@ref)); otherwise
it stops with an error naming the processor.
