# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Juleana
using Test
using LegendDataManagement: DataPeriod, DataRun, readlprops

const CONFIG_DIR = joinpath(dirname(@__DIR__), "config")

# Nested `Dict{String,Any}`, as produced by a plain JSON parser.
stringdict(x) = x
stringdict(d::AbstractDict) = Dict{String,Any}(string(k) => stringdict(v) for (k, v) in d)

module KwargsCheck
    process_a(cfg, l200, period, run; reprocess::Bool = false, timeout::Int = 0) = nothing
    p_process_b(cfg, l200, period; kwargs...) = true
end

@testset "processing config" begin
    json = ProcessingConfig(joinpath(CONFIG_DIR, "processing_config.json"))
    yaml = ProcessingConfig(joinpath(CONFIG_DIR, "processing_config.yaml"))
    base = stringdict(readlprops(joinpath(CONFIG_DIR, "processing_config.json")))

    @testset "repository configs" begin
        @test json.runmode === :local
        @test !json.submit_jobs
        @test json.local_n == 64
        @test json.local_julia_settings == String[]
        @test "--nodes=4" in json.slurm_flags
        @test json.env_variables["JULIA_WORKER_TIMEOUT"] == "240"
        @test json.periods == DataPeriod.([3, 4, 6, 7, 8, 9])
        @test isnothing(json.runs)
        @test json.analysis_runs_only && !json.only_partitions && !json.only_runs
        @test json.log_path == ""
        spec = json.processors[:process_dsp_cal]
        @test spec.level === :run && spec.category === :cal && spec.rank == 5 && !spec.enabled
        @test spec.dependencies == [:p_process_aoe_optimization, :p_process_filter_optimization, :p_process_decay_time]
        @test spec.kwargs == Dict{Symbol,Any}(:reprocess => false, :max_wvfs => 1000, :timeout => 0, :use_partition_filter => true)
        @test json.p_processors[:p_process_energy].level === :partition
        @test json.p_processors[:p_process_energy].category === :cal
        @test json.p_processors[:p_process_skm_phy].category === :phy

        @test yaml.runmode === :slurm
        @test yaml.periods == DataPeriod.([16, 18, 19, 20, 21, 22])
        @test yaml.processors[:process_sipm_calibration_phy].kwargs[:subsystems] == [:geds, :spms, :pmts, :aux]

        from_strings = ProcessingConfig(base)
        @test run_steps(from_strings; enabled_only = false) == run_steps(json; enabled_only = false)
        @test from_strings.processors[:process_dsp_cal].kwargs == spec.kwargs
        @test sprint(show, json) == "ProcessingConfig(runmode=:local, 3/15 run and 4/11 partition processors enabled)"
        @test occursin("rank=5", sprint(show, spec))
    end

    @testset "steps" begin
        @test run_steps(json) == [:process_psd_efficiencies, :process_sipm_calibration_phy, :process_evt_phy]
        @test partition_steps(json) == [:p_process_lq_calibration_cut, :p_process_psd_efficiencies,
            :p_process_sipm_calibration_phy, :p_process_skm_phy]
        all_steps = run_steps(json; enabled_only = false)
        @test length(all_steps) == 15 && first(all_steps) === :process_peak_split
        @test issorted(all_steps; by = s -> json.processors[s].rank)
        @test length(partition_steps(json; enabled_only = false)) == 11
    end

    @testset "overrides" begin
        # the JSON config sets analysis_runs_only = true and only_runs = false
        @test ProcessingConfig(base; analysis_runs_only = false).analysis_runs_only
        @test !ProcessingConfig(base; analysis_runs_only = false, ignore_config = true).analysis_runs_only
        @test !ProcessingConfig(base; ignore_config = true).analysis_runs_only
        @test ProcessingConfig(base; only_runs = true).only_runs
        @test !ProcessingConfig(base; only_runs = nothing).only_runs
        @test ProcessingConfig(base; submit_jobs = true, ignore_config = true).submit_jobs
        @test ProcessingConfig(base; runmode = "slurm").runmode === :slurm
        cfg = ProcessingConfig(base; periods = [5], runs = [1, 2], log_path = "logs")
        @test cfg.periods == [DataPeriod(5)] && cfg.runs == DataRun.([1, 2]) && cfg.log_path == "logs"
        @test isnothing(ProcessingConfig(base; periods = [5]).runs)

        @test !json.processors[:process_dsp_cal].kwargs[:reprocess]
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
        @test_throws "missing key `processing.only_runs`" ProcessingConfig(edited(d -> delete!(d["processing"], "only_runs")))
        @test_throws "unknown key `processors.process_dsp_cal.n_workers`" ProcessingConfig(edited(d -> d["processors"]["process_dsp_cal"]["n_workers"] = "all"))
        @test_throws "unknown key `config.remote_workers`" ProcessingConfig(edited(d -> d["config"]["remote_workers"] = []))
        @test_throws "unknown key `extra`" ProcessingConfig(edited(d -> d["extra"] = 1))
        @test_throws "`p_processors.p_process_energy.category` must be \"cal\" or \"phy\"" ProcessingConfig(edited(d -> d["p_processors"]["p_process_energy"]["category"] = "physics"))
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
        @test_throws "no processor is enabled" ProcessingConfig(edited(d -> foreach(p -> p["enabled"] = false, (values(d["processors"])..., values(d["p_processors"])...))))
    end

    @testset "check_processor_kwargs" begin
        processor(entries...) = Dict{String,Any}(
            "enabled" => true, "category" => "cal", "rank" => 1, "dependencies" => Any[], "kwargs" => Dict{String,Any}(entries...))
        d = deepcopy(base)
        d["processors"] = Dict{String,Any}("process_a" => processor("reprocess" => true, "timeout" => 1))
        d["p_processors"] = Dict{String,Any}("p_process_b" => processor("anything" => 1))
        @test isnothing(check_processor_kwargs(ProcessingConfig(d), KwargsCheck))

        d["processors"]["process_a"]["kwargs"]["only_pulser"] = true
        @test_throws "`process_a` does not accept keyword(s) only_pulser" check_processor_kwargs(ProcessingConfig(d), KwargsCheck)
        d["processors"]["process_missing"] = processor()
        @test_throws "`process_missing` is not defined" check_processor_kwargs(ProcessingConfig(d), KwargsCheck)
        d["processors"]["process_missing"]["enabled"] = false
        d["processors"]["process_a"]["kwargs"] = Dict{String,Any}()
        @test isnothing(check_processor_kwargs(ProcessingConfig(d), KwargsCheck))
    end
end
