# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

# Completion flags of the run steps: `status[period][step][run]`.
const RunStatus = ConcurrentDict{DataPeriod, ConcurrentDict{Symbol, ConcurrentDict{DataRun, Bool}}}
# Completion flags of the partition steps: `status[period][step]`.
const PartitionStatus = ConcurrentDict{DataPeriod, ConcurrentDict{Symbol, Bool}}

"""
    mutable struct DataflowSession

State of a dataflow session that [`menu`](@ref) reads and edits, as returned by
[`main`](@ref) in an interactive session.

Fields:
- `args::Dict{String,Any}`: parsed command line options, used to reload the config.
- `l200::LegendData`: the LEGEND data the session processes.
- `config::ProcessingConfig`: the validated processing config.
- `periods::Vector{DataPeriod}`: selected periods.
- `runs::Union{Nothing,Vector{DataRun}}`: selected runs; `nothing` selects all runs of
  each period.
- `run_steps::Vector{Symbol}`, `partition_steps::Vector{Symbol}`: run and
  partition steps scheduled by default, sorted by rank.
- `run_status`, `partition_status`: completion flags of the dependency graph, as
  built by `setup_dependency_graph`.

`DataflowSession(; args, l200, config, periods, runs=config.runs, run_steps,
partition_steps, run_status, partition_status)` builds a session from keywords.
"""
mutable struct DataflowSession
    const args::Dict{String,Any}
    l200::LegendData
    config::ProcessingConfig
    periods::Vector{DataPeriod}
    runs::Union{Nothing,Vector{DataRun}}
    run_steps::Vector{Symbol}
    partition_steps::Vector{Symbol}
    run_status::RunStatus
    partition_status::PartitionStatus
end

DataflowSession(; args, l200, config, periods, runs = config.runs, run_steps, partition_steps,
        run_status, partition_status) =
    DataflowSession(args, l200, config, periods, runs, run_steps, partition_steps, run_status, partition_status)

"""
    run_processing(session::DataflowSession; kwargs...)

Run the session's scheduled steps over its periods and update its status flags, as
`run_processing(session.config, session.l200, session.periods, session.run_steps,
session.partition_steps, session.run_status, session.partition_status; kwargs...)`.
"""
run_processing(session::DataflowSession; kwargs...) =
    run_processing(session.config, session.l200, session.periods, session.run_steps,
        session.partition_steps, session.run_status, session.partition_status; kwargs...)

function Base.show(io::IO, session::DataflowSession)
    print(io, "DataflowSession(", length(session.periods), " period(s), ",
        isnothing(session.runs) ? "all runs" : "$(length(session.runs)) run(s)", ", ",
        length(session.run_steps), " run and ", length(session.partition_steps), " partition steps)")
end

# Enabled steps sorted by rank. With `only_runs`/`only_partitions` the other level is
# not scheduled, so its steps start as finished in the dependency graph.
selected_steps(cfg::ProcessingConfig) = (
    cfg.only_partitions ? Symbol[] : run_steps(cfg),
    cfg.only_runs ? Symbol[] : partition_steps(cfg),
)

function reset_dependency_graph!(session::DataflowSession)
    session.periods, session.run_status, session.partition_status = setup_dependency_graph(
        session.l200, session.config, session.periods, session.runs, session.run_steps, session.partition_steps)
    return session
end

# ParallelProcessingTools run mode that starts the workers configured in `cfg`.
function runprocs_mode(cfg::ProcessingConfig)
    if cfg.runmode == :local
        return OnLocalhost(n = cfg.local_n, env = cfg.env_variables)
    elseif cfg.runmode == :slurm
        return OnSlurm(
            slurm_flags = Cmd(cfg.slurm_flags),
            julia_flags = Cmd(cfg.slurm_julia_settings),
            redirect_output = false,
            env = cfg.env_variables
        )
    else
        throw(ArgumentError("unsupported runmode $(repr(cfg.runmode))"))
    end
end

"""
    init_process()

Prepare the current process for processing: set the `LegendSpecFits` fit time limit to
180 s, pin threads, and install an [`UnderscoreSafeLogger`](@ref) around a
`TerminalLogger` as the global logger. [`main`](@ref) runs it on the head and on every
worker.
"""
function init_process()
    set_timelimit(180.0)
    pinthreads_auto()
    global_logger(UnderscoreSafeLogger(TerminalLogger()))
    return nothing
end

"""
    main(args::AbstractVector{<:AbstractString} = ARGS)

Run the dataflow with the command line options `args` (see `julia main.jl --help`).

Builds the processing config and `LegendData(:l200)`, runs [`init_process`](@ref) on
this process and registers it for every worker, starts the workers of the configured
run mode (`local` workers are always started; `slurm` workers only with
`submit_jobs`, otherwise `startjlworkers.sh` is written to the package directory for
manual submission), checks the processor keyword arguments, and builds the dependency
graph for the enabled steps.

In an interactive session, return the [`DataflowSession`](@ref) to pass to
[`menu`](@ref). Otherwise run all enabled steps with [`run_processing`](@ref) and
return the session afterwards. Return `nothing` when `args` asks for `--help` or
`--version` in an interactive session.
"""
function main(args::AbstractVector{<:AbstractString} = ARGS)
    parsed_args = parse_commandline(args)
    isnothing(parsed_args) && return nothing
    l200, config, periods = setup_processing(parsed_args)
    check_processor_kwargs(config)
    @info "Start Data processing"

    # runs `init_process` on this process now and on every worker when it starts
    @always_everywhere begin
        using Juleana: Juleana
        Juleana.init_process()
    end

    mode = runprocs_mode(config)
    if config.runmode == :local
        errormonitor(@async runworkers(mode))
    else
        script = joinpath(pkgdir(Juleana), "startjlworkers.sh")
        @info "Write worker start script to $script"
        write_worker_start_script(script, mode)
        config.submit_jobs && errormonitor(@async runworkers(mode))
    end
    ppt_worker_pool!(FlexWorkerPool(withmyid = false, label = "juleana"; maxoccupancy = 1))

    run_steps, partition_steps = selected_steps(config)
    periods, run_status, partition_status = setup_dependency_graph(l200, config, periods, config.runs, run_steps, partition_steps)
    session = DataflowSession(; args = parsed_args, l200, config, periods,
        run_steps, partition_steps, run_status, partition_status)
    flush(stdout)

    if isinteractive()
        Base.exit_on_sigint(false)
        @info "Dataflow session ready, call `menu(session)` to select an action"
    else
        run_processing(session)
        @info "# Processing Done"
    end
    return session
end
