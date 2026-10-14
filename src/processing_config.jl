# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

"""
    struct ProcessorSpec

Settings of one processor from the `processors` (run level) or `p_processors`
(partition level) table of a processing config.

Fields:
- `name::Symbol`: name of the processor function.
- `level::Symbol`: `:run` for an entry of `processors`, `:partition` for an entry of
  `p_processors`.
- `enabled::Bool`: whether the processor is selected for execution by default.
- `category::Symbol`: data category the processor acts on, `:cal` or `:phy`.
- `rank::Int`: position in the processing order; lower ranks run first.
- `dependencies::Vector{Symbol}`: processors of the other level that must finish first.
- `kwargs::Dict{Symbol,Any}`: keyword arguments passed to the processor function.

The positional constructor takes the fields in the order listed above,
`ProcessorSpec(name, level, enabled, category, rank, dependencies, kwargs)`;
`ProcessorSpec(; name, level, category, rank, enabled=true, dependencies=Symbol[],
kwargs=Dict{Symbol,Any}())` builds a spec from keywords. Every constructor throws an `ArgumentError` when `level` is not `:run` or
`:partition`, `category` is not `:cal` or `:phy`, or the processor depends on itself.
"""
struct ProcessorSpec
    name::Symbol
    level::Symbol
    enabled::Bool
    category::Symbol
    rank::Int
    dependencies::Vector{Symbol}
    kwargs::Dict{Symbol,Any}

    function ProcessorSpec(name, level, enabled, category, rank, dependencies, kwargs)
        spec = new(name, level, enabled, category, rank, dependencies, kwargs)
        spec.level in (:run, :partition) ||
            throw(ArgumentError("processing_config: processor `$(spec.name)` has level $(repr(spec.level)), expected :run or :partition"))
        path = "$(spec.level === :run ? "processors" : "p_processors").$(spec.name)."
        spec.category in (:cal, :phy) ||
            throw(ArgumentError("processing_config: key `$(path)category` must be \"cal\" or \"phy\", got $(repr(spec.category))"))
        spec.name in spec.dependencies &&
            throw(ArgumentError("processing_config: key `$(path)dependencies` names the processor itself"))
        return spec
    end
end

ProcessorSpec(; name, level, category, rank, enabled = true, dependencies = Symbol[], kwargs = Dict{Symbol,Any}()) =
    ProcessorSpec(name, level, enabled, category, rank, dependencies, kwargs)

