# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

"""
    abstract type ControllerCommand

Supertype of the commands that [`dispatch!`](@ref) applies to a [`DataflowController`](@ref).
"""
abstract type ControllerCommand end

"""
    LoadSession()

Set up the session from the controller's command line options with
[`setup_session`](@ref): read the config and the LEGEND data and start the workers. Runs
in the background; the controller is `:loading` until it is `:ready`. Allowed when the
controller is `:idle`.
"""
struct LoadSession <: ControllerCommand end

"""
    ReloadConfig()

Read the processing config file again with the original command line options, keeping
the log directory, and reset the selection to the config's periods, runs and enabled
processors. Drops all kwarg overrides. Runs in the background like [`LoadSession`](@ref).
"""
struct ReloadConfig <: ControllerCommand end

"""
    SelectPeriods(periods)

Select the periods to process, given as `DataPeriod`s or anything `DataPeriod` accepts.
Every period must be available on disk. Periods that stay selected keep their runs.
"""
struct SelectPeriods <: ControllerCommand
    periods::Vector{DataPeriod}
    SelectPeriods(periods) = new(DataPeriod[DataPeriod(p) for p in periods])
end

"""
    SelectRuns(runs)

Select the runs to process.

- `nothing` selects all runs of the selected periods.
- A vector of `DataRun`s (or anything `DataRun` accepts) selects the same runs in every
  selected period; every run must be available in at least one selected period.
- A dict of period => runs (keys and values as `DataPeriod` and `DataRun` accept)
  selects exactly these periods, each with its runs, where `nothing` stands for all runs
  of the period. Every period and every run of it must be available on disk.
"""
struct SelectRuns <: ControllerCommand
    runs::Union{Nothing,Vector{DataRun},Dict{DataPeriod,Union{Nothing,Vector{DataRun}}}}
    SelectRuns(::Nothing) = new(nothing)
    SelectRuns(runs::AbstractDict) = new(Dict{DataPeriod,Union{Nothing,Vector{DataRun}}}(
        DataPeriod(p) => (isnothing(r) ? nothing : DataRun[DataRun(x) for x in r]) for (p, r) in runs))
    SelectRuns(runs) = new(DataRun[DataRun(r) for r in runs])
end

"""
    SelectSteps(run_steps, partition_steps)

Select the run-level and partition-level processors to run, by name. Every name must be
a processor of that level in the config, enabled or not. The steps run in rank order.
"""
struct SelectSteps <: ControllerCommand
    run_steps::Vector{Symbol}
    partition_steps::Vector{Symbol}
    SelectSteps(run_steps, partition_steps) = new(Symbol.(run_steps), Symbol.(partition_steps))
end

"""
    SetReprocess(reprocess::Union{Nothing,Bool})

Set the `reprocess` keyword passed to every processor: `true` or `false` override the
config, `nothing` keeps the configured values.
"""
struct SetReprocess <: ControllerCommand
    reprocess::Union{Nothing,Bool}
end

"""
    SetCheckDependencies(check::Bool)

Choose whether a processing run rebuilds the dependency graph for the selected steps and
waits for their dependencies (`true`), or runs the selected steps on the current graph
without waiting (`false`).
"""
struct SetCheckDependencies <: ControllerCommand
    check::Bool
end

"""
    SetAnalysisRunsOnly(only::Bool)

Choose whether processing skips the runs that are not analysis runs (`true`) or processes
every run in the run info (`false`), instead of the setting of the config.
"""
struct SetAnalysisRunsOnly <: ControllerCommand
    only::Bool
end

"""
    SetKwarg(step, key, value)

Override the keyword argument `key` of the processor `step` for this session. The
processor function must accept `key`.
"""
struct SetKwarg <: ControllerCommand
    step::Symbol
    key::Symbol
    value::Any
    SetKwarg(step, key, value) = new(Symbol(step), Symbol(key), value)
end

"""
    ResetKwargs(step = nothing, key = nothing)

Drop the kwarg overrides of all processors, of the processor `step`, or only the override
of `key` of the processor `step`.
"""
struct ResetKwargs <: ControllerCommand
    step::Union{Nothing,Symbol}
    key::Union{Nothing,Symbol}
    function ResetKwargs(step = nothing, key = nothing)
        isnothing(step) && !isnothing(key) && throw(ArgumentError("ResetKwargs: a key needs a processor"))
        return new(isnothing(step) ? nothing : Symbol(step), isnothing(key) ? nothing : Symbol(key))
    end
