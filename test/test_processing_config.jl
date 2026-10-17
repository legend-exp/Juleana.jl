# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Juleana
using Test
using LegendDataManagement: DataPeriod, DataRun, readlprops

const CONFIG_DIR = joinpath(dirname(@__DIR__), "config")

# Nested `Dict{String,Any}`, as produced by a plain JSON parser.
stringdict(x) = x
stringdict(d::AbstractDict) = Dict{String,Any}(string(k) => stringdict(v) for (k, v) in d)

process_a(cfg, l200, period, run; reprocess::Bool = false, timeout::Int = 0) = nothing
# A callable struct stands in for a processor, as a test double might.
struct PartitionStub end
(::PartitionStub)(cfg, l200, period; kwargs...) = true
const STUB_PROCESSORS = Dict{Symbol,Any}(:process_a => process_a, :p_process_b => PartitionStub())

@testset "processing config" begin
    shipped = ProcessingConfig(joinpath(CONFIG_DIR, "processing_config.yaml"))
    base = stringdict(readlprops(joinpath(CONFIG_DIR, "processing_config.yaml")))

    @testset "repository configs" begin
        @test shipped.runmode === :slurm
        @test !shipped.submit_jobs
        @test shipped.local_n == 64
        @test shipped.local_julia_settings == String[]
        @test "--nodes=1" in shipped.slurm_flags && "--time=01:00:00" in shipped.slurm_flags
        @test shipped.env_variables["JULIA_WORKER_TIMEOUT"] == "240"
        @test shipped.log_level == Juleana.parse_log_level("info")
        @test shipped.periods == DataPeriod.([16, 18, 19, 20, 21, 22])
        @test isnothing(shipped.runs)
        @test !shipped.analysis_runs_only && !shipped.only_partitions && !shipped.only_runs
        @test shipped.log_path == ""
        spec = shipped.processors[:process_dsp_cal]
        @test spec.level === :run && spec.category === :cal && spec.rank == 5 && !spec.enabled
        @test spec.dependencies == [:p_process_aoe_optimization_cal, :p_process_filter_optimization_cal, :p_process_decay_time_cal]
        @test spec.kwargs == Dict{Symbol,Any}(:reprocess => false, :max_wvfs => 1000, :timeout => 0, :use_partition_pars => true)
        @test shipped.p_processors[:p_process_energy_cal].level === :partition
        @test shipped.p_processors[:p_process_energy_cal].category === :cal
        @test shipped.p_processors[:p_process_skm_phy].category === :phy

        from_strings = ProcessingConfig(base)
        @test run_steps(from_strings; enabled_only = false) == run_steps(shipped; enabled_only = false)
        @test from_strings.processors[:process_dsp_cal].kwargs == spec.kwargs
        @test sprint(show, shipped) == "ProcessingConfig(runmode=:slurm, 0/18 run and 0/12 partition processors enabled)"
        @test occursin("rank=5", sprint(show, spec))
    end

    @testset "steps" begin
        # the shipped config enables no processor; the steps are chosen in the interface
        @test isempty(run_steps(shipped)) && isempty(partition_steps(shipped))
        d = deepcopy(base)
        foreach(((section, name),) -> d[section][name]["enabled"] = true,
            [("processors", "process_evt_phy"), ("processors", "process_psd_efficiencies_cal"), ("p_processors", "p_process_skm_phy")])
        some = ProcessingConfig(d)
        @test run_steps(some) == [:process_psd_efficiencies_cal, :process_evt_phy]
        @test partition_steps(some) == [:p_process_skm_phy]
        all_steps = run_steps(shipped; enabled_only = false)
        @test length(all_steps) == 18 && first(all_steps) === :process_peak_split_cal
        @test issorted(all_steps; by = s -> shipped.processors[s].rank)
        @test length(partition_steps(shipped; enabled_only = false)) == 12
    end

    @testset "overrides" begin
        # a config with analysis_runs_only = true and only_runs = false
        analysis = deepcopy(base)
        analysis["processing"]["analysis_runs_only"] = true
        @test ProcessingConfig(analysis; analysis_runs_only = false).analysis_runs_only
        @test !ProcessingConfig(analysis; analysis_runs_only = false, ignore_config = true).analysis_runs_only
        @test !ProcessingConfig(base; ignore_config = true).analysis_runs_only
        @test ProcessingConfig(base; only_runs = true).only_runs
        @test !ProcessingConfig(base; only_runs = nothing).only_runs
        @test ProcessingConfig(base; submit_jobs = true, ignore_config = true).submit_jobs
        @test ProcessingConfig(base; runmode = "slurm").runmode === :slurm
        cfg = ProcessingConfig(base; periods = [5], runs = [1, 2], log_path = "logs")
        @test cfg.periods == [DataPeriod(5)] && cfg.runs == DataRun.([1, 2]) && cfg.log_path == "logs"
        @test isnothing(ProcessingConfig(base; periods = [5]).runs)

        @test !shipped.processors[:process_dsp_cal].kwargs[:reprocess]
        reprocessed = ProcessingConfig(base; reprocess = true)
        @test all(s -> s.kwargs[:reprocess], values(reprocessed.processors))
        @test all(s -> s.kwargs[:reprocess], values(reprocessed.p_processors))
    end

    @testset "kwargs conversion" begin
        d = deepcopy(base)
        d["processors"]["process_evt_phy"]["kwargs"]["subsystems"] = Any["geds", "spms"]
        d["processors"]["process_evt_phy"]["kwargs"]["empty"] = Any[]
        kwargs = ProcessingConfig(d).processors[:process_evt_phy].kwargs
        @test kwargs[:subsystems] == [:geds, :spms] && kwargs[:subsystems] isa Vector{Symbol}
        @test kwargs[:empty] isa Vector{Symbol} && isempty(kwargs[:empty])
    end

    @testset "validation" begin
        edited(f) = (d = deepcopy(base); f(d); d)

        @test_throws "missing key `processors.process_dsp_cal.rank`" ProcessingConfig(edited(d -> delete!(d["processors"]["process_dsp_cal"], "rank")))
        @test_throws "missing key `config.runmode_settings.local.n`" ProcessingConfig(edited(d -> delete!(d["config"]["runmode_settings"]["local"], "n")))
        @test_throws "missing key `config.log_level`" ProcessingConfig(edited(d -> delete!(d["config"], "log_level")))
        @test_throws "`config.log_level` must be one of" ProcessingConfig(edited(d -> d["config"]["log_level"] = "verbose"))
        @test_throws "missing key `processing.only_runs`" ProcessingConfig(edited(d -> delete!(d["processing"], "only_runs")))
        @test_throws "unknown key `processors.process_dsp_cal.n_workers`" ProcessingConfig(edited(d -> d["processors"]["process_dsp_cal"]["n_workers"] = "all"))
        @test_throws "unknown key `config.remote_workers`" ProcessingConfig(edited(d -> d["config"]["remote_workers"] = []))
        @test_throws "unknown key `extra`" ProcessingConfig(edited(d -> d["extra"] = 1))
        # the idle timeout is optional
        @test shipped.idle_timeout_minutes == 20
        @test ProcessingConfig(edited(d -> delete!(d["config"], "idle_timeout_minutes"))).idle_timeout_minutes == 20
        @test ProcessingConfig(edited(d -> d["config"]["idle_timeout_minutes"] = 0)).idle_timeout_minutes == 0
        @test ProcessingConfig(edited(d -> d["config"]["idle_timeout_minutes"] = 2.5)).idle_timeout_minutes == 2.5
        @test_throws "`config.idle_timeout_minutes` must be zero or positive, got -1.0" ProcessingConfig(edited(d -> d["config"]["idle_timeout_minutes"] = -1))
        @test_throws "`config.idle_timeout_minutes` must be a Real" ProcessingConfig(edited(d -> d["config"]["idle_timeout_minutes"] = "20"))
        @test_throws "`p_processors.p_process_energy_cal.category` must be \"cal\" or \"phy\"" ProcessingConfig(edited(d -> d["p_processors"]["p_process_energy_cal"]["category"] = "physics"))
        @test_throws "`processors.process_dsp_cal.enabled` must be a Bool" ProcessingConfig(edited(d -> d["processors"]["process_dsp_cal"]["enabled"] = "yes"))
        @test_throws "`processors.process_dsp_cal.rank` must be a $Int" ProcessingConfig(edited(d -> d["processors"]["process_dsp_cal"]["rank"] = 5.5))
        @test_throws "`config.runmode_settings.local.n` must be positive" ProcessingConfig(edited(d -> d["config"]["runmode_settings"]["local"]["n"] = 0))
        @test_throws "names unknown processor `p_process_missing`" ProcessingConfig(edited(d -> push!(d["processors"]["process_dsp_cal"]["dependencies"], "p_process_missing")))
        @test_throws "in both `processors` and `p_processors`: process_dsp_cal" ProcessingConfig(edited(d -> d["p_processors"]["process_dsp_cal"] = deepcopy(d["processors"]["process_dsp_cal"])))
        @test_throws "only one of `only_partitions` or `only_runs`" ProcessingConfig(base; only_runs = true, only_partitions = true)
        @test_throws "only one of `only_partitions` or `only_runs`" ProcessingConfig(edited(d -> (d["processing"]["only_runs"] = true; d["processing"]["only_partitions"] = true)))
        @test_throws "runmode must be \"local\" or \"slurm\"" ProcessingConfig(base; runmode = "cluster")
        @test_throws "runmode must be \"local\" or \"slurm\"" ProcessingConfig(edited(d -> d["config"]["runmode"] = "cluster"))
        @test_throws "runs without periods" ProcessingConfig(base; runs = [1])
        # a config may enable no processor; the steps are then selected in the interface
        none = ProcessingConfig(edited(d -> foreach(p -> p["enabled"] = false, (values(d["processors"])..., values(d["p_processors"])...))))
        @test isempty(run_steps(none)) && isempty(partition_steps(none))
    end

    @testset "constructors" begin
        samefields(a, b) = all(f -> getfield(a, f) == getfield(b, f), fieldnames(typeof(a)))

        spec = shipped.processors[:process_dsp_cal]
        spec_fields = NamedTuple{fieldnames(ProcessorSpec)}(getfield.(Ref(spec), fieldnames(ProcessorSpec)))
        @test samefields(ProcessorSpec(spec_fields...), spec)
        @test samefields(ProcessorSpec(; spec_fields...), spec)
        minimal = ProcessorSpec(; name = :x, level = :run, category = :cal, rank = 1)
        @test minimal.enabled && isempty(minimal.dependencies) && isempty(minimal.kwargs)
        @test_throws "processor `x` has level :other" ProcessorSpec(; name = :x, level = :other, category = :cal, rank = 1)
        @test_throws "key `p_processors.x.category` must be \"cal\" or \"phy\"" ProcessorSpec(; name = :x, level = :partition, category = :physics, rank = 1)
        @test_throws "key `processors.x.dependencies` names the processor itself" ProcessorSpec(; name = :x, level = :run, category = :cal, rank = 1, dependencies = [:x])

        fields = NamedTuple{fieldnames(ProcessingConfig)}(getfield.(Ref(shipped), fieldnames(ProcessingConfig)))
        @test samefields(ProcessingConfig(fields...), shipped)
        @test samefields(ProcessingConfig(; fields...), shipped)
        positional(; kw...) = ProcessingConfig(values(merge(fields, kw))...)
        @test_throws "runmode must be \"local\" or \"slurm\", got :cluster" positional(runmode = :cluster)
        @test_throws "`config.runmode_settings.local.n` must be positive" positional(local_n = 0)
        @test_throws "only one of `only_partitions` or `only_runs`" positional(only_runs = true, only_partitions = true)
        @test_throws "`processors` entry `renamed` holds the spec of `process_dsp_cal`" positional(processors = Dict(:renamed => spec))
        @test_throws "`p_processors.process_dsp_cal` has level :run" positional(p_processors = Dict(:process_dsp_cal => spec))
        partition_twin = ProcessorSpec(; name = :process_dsp_cal, level = :partition, category = :cal, rank = 1)
        @test_throws "in both `processors` and `p_processors`: process_dsp_cal" positional(p_processors = merge(shipped.p_processors, Dict(:process_dsp_cal => partition_twin)))
        orphan = ProcessorSpec(; name = :x, level = :run, category = :cal, rank = 1, dependencies = [:missing])
        @test_throws "key `processors.x.dependencies` names unknown processor `missing`" ProcessingConfig(; processors = Dict(:x => orphan), p_processors = Dict{Symbol,ProcessorSpec}())
        first_run = ProcessorSpec(; name = :a, level = :run, category = :cal, rank = 1)
        second_run = ProcessorSpec(; name = :b, level = :run, category = :cal, rank = 2, dependencies = [:a])
        @test_throws "key `processors.b.dependencies` names `a` of the same level; dependencies must name processors of the other level" ProcessingConfig(; processors = Dict(:a => first_run, :b => second_run), p_processors = Dict{Symbol,ProcessorSpec}())
        idle = ProcessorSpec(; name = :x, level = :run, category = :cal, rank = 1, enabled = false)
        @test isempty(run_steps(ProcessingConfig(; processors = Dict(:x => idle), p_processors = Dict{Symbol,ProcessorSpec}())))

        # A run selection over all periods is valid; runs are matched within each period.
        @test isnothing(positional(periods = nothing, runs = DataRun.([1, 2])).periods)
    end

    @testset "check_processor_kwargs" begin
        processor(entries...) = Dict{String,Any}(
            "enabled" => true, "category" => "cal", "rank" => 1, "dependencies" => Any[], "kwargs" => Dict{String,Any}(entries...))
        d = deepcopy(base)
        d["processors"] = Dict{String,Any}("process_a" => processor("reprocess" => true, "timeout" => 1))
        d["p_processors"] = Dict{String,Any}("p_process_b" => processor("anything" => 1))
        @test isnothing(check_processor_kwargs(ProcessingConfig(d); processors = STUB_PROCESSORS))

        d["processors"]["process_a"]["kwargs"]["only_pulser"] = true
        @test_throws "`process_a` does not accept keyword(s) only_pulser" check_processor_kwargs(ProcessingConfig(d); processors = STUB_PROCESSORS)
        d["processors"]["process_missing"] = processor()
        @test_throws "`process_missing` is not a registered processor" check_processor_kwargs(ProcessingConfig(d); processors = STUB_PROCESSORS)
        d["processors"]["process_missing"]["enabled"] = false
        d["processors"]["process_a"]["kwargs"] = Dict{String,Any}()
        @test isnothing(check_processor_kwargs(ProcessingConfig(d); processors = STUB_PROCESSORS))

        # `run_processing` passes `only_first_period` to partition processors and may pass `reprocess`.
        p_process_c(cfg, l200, period; reprocess::Bool = false) = true
        d["p_processors"]["p_process_c"] = processor()
        @test_throws "`p_process_c` does not accept keyword(s) only_first_period" check_processor_kwargs(ProcessingConfig(d); processors = merge(STUB_PROCESSORS, Dict(:p_process_c => p_process_c)))
        process_d(cfg, l200, period, run) = nothing
        d["p_processors"]["p_process_c"]["enabled"] = false
        d["processors"]["process_d"] = processor()
        @test_throws "`process_d` does not accept keyword(s) reprocess" check_processor_kwargs(ProcessingConfig(d); processors = merge(STUB_PROCESSORS, Dict(:process_d => process_d)))
    end

    @testset "registered processors" begin
        @test isnothing(check_processor_kwargs(shipped))
        processors = run_steps(shipped; enabled_only = false) ∪ partition_steps(shipped; enabled_only = false)
        @test isempty(setdiff(processors, keys(Juleana.PROCESSORS)))

        # Every processor entry in the shipped config, enabled or not, should match its function's keywords.
        all_enabled = deepcopy(base)
        for (name, entry) in (all_enabled["processors"]..., all_enabled["p_processors"]...)
            entry["enabled"] = haskey(Juleana.PROCESSORS, Symbol(name))
        end
        @test isnothing(check_processor_kwargs(ProcessingConfig(all_enabled)))
        dsp = deepcopy(base)
        dsp["processors"]["process_dsp_cal"]["enabled"] = true
        @test isnothing(check_processor_kwargs(ProcessingConfig(dsp)))
        dsp["processors"]["process_dsp_cal"]["kwargs"]["use_partition_filter"] = true
        @test_throws "`process_dsp_cal` does not accept keyword(s) use_partition_filter" check_processor_kwargs(ProcessingConfig(dsp))
    end

    @testset "display_name" begin
        @test Juleana.display_name(:process_decay_time_cal) == "decay_time"
        @test Juleana.display_name(:p_process_sipm_calibration_phy) == "sipm_calibration"
        @test Juleana.display_name(:process_dsp_aux_phy) == "dsp_aux"
        @test Juleana.display_name(:dsp_cal) == "dsp"
        for name in keys(Juleana.PROCESSORS)
            display = Juleana.display_name(name)
            @test !startswith(display, "process_") && !startswith(display, "p_process_")
            @test !endswith(display, "_cal") && !endswith(display, "_phy")
            @test occursin(display, string(name))
        end
        # a display name is unique among the processors of one level and category
        for level in (:run, :partition), category in (:cal, :phy)
            specs = [s for s in vcat(collect(values(shipped.processors)), collect(values(shipped.p_processors)))
                     if s.level === level && s.category === category]
            names = Juleana.display_name.(getfield.(specs, :name))
            @test allunique(names)
        end
    end

    @testset "former processor names" begin
        d = deepcopy(base)
        d["processors"]["process_decay_time"] = pop!(d["processors"], "process_decay_time_cal")
        d["p_processors"]["p_process_energy"] = pop!(d["p_processors"], "p_process_energy_cal")
        d["processors"]["process_dsp_cal"]["dependencies"] = ["p_process_aoe_optimization_cal", "p_process_filter_optimization", "p_process_decay_time"]
        cfg = @test_logs (:warn, r"`p_process_decay_time` is now named `p_process_decay_time_cal`") (:warn, r"`p_process_energy` is now named `p_process_energy_cal`") (:warn, r"`p_process_filter_optimization` is now named `p_process_filter_optimization_cal`") (:warn, r"`process_decay_time` is now named `process_decay_time_cal`") ProcessingConfig(d)
        @test haskey(cfg.processors, :process_decay_time_cal) && !haskey(cfg.processors, :process_decay_time)
        @test haskey(cfg.p_processors, :p_process_energy_cal)
        @test cfg.processors[:process_dsp_cal].dependencies == [:p_process_aoe_optimization_cal, :p_process_filter_optimization_cal, :p_process_decay_time_cal]
        @test cfg.processors[:process_decay_time_cal].name === :process_decay_time_cal

        both = deepcopy(base)
        both["processors"]["process_decay_time"] = deepcopy(both["processors"]["process_decay_time_cal"])
        @test_throws "has both `process_decay_time` and `process_decay_time_cal`" ProcessingConfig(both)

        @test_logs ProcessingConfig(base)
        @test all(((old, new),) -> haskey(Juleana.PROCESSORS, new) && !haskey(Juleana.PROCESSORS, old), Juleana.RENAMED_PROCESSORS)
    end
end