"""
    struct ProcessingConfig

Validated processing settings, built from a processing config file and the command
line options of the dataflow driver.

Fields:
- `runmode::Symbol`: `:local` or `:slurm`.
- `submit_jobs::Bool`: whether the driver starts the workers itself.
- `local_n::Int`: number of local workers (`config.runmode_settings.local.n`).
- `local_julia_settings::Vector{String}`: Julia flags for local workers.
- `slurm_flags::Vector{String}`: SLURM flags for SLURM workers.
- `slurm_julia_settings::Vector{String}`: Julia flags for SLURM workers.
- `env_variables::Dict{String,String}`: environment variables for the driver and workers.
- `periods::Union{Nothing,Vector{DataPeriod}}`: selected periods; `nothing` selects all.
- `runs::Union{Nothing,Vector{DataRun}}`: selected runs; `nothing` selects all.
- `analysis_runs_only::Bool`: process only runs marked as analysis runs.
- `only_partitions::Bool`: process only partition-level processors.
- `only_runs::Bool`: process only run-level processors.
- `log_path::String`: directory for log files; `""` when not resolved.
- `log_level::LogLevel`: level of the records written to the log files.
- `processors::Dict{Symbol,ProcessorSpec}`: run-level processors.
- `p_processors::Dict{Symbol,ProcessorSpec}`: partition-level processors.

Besides the positional constructor and the config-file constructors documented below,
`ProcessingConfig(; processors, p_processors, runmode=:local, ...)` builds a config from
keywords named like the fields. Every field except the two processor tables has a
default: empty flag and settings lists, no environment variables, `periods` and `runs`
of `nothing`, all `Bool` fields `false`, `local_n = 1`, `log_path = ""` and
`log_level = Logging.Info`. Every
constructor throws an `ArgumentError` when `runmode` is not `:local` or `:slurm`,
`local_n < 1`, both `only_runs` and `only_partitions` are set, a table key differs from
its spec's name or level, a name appears in both tables, a dependency names an unknown
processor or one of its own level, or no processor is enabled.

See [`run_steps`](@ref), [`partition_steps`](@ref) and [`check_processor_kwargs`](@ref).
"""
struct ProcessingConfig
    runmode::Symbol
    submit_jobs::Bool
    local_n::Int
    local_julia_settings::Vector{String}
    slurm_flags::Vector{String}
    slurm_julia_settings::Vector{String}
    env_variables::Dict{String,String}
    periods::Union{Nothing,Vector{DataPeriod}}
    runs::Union{Nothing,Vector{DataRun}}
    analysis_runs_only::Bool
    only_partitions::Bool
    only_runs::Bool
    log_path::String
    log_level::LogLevel
    processors::Dict{Symbol,ProcessorSpec}
    p_processors::Dict{Symbol,ProcessorSpec}

    function ProcessingConfig(runmode, submit_jobs, local_n, local_julia_settings, slurm_flags,
            slurm_julia_settings, env_variables, periods, runs, analysis_runs_only,
            only_partitions, only_runs, log_path, log_level, processors, p_processors)
        cfg = new(runmode, submit_jobs, local_n, local_julia_settings, slurm_flags,
            slurm_julia_settings, env_variables, periods, runs, analysis_runs_only,
            only_partitions, only_runs, log_path, log_level, processors, p_processors)
        cfg.runmode in (:local, :slurm) ||
            throw(ArgumentError("processing_config: runmode must be \"local\" or \"slurm\", got $(repr(cfg.runmode))"))
        cfg.local_n > 0 ||
            throw(ArgumentError("processing_config: key `config.runmode_settings.local.n` must be positive, got $(cfg.local_n)"))
        cfg.only_runs && cfg.only_partitions &&
            throw(ArgumentError("processing_config: only one of `only_partitions` or `only_runs` can be set"))
        for (section, level, specs) in (("processors", :run, cfg.processors), ("p_processors", :partition, cfg.p_processors)),
                (name, spec) in specs
            name === spec.name ||
                throw(ArgumentError("processing_config: `$section` entry `$name` holds the spec of `$(spec.name)`"))
            spec.level === level ||
                throw(ArgumentError("processing_config: `$section.$name` has level $(repr(spec.level)), expected $(repr(level))"))
        end
        duplicates = intersect(keys(cfg.processors), keys(cfg.p_processors))
        isempty(duplicates) ||
            throw(ArgumentError("processing_config: processor names in both `processors` and `p_processors`: $(join(duplicates, ", "))"))
        for (section, specs, others) in (("processors", cfg.processors, cfg.p_processors), ("p_processors", cfg.p_processors, cfg.processors)),
                spec in values(specs), dep in spec.dependencies
            haskey(others, dep) && continue
            haskey(specs, dep) &&
                throw(ArgumentError("processing_config: key `$section.$(spec.name).dependencies` names `$dep` of the same level; dependencies must name processors of the other level"))
            throw(ArgumentError("processing_config: key `$section.$(spec.name).dependencies` names unknown processor `$dep`"))
        end
        any(s -> s.enabled, values(cfg.processors)) || any(s -> s.enabled, values(cfg.p_processors)) ||
            throw(ArgumentError("processing_config: no processor is enabled"))
        return cfg
    end
end

ProcessingConfig(;
        processors, p_processors, runmode = :local, submit_jobs = false, local_n = 1,
        local_julia_settings = String[], slurm_flags = String[], slurm_julia_settings = String[],
        env_variables = Dict{String,String}(), periods = nothing, runs = nothing,
        analysis_runs_only = false, only_partitions = false, only_runs = false, log_path = "",
        log_level = Logging.Info
    ) = ProcessingConfig(runmode, submit_jobs, local_n, local_julia_settings, slurm_flags,
        slurm_julia_settings, env_variables, periods, runs, analysis_runs_only,
        only_partitions, only_runs, log_path, log_level, processors, p_processors)

# Recursively convert nested dictionaries to `Dict{Symbol,Any}`.
_symbolkeys(x) = x
_symbolkeys(d::AbstractDict) = Dict{Symbol,Any}(Symbol(k) => _symbolkeys(v) for (k, v) in d)