end

"""
    ResetDependencyGraph()

Mark the selected steps as unfinished for the selected periods and runs.
"""
struct ResetDependencyGraph <: ControllerCommand end

"""
    StartProcessing()

Run the selected steps over the selected periods and runs in the background with
[`run_processing`](@ref), using the config with the session's kwarg overrides. The
controller is `:running` until the run ends; the outcome is `:finished`, `:failed` or
`:stopped`. [`progress`](@ref) shows the progress of the run. Throws an `ArgumentError` when no step is selected or a selected processor
does not accept its keyword arguments.
"""
struct StartProcessing <: ControllerCommand end

"""
    StopProcessing(; force::Bool = false)

Stop the processing run: no further step or item starts, items running on workers
finish, and the run ends as `:stopped`. With `force = true`, the run ends without waiting
for the running items. They count as not run, go on in the background and keep their
workers busy until they end; [`busy_workers`](@ref) lists them as abandoned. No worker is
stopped.
"""
struct StopProcessing <: ControllerCommand
    force::Bool
end
StopProcessing(; force::Bool = false) = StopProcessing(force)

"""
    WriteConfig(path::AbstractString)

Write the processing config file of the session to `path` with the current settings of
the session: the kwarg overrides are applied to the processor entries, every processor
is `enabled` exactly when it is selected, and `processing.analysis_runs_only` is the
setting in effect. An existing file at `path` is first copied to `path * ".bak"`. The
format follows the file extension (`.json` or `.yaml`).
"""
struct WriteConfig <: ControllerCommand
    path::String
end

"""
    SubmitWorkers()

Start workers for the configured run mode and add them to the worker pool.
"""
struct SubmitWorkers <: ControllerCommand end

"""
    mutable struct DataflowController

Headless state of an interactive dataflow session. All changes go through
[`dispatch!`](@ref) with a [`ControllerCommand`](@ref); [`snapshot`](@ref) returns a
read-only view of the state and [`progress`](@ref) the progress of the current or last
processing run. Commands may be sent from any task; long-running ones
(loading the session, reloading the config, processing) run in the background.

The controller is in one of the states
- `:idle`: no session loaded yet,
- `:loading`: the session or config is being loaded,
- `:ready`: a session is loaded and no processing runs,
- `:running`: processing runs,
- `:stopping`: processing was asked to stop and runs until the running items finish.

Constructors:
- `DataflowController(args::AbstractDict; processors = PROCESSORS, console = true)`
  starts `:idle` with the parsed command line options `args`; [`LoadSession`](@ref)
  sets up the session, with terminal log output of this process only if `console`.
- `DataflowController(session::DataflowSession; processors = PROCESSORS)` starts
  `:ready` with an existing session.

`processors` maps processor names to their functions.
"""
mutable struct DataflowController
    const args::Dict{String,Any}
    const processors::AbstractDict{Symbol}
    const loader::Any
    const lock::ReentrantLock
    const stop::Threads.Atomic{Bool}
    const abandon::Threads.Atomic{Bool}
    const progress::ProgressStore
    state::Symbol
    session::Union{Nothing,DataflowSession}
    # selected periods, including those without runs to process
    periods::Vector{DataPeriod}
    available_periods::Vector{DataPeriod}
    available_runs::Dict{DataPeriod,Vector{DataRun}}
    reprocess::Union{Nothing,Bool}
    analysis_runs_only::Union{Nothing,Bool}
    check_dependencies::Bool
    kwarg_overrides::Dict{Symbol,Dict{Symbol,Any}}
    task::Union{Nothing,Task}
    outcome::Union{Nothing,Symbol}
    last_error::Union{Nothing,String}
    started::Union{Nothing,DateTime}
    finished::Union{Nothing,DateTime}
end

function DataflowController(args::AbstractDict; processors::AbstractDict{Symbol} = PROCESSORS,
        console::Bool = true, loader = parsed_args -> setup_session(parsed_args; console))
    return DataflowController(Dict{String,Any}(args), processors, loader, ReentrantLock(),
        Threads.Atomic{Bool}(false), Threads.Atomic{Bool}(false), ProgressStore(), :idle, nothing, DataPeriod[], DataPeriod[],
        Dict{DataPeriod,Vector{DataRun}}(), nothing, nothing, true, Dict{Symbol,Dict{Symbol,Any}}(),
        nothing, nothing, nothing, nothing, nothing)