# Throw unless `d` has exactly the keys `required`; `path` is the key path of `d`.
function _check_keys(d::AbstractDict, required, path::AbstractString)
    for k in required
        haskey(d, k) || throw(ArgumentError("processing_config: missing key `$path$k`"))
    end
    for k in keys(d)
        k in required || throw(ArgumentError("processing_config: unknown key `$path$k`"))
    end
end

# Return `d[k]` after checking that it is a `T`.
function _typed(d::AbstractDict, k::Symbol, ::Type{T}, path::AbstractString) where {T}
    v = d[k]
    v isa T || throw(ArgumentError("processing_config: key `$path$k` must be a $T, got $(repr(v))"))
    return v
end

function _strings(d::AbstractDict, k::Symbol, path::AbstractString)
    v = _typed(d, k, AbstractVector, path)
    all(x -> x isa AbstractString, v) ||
        throw(ArgumentError("processing_config: key `$path$k` must be a list of strings, got $(repr(v))"))
    return String[x for x in v]
end

# `"all"` selects everything (`nothing`), a list selects the given periods or runs.
function _selection(::Type{T}, d::AbstractDict, k::Symbol) where {T}
    v = d[k]
    v == "all" && return nothing
    v isa AbstractVector ||
        throw(ArgumentError("processing_config: key `processing.$k` must be \"all\" or a list, got $(repr(v))"))
    return T[T(x) for x in v]
end

function _processor_specs(table::AbstractDict, level::Symbol, section::Symbol, reprocess::Bool)
    specs = Dict{Symbol,ProcessorSpec}()
    for (name, entry) in table
        path = "$section.$name."
        entry isa AbstractDict ||
            throw(ArgumentError("processing_config: key `$section.$name` must be a table, got $(repr(entry))"))
        _check_keys(entry, (:enabled, :category, :rank, :kwargs, :dependencies), path)
        category = _typed(entry, :category, AbstractString, path)
        kwargs = Dict{Symbol,Any}()
        for (k, v) in _typed(entry, :kwargs, AbstractDict, path)
            # String lists become Symbol lists, an untyped empty list becomes `Symbol[]`.
            kwargs[k] = v isa AbstractVector && all(x -> x isa AbstractString, v) ? Symbol[Symbol(x) for x in v] : v
        end
        reprocess && (kwargs[:reprocess] = true)
        specs[name] = ProcessorSpec(
            name, level, _typed(entry, :enabled, Bool, path), Symbol(category),
            _typed(entry, :rank, Int, path), Symbol.(_strings(entry, :dependencies, path)), kwargs
        )
    end
    return specs
end