end

function DataflowController(session::DataflowSession; processors::AbstractDict{Symbol} = PROCESSORS)
    ctrl = DataflowController(session.args; processors, loader = nothing)
    install_session!(ctrl, session)
    return ctrl
end

function Base.show(io::IO, ctrl::DataflowController)
    print(io, "DataflowController(", repr(ctrl.state))
    isnothing(ctrl.session) || print(io, ", ", ctrl.session)
    print(io, ")")
end

# Take over `session` and scan the periods and runs on disk; the caller holds the lock.
function install_session!(ctrl::DataflowController, session::DataflowSession)
    ctrl.session = session
    ctrl.periods = copy(session.periods)
    ctrl.available_periods = available_periods(session.l200)
    ctrl.available_runs = Dict(p => available_runs(session.l200, p) for p in ctrl.available_periods)
    ctrl.state = :ready
    return ctrl
end

# Run `f` in the background with the controller `:loading`; an error is kept as
# `last_error` and the controller returns to `fallback`.
function load_in_background!(f, ctrl::DataflowController, fallback::Symbol)
    ctrl.state = :loading
    ctrl.last_error = nothing
    ctrl.task = Threads.@spawn try
        f()
    catch e
        @error "Loading the session failed" exception = (e, catch_backtrace())
        @lock ctrl.lock begin
            ctrl.last_error = truncate_error(e)
            ctrl.state = fallback
        end
    end
    return nothing
end

function require_state(ctrl::DataflowController, cmd::ControllerCommand, states::Symbol...)
    ctrl.state in states ||
        throw(ArgumentError("$(nameof(typeof(cmd))) is not possible while the controller is $(repr(ctrl.state))"))
    return nothing
end

# Processor specs of `specs` with the session's kwarg overrides merged into their kwargs.
function with_overrides(specs::AbstractDict{Symbol,ProcessorSpec}, overrides::AbstractDict)
    return Dict{Symbol,ProcessorSpec}(name => !haskey(overrides, name) ? spec :
        ProcessorSpec(spec.name, spec.level, spec.enabled, spec.category, spec.rank,
            spec.dependencies, merge(spec.kwargs, overrides[name])) for (name, spec) in specs)
end

"""
    effective_config(ctrl::DataflowController)

Return the session's [`ProcessingConfig`](@ref) with the kwarg overrides of the
controller merged into the processor kwargs and its `analysis_runs_only` setting
applied.
"""
function effective_config(ctrl::DataflowController)
    cfg = ctrl.session.config
    return ProcessingConfig(cfg.runmode, cfg.submit_jobs, cfg.local_n, cfg.local_julia_settings,
        cfg.slurm_flags, cfg.slurm_julia_settings, cfg.env_variables, cfg.periods, cfg.runs,
        something(ctrl.analysis_runs_only, cfg.analysis_runs_only), cfg.only_partitions, cfg.only_runs, cfg.log_path, cfg.log_level,
        with_overrides(cfg.processors, ctrl.kwarg_overrides), with_overrides(cfg.p_processors, ctrl.kwarg_overrides))
end

processor_spec(cfg::ProcessingConfig, step::Symbol) =
    haskey(cfg.processors, step) ? cfg.processors[step] :
    haskey(cfg.p_processors, step) ? cfg.p_processors[step] :
    throw(ArgumentError("unknown processor `$step`"))

"""
    dispatch!(ctrl::DataflowController, cmd::ControllerCommand)

Apply `cmd` to `ctrl` and return `nothing`. Throw an `ArgumentError` that explains why
when the command is not possible in the controller's state or its arguments are invalid;
the controller is then unchanged. Commands that run in the background return as soon as
they are started; see [`snapshot`](@ref) for their state and `wait(ctrl)` to block
until they are done.
"""
function dispatch! end

dispatch!(ctrl::DataflowController, cmd::ControllerCommand) = @lock ctrl.lock apply!(ctrl, cmd)

function apply!(ctrl::DataflowController, cmd::LoadSession)
    require_state(ctrl, cmd, :idle)
    load_in_background!(ctrl, :idle) do
        session = ctrl.loader(ctrl.args)
        @lock ctrl.lock install_session!(ctrl, session)
    end
end

function apply!(ctrl::DataflowController, cmd::ReloadConfig)
    require_state(ctrl, cmd, :ready)
    load_in_background!(ctrl, :ready) do
        session = ctrl.session
        l200, config, periods = setup_processing(session.args)
        check_processor_kwargs(config; ctrl.processors)
        @lock ctrl.lock begin
            session.l200, session.config, session.periods, session.runs = l200, config, periods, session_runs(session.args, config)
            session.run_steps, session.partition_steps = selected_steps(config)
            empty!(ctrl.kwarg_overrides)
            reset_dependency_graph!(session)
            install_session!(ctrl, session)
        end
        @info "Reloaded processing config"
    end
end

function check_available_periods(ctrl::DataflowController, periods)
    unknown = setdiff(periods, ctrl.available_periods)
    isempty(unknown) || throw(ArgumentError("periods not available on disk: $(join(string.(unknown), ", "))"))
    return nothing
end

# Rebuild the dependency graph for the selected periods; periods without runs to process
# stay selected in the controller.
function select_periods!(ctrl::DataflowController, periods)
    ctrl.periods = sort(unique(periods))
    ctrl.session.periods = copy(ctrl.periods)
    reset_dependency_graph!(ctrl.session)
    return nothing
end

function apply!(ctrl::DataflowController, cmd::SelectPeriods)
    require_state(ctrl, cmd, :ready)
    check_available_periods(ctrl, cmd.periods)
    runs = ctrl.session.runs
    if runs isa AbstractDict
        filter!(((p, _),) -> p in cmd.periods, runs)
        isempty(runs) && (ctrl.session.runs = nothing)
    end
    select_periods!(ctrl, cmd.periods)
end

function apply!(ctrl::DataflowController, cmd::SelectRuns)
    require_state(ctrl, cmd, :ready)
    session = ctrl.session
    if cmd.runs isa AbstractDict
        check_available_periods(ctrl, keys(cmd.runs))
        for (period, runs) in cmd.runs
            unknown = isnothing(runs) ? DataRun[] : setdiff(runs, ctrl.available_runs[period])
            isempty(unknown) ||
                throw(ArgumentError("runs not available in $period: $(join(string.(unknown), ", "))"))
        end
        explicit = Dict{DataPeriod,Vector{DataRun}}(p => sort(unique(r)) for (p, r) in cmd.runs if !isnothing(r))
        session.runs = isempty(explicit) ? nothing : explicit
        select_periods!(ctrl, collect(keys(cmd.runs)))
    else
        if !isnothing(cmd.runs)
            selectable = reduce(union, (ctrl.available_runs[p] for p in ctrl.periods); init = DataRun[])
            unknown = setdiff(cmd.runs, selectable)
            isempty(unknown) ||
                throw(ArgumentError("runs not available in the selected periods: $(join(string.(unknown), ", "))"))
        end
        session.runs = isnothing(cmd.runs) ? nothing : sort(unique(cmd.runs))
        select_periods!(ctrl, ctrl.periods)
    end
end

function apply!(ctrl::DataflowController, cmd::SelectSteps)
    require_state(ctrl, cmd, :ready)
    cfg = ctrl.session.config
    for (steps, specs, section) in ((cmd.run_steps, cfg.processors, "processors"), (cmd.partition_steps, cfg.p_processors, "p_processors"))
        unknown = filter(!in(keys(specs)), steps)
        isempty(unknown) ||
            throw(ArgumentError("not in `$section` of the config: $(join(unknown, ", "))"))
    end
    ctrl.session.run_steps = filter(in(cmd.run_steps), run_steps(cfg; enabled_only = false))
    ctrl.session.partition_steps = filter(in(cmd.partition_steps), partition_steps(cfg; enabled_only = false))
    reset_dependency_graph!(ctrl.session)
    return nothing
end

function apply!(ctrl::DataflowController, cmd::SetReprocess)
    require_state(ctrl, cmd, :idle, :ready)
    ctrl.reprocess = cmd.reprocess
    return nothing
end

function apply!(ctrl::DataflowController, cmd::SetAnalysisRunsOnly)
    require_state(ctrl, cmd, :idle, :ready)
    ctrl.analysis_runs_only = cmd.only
    return nothing
end

function apply!(ctrl::DataflowController, cmd::SetCheckDependencies)
    require_state(ctrl, cmd, :idle, :ready)
    ctrl.check_dependencies = cmd.check
    return nothing
end