"""
    ProcessingConfig(dict::AbstractDict; runmode=nothing, submit_jobs=nothing,
        periods=nothing, runs=nothing, analysis_runs_only=nothing,
        only_partitions=nothing, only_runs=nothing, ignore_config=false,
        reprocess=false, log_path="")
    ProcessingConfig(filename::AbstractString; kwargs...)

Validate a parsed processing config `dict` (keys may be `Symbol`s or strings), combine
it with command line overrides and return the resulting [`ProcessingConfig`](@ref). The
second form reads `filename` (JSON or YAML) with `readlprops`.

The config must contain exactly these keys; a missing or unknown key throws an
`ArgumentError` that names the key path:

- `config`: `runmode` (`"local"` or `"slurm"`), `submit_jobs::Bool`,
  `runmode_settings.local.{n, julia_settings}`,
  `runmode_settings.slurm.{flags, julia_settings}`, `env_variables`, `log_level`
  (`"debug"`, `"info"`, `"warn"` or `"error"`)
- `processing`: `periods` and `runs` (each `"all"` or a list), `analysis_runs_only`,
  `only_partitions`, `only_runs` (all `Bool`)
- `processors`, `p_processors`: tables of processor name to
  `{enabled::Bool, category ("cal" or "phy"), rank::Int, kwargs, dependencies}`

Processor names must be unique across both tables, every dependency must name a
configured processor, and at least one processor must be enabled. String lists in
`kwargs` become `Vector{Symbol}`.

Overrides:
- `analysis_runs_only`, `only_partitions`, `only_runs`, `submit_jobs`: with
  `ignore_config = true` the given value is used (`nothing` means `false`); otherwise
  `true` overrides the config and `nothing` or `false` keeps the config value.
  `only_runs` and `only_partitions` cannot both be `true`.
- `runmode`: replaces `config.runmode` when not `nothing`.
- `periods`, `runs`: lists of period and run numbers that replace the config
  selection. `periods` without `runs` selects all runs of those periods; `runs`
  without `periods` is an error.
- `reprocess = true` sets the `reprocess` keyword of every processor to `true`.
- `log_path` is stored as given.

# Examples
```jldoctest
julia> config = Dict(
           "config" => Dict("runmode" => "local", "submit_jobs" => false,
               "runmode_settings" => Dict(
                   "local" => Dict("n" => 4, "julia_settings" => []),
                   "slurm" => Dict("flags" => [], "julia_settings" => [])),
               "env_variables" => Dict(), "log_level" => "info"),
           "processing" => Dict("periods" => [3], "runs" => "all", "analysis_runs_only" => false,
               "only_partitions" => false, "only_runs" => false),
           "processors" => Dict("process_energy_calibration" => Dict("enabled" => true,
               "category" => "cal", "rank" => 1, "kwargs" => Dict(), "dependencies" => [])),
           "p_processors" => Dict());

julia> cfg = ProcessingConfig(config; periods = [3, 4])
ProcessingConfig(runmode=:local, 1/1 run and 0/0 partition processors enabled)

julia> string.(cfg.periods)
2-element Vector{String}:
 "p03"
 "p04"
```
"""
function ProcessingConfig(
        dict::AbstractDict;
        runmode::Union{Nothing,AbstractString,Symbol} = nothing,
        submit_jobs::Union{Nothing,Bool} = nothing,
        periods = nothing,
        runs = nothing,
        analysis_runs_only::Union{Nothing,Bool} = nothing,
        only_partitions::Union{Nothing,Bool} = nothing,
        only_runs::Union{Nothing,Bool} = nothing,
        ignore_config::Bool = false,
        reprocess::Bool = false,
        log_path::AbstractString = ""
    )
    d = _symbolkeys(dict)
    _check_keys(d, (:config, :processing, :processors, :p_processors), "")
    config = _typed(d, :config, AbstractDict, "")
    _check_keys(config, (:runmode, :submit_jobs, :runmode_settings, :env_variables, :log_level), "config.")
    settings = _typed(config, :runmode_settings, AbstractDict, "config.")
    _check_keys(settings, (:local, :slurm), "config.runmode_settings.")
    local_settings = _typed(settings, :local, AbstractDict, "config.runmode_settings.")
    _check_keys(local_settings, (:n, :julia_settings), "config.runmode_settings.local.")
    slurm_settings = _typed(settings, :slurm, AbstractDict, "config.runmode_settings.")
    _check_keys(slurm_settings, (:flags, :julia_settings), "config.runmode_settings.slurm.")
    processing = _typed(d, :processing, AbstractDict, "")
    _check_keys(processing, (:periods, :runs, :analysis_runs_only, :only_partitions, :only_runs), "processing.")

    function flag(cli, section, key, path)
        value = _typed(section, key, Bool, path)
        return ignore_config ? something(cli, false) : (cli === true || value)
    end
    sel_submit_jobs = flag(submit_jobs, config, :submit_jobs, "config.")
    sel_analysis_runs_only = flag(analysis_runs_only, processing, :analysis_runs_only, "processing.")
    sel_only_partitions = flag(only_partitions, processing, :only_partitions, "processing.")
    sel_only_runs = flag(only_runs, processing, :only_runs, "processing.")
    sel_runmode = Symbol(something(runmode, _typed(config, :runmode, AbstractString, "config.")))
    n = _typed(local_settings, :n, Int, "config.runmode_settings.local.")

    env_variables = Dict{String,String}()
    for (k, v) in _typed(config, :env_variables, AbstractDict, "config.")
        v isa Union{AbstractString,Real} ||
            throw(ArgumentError("processing_config: key `config.env_variables.$k` must be a string or number, got $(repr(v))"))
        env_variables[string(k)] = string(v)
    end

    sel_periods, sel_runs = if !isnothing(periods)
        DataPeriod[DataPeriod(p) for p in periods], isnothing(runs) ? nothing : DataRun[DataRun(r) for r in runs]
    elseif !isnothing(runs)
        throw(ArgumentError("processing_config: runs without periods are not supported"))
    else
        _selection(DataPeriod, processing, :periods), _selection(DataRun, processing, :runs)
    end

    processors = _processor_specs(_typed(d, :processors, AbstractDict, ""), :run, :processors, reprocess)
    p_processors = _processor_specs(_typed(d, :p_processors, AbstractDict, ""), :partition, :p_processors, reprocess)

    return ProcessingConfig(
        sel_runmode, sel_submit_jobs, n,
        _strings(local_settings, :julia_settings, "config.runmode_settings.local."),
        _strings(slurm_settings, :flags, "config.runmode_settings.slurm."),
        _strings(slurm_settings, :julia_settings, "config.runmode_settings.slurm."),
        env_variables, sel_periods, sel_runs,
        sel_analysis_runs_only, sel_only_partitions, sel_only_runs, log_path,
        parse_log_level(_typed(config, :log_level, AbstractString, "config.")),
        processors, p_processors
    )
end

ProcessingConfig(filename::AbstractString; kwargs...) = ProcessingConfig(readlprops(filename); kwargs...)

_sorted_steps(specs::AbstractDict, enabled_only::Bool) =
    sort!([s.name for s in values(specs) if s.enabled || !enabled_only]; by = n -> (specs[n].rank, n))

"""
    run_steps(cfg::ProcessingConfig; enabled_only::Bool=true)

Return the names of the run-level processors of `cfg` as a `Vector{Symbol}`, sorted by
rank (ties by name). With `enabled_only = false` the disabled processors are included.
"""
run_steps(cfg::ProcessingConfig; enabled_only::Bool = true) = _sorted_steps(cfg.processors, enabled_only)

"""
    partition_steps(cfg::ProcessingConfig; enabled_only::Bool=true)

Return the names of the partition-level processors of `cfg` as a `Vector{Symbol}`,
sorted by rank (ties by name). With `enabled_only = false` the disabled processors are
included.
"""
partition_steps(cfg::ProcessingConfig; enabled_only::Bool = true) = _sorted_steps(cfg.p_processors, enabled_only)

"""
    check_processor_kwargs(cfg::ProcessingConfig; processors::AbstractDict{Symbol} = PROCESSORS)

Check that every enabled processor of `cfg` is registered in `processors` and that its
function accepts all keyword arguments configured in its `kwargs`, plus the keywords
[`run_processing`](@ref) may pass on its own: `reprocess` for every processor and
`only_first_period` for partition processors. Throw an `ArgumentError` listing every
mismatch; return `nothing` otherwise.
"""
function check_processor_kwargs(cfg::ProcessingConfig; processors::AbstractDict{Symbol} = PROCESSORS)
    problems = String[]
    for specs in (cfg.processors, cfg.p_processors), spec in values(specs)
        spec.enabled || continue
        if !haskey(processors, spec.name)
            push!(problems, "`$(spec.name)` is not a registered processor")
            continue
        end
        declared = reduce(vcat, (Base.kwarg_decl(m) for m in methods(processors[spec.name])); init = Symbol[])
        # A method with `kwargs...` accepts every keyword.
        any(k -> endswith(string(k), "..."), declared) && continue
        implicit = spec.level === :partition ? (:reprocess, :only_first_period) : (:reprocess,)
        unsupported = sort!(collect(setdiff(union(keys(spec.kwargs), implicit), declared)))
        isempty(unsupported) ||
            push!(problems, "`$(spec.name)` does not accept keyword(s) $(join(unsupported, ", "))")
    end
    isempty(problems) ||
        throw(ArgumentError("processing_config: processor kwargs mismatch:\n  " * join(problems, "\n  ")))
    return nothing
end

function Base.show(io::IO, spec::ProcessorSpec)
    print(io, "ProcessorSpec(", repr(spec.name), ", level=", repr(spec.level), ", category=",
        repr(spec.category), ", rank=", spec.rank, ", enabled=", spec.enabled, ")")
end

function Base.show(io::IO, cfg::ProcessingConfig)
    print(io, "ProcessingConfig(runmode=", repr(cfg.runmode), ", ",
        length(run_steps(cfg)), "/", length(cfg.processors), " run and ",
        length(partition_steps(cfg)), "/", length(cfg.p_processors), " partition processors enabled)")
end