function apply!(ctrl::DataflowController, cmd::SetKwarg)
    require_state(ctrl, cmd, :ready)
    spec = processor_spec(ctrl.session.config, cmd.step)
    overrides = merge(get(ctrl.kwarg_overrides, cmd.step, Dict{Symbol,Any}()), Dict{Symbol,Any}(cmd.key => cmd.value))
    candidate = ProcessorSpec(spec.name, spec.level, spec.enabled, spec.category, spec.rank,
        spec.dependencies, merge(spec.kwargs, overrides))
    problem = processor_kwargs_problem(candidate, ctrl.processors)
    isnothing(problem) || throw(ArgumentError(problem))
    ctrl.kwarg_overrides[cmd.step] = overrides
    return nothing
end

function apply!(ctrl::DataflowController, cmd::ResetKwargs)
    require_state(ctrl, cmd, :ready)
    if isnothing(cmd.step)
        empty!(ctrl.kwarg_overrides)
    elseif isnothing(cmd.key)
        delete!(ctrl.kwarg_overrides, cmd.step)
    elseif haskey(ctrl.kwarg_overrides, cmd.step)
        overrides = ctrl.kwarg_overrides[cmd.step]
        delete!(overrides, cmd.key)
        isempty(overrides) && delete!(ctrl.kwarg_overrides, cmd.step)
    end
    return nothing
end

function apply!(ctrl::DataflowController, cmd::ResetDependencyGraph)
    require_state(ctrl, cmd, :ready)
    reset_dependency_graph!(ctrl.session)
    return nothing
end

function apply!(ctrl::DataflowController, cmd::StartProcessing)
    require_state(ctrl, cmd, :ready)
    session = ctrl.session
    steps, p_steps = copy(session.run_steps), copy(session.partition_steps)
    isempty(steps) && isempty(p_steps) && throw(ArgumentError("no processing steps selected"))
    isempty(ctrl.periods) && throw(ArgumentError("no periods selected"))
    cfg = effective_config(ctrl)
    problems = filter(!isnothing, [processor_kwargs_problem(processor_spec(cfg, step), ctrl.processors) for step in vcat(steps, p_steps)])
    isempty(problems) || throw(ArgumentError("processor kwargs mismatch:\n  " * join(problems, "\n  ")))
    if ctrl.check_dependencies
        session.periods, session.run_status, session.partition_status = setup_dependency_graph(
            session.l200, cfg, ctrl.periods, session.runs, steps, p_steps)
    end
    ctrl.stop[], ctrl.abandon[] = false, false
    # no progress of the last run is shown until `run_processing` registers the new steps
    reset_progress!(ctrl.progress, ProgressKey[])
    ctrl.state, ctrl.outcome, ctrl.last_error = :running, nothing, nothing
    ctrl.started, ctrl.finished = now(UTC), nothing
    (; l200, periods, run_status, partition_status) = session
    check_dependencies, reprocess = ctrl.check_dependencies, ctrl.reprocess
    ctrl.task = Threads.@spawn begin
        outcome, err = try
            run_processing(cfg, l200, periods, steps, p_steps, run_status, partition_status;
                processors = ctrl.processors, check_dependencies, reprocess, ctrl.stop, ctrl.abandon, progress_store = ctrl.progress)
            :finished, nothing
        catch e
            ctrl.stop[] ? (:stopped, nothing) : (:failed, e)
        end
        isnothing(err) || @error "Processing failed" exception = err
        @info "Processing $outcome"
        @lock ctrl.lock begin
            ctrl.state, ctrl.outcome, ctrl.finished = :ready, outcome, now(UTC)
            ctrl.last_error = isnothing(err) ? nothing : truncate_error(err)
        end
    end
    return nothing
end

function apply!(ctrl::DataflowController, cmd::StopProcessing)
    require_state(ctrl, cmd, :running, :stopping)
    cmd.force && (ctrl.abandon[] = true)
    ctrl.stop[] = true
    ctrl.state = :stopping
    cmd.force && @warn "Stopping without waiting for the running items; their workers stay busy until the items end"
    return nothing
end

function apply!(ctrl::DataflowController, cmd::WriteConfig)
    require_state(ctrl, cmd, :ready, :running, :stopping)
    session = ctrl.session
    props = readlprops(ctrl.args["config"])
    for (step, overrides) in ctrl.kwarg_overrides
        spec = processor_spec(session.config, step)
        entry = props[spec.level === :run ? :processors : :p_processors][step]
        for (key, value) in overrides
            # the config stores symbol lists as strings
            entry.kwargs[key] = value isa AbstractVector{Symbol} ? string.(value) : value
        end
    end
    selected = union(session.run_steps, session.partition_steps)
    for section in (:processors, :p_processors), (name, entry) in props[section]
        entry.enabled = name in selected
    end
    props.processing.analysis_runs_only = effective_config(ctrl).analysis_runs_only
    isfile(cmd.path) && cp(cmd.path, cmd.path * ".bak"; force = true)
    writelprops(cmd.path, props)
    @info "Wrote processing config to $(cmd.path)"
    return nothing
end

function apply!(ctrl::DataflowController, cmd::SubmitWorkers)
    require_state(ctrl, cmd, :ready, :running, :stopping)
    errormonitor(Threads.@spawn runworkers(runprocs_mode(ctrl.session.config)))
    @info "Submitted workers"
    return nothing
end

"""
    wait(ctrl::DataflowController)

Block until the background task of the last loading or processing command has ended.
"""
function Base.wait(ctrl::DataflowController)
    task = @lock ctrl.lock ctrl.task
    isnothing(task) || wait(task)
    return nothing
end

"""
    snapshot(ctrl::DataflowController)

Return a `NamedTuple` with a copy of the controller state:

- `state`, `outcome` (`:finished`, `:failed`, `:stopped` or `nothing` of the last
  processing run), `last_error` (message or `nothing`), `started`, `finished` (UTC
  times of the last processing run or `nothing`);
- `config_file`, `log_path`;
- `available_periods`, `available_runs` (`Dict` period => runs on disk), `periods`
  (selected periods), `runs` (selected runs: `nothing` for all runs, a vector for the
  same runs in every period, or a dict of runs per period where a period without an
  entry keeps all its runs), `run_steps`, `partition_steps` (selected steps in
  processing order);
- `processors`: one `NamedTuple` per configured processor, run level first and then by
  rank, with `name`, `level`, `category`, `rank`, `enabled`, `selected`,
  `dependencies`, `kwargs` (with the overrides applied), `config_kwargs` (as in the
  config), `accepted` (the keyword arguments the processor function accepts besides the
  ones the dataflow passes itself, `nothing` if it accepts any) and `overridden` (names of
  the overridden kwargs);
- `reprocess`, `analysis_runs_only` (the setting in effect), `check_dependencies`,
  `nworkers` (workers in the pool).
"""
function snapshot(ctrl::DataflowController)
    @lock ctrl.lock begin
        session = ctrl.session
        processors = if isnothing(session)
            NamedTuple[]
        else
            cfg = effective_config(ctrl)
            selected = union(session.run_steps, session.partition_steps)
            [(; name, spec.level, spec.category, spec.rank, spec.enabled, selected = name in selected,
                    dependencies = copy(spec.dependencies), kwargs = copy(spec.kwargs),
                    config_kwargs = copy(processor_spec(session.config, name).kwargs),
                    accepted = accepted_kwargs(ctrl.processors, spec),
                    overridden = sort!(collect(keys(get(ctrl.kwarg_overrides, name, Dict{Symbol,Any}())))))
                for name in vcat(run_steps(cfg; enabled_only = false), partition_steps(cfg; enabled_only = false))
                for spec in (processor_spec(cfg, name),)]
        end
        return (;
            ctrl.state, ctrl.outcome, ctrl.last_error, ctrl.started, ctrl.finished,
            config_file = get(ctrl.args, "config", nothing),
            log_path = isnothing(session) ? nothing : session.config.log_path,
            available_periods = copy(ctrl.available_periods),
            available_runs = Dict(p => copy(r) for (p, r) in ctrl.available_runs),
            periods = copy(ctrl.periods),
            runs = isnothing(session) ? nothing : deepcopy(session.runs),
            run_steps = isnothing(session) ? Symbol[] : copy(session.run_steps),
            partition_steps = isnothing(session) ? Symbol[] : copy(session.partition_steps),
            processors, ctrl.reprocess,
            analysis_runs_only = isnothing(session) ? ctrl.analysis_runs_only : something(ctrl.analysis_runs_only, session.config.analysis_runs_only),
            ctrl.check_dependencies,
            nworkers = nprocs() > 1 ? nworkers() : 0,
        )
    end
end

progress(ctrl::DataflowController) = progress(ctrl.progress)
busy_workers(ctrl::DataflowController) = busy_workers(ctrl.progress)
step_messages(ctrl::DataflowController, key) = step_messages(ctrl.progress, key)
