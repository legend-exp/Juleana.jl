# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Juleana
using Test
using LegendDataManagement: LegendDataManagement, DataPeriod, DataRun

# Stands in for `LegendData`: every run is in the run info.
struct FakeData end
LegendDataManagement.is_lrun(::FakeData, key) = true
# Runs that are in the run info but are no analysis runs.
struct NoAnalysisData end
LegendDataManagement.is_lrun(::NoAnalysisData, key) = true
LegendDataManagement.is_analysis_run(::NoAnalysisData, key) = false
# Runs that are not in the run info.
struct NoRunData end
LegendDataManagement.is_lrun(::NoRunData, key) = false

const ConcurrentDict = Juleana.ConcurrentDict

function stub_status(periods, runs, run_steps, partition_steps)
    run_status, partition_status = Juleana.RunStatus(), Juleana.PartitionStatus()
    for p in periods
        run_status[p] = ConcurrentDict{Symbol,ConcurrentDict{DataRun,Bool}}(
            [s => ConcurrentDict{DataRun,Bool}(runs .=> false) for s in run_steps])
        partition_status[p] = ConcurrentDict{Symbol,Bool}([s => false for s in partition_steps])
    end
    return run_status, partition_status
end

const REPORT = """
# Energy calibration
| Key | Value |
|:---|:---|
| Period | p03 |

| Detector | Status | Filter Type | Error |
|:---|:---|:---|:---|
| V01 | <span style="color:green">Success</span> | trap | - |
| V02 | <span style="color:red">Failure</span> | trap | fit failed |

| Filekey | Status | Failed Detectors |
|:---|:---|:---|
| l200-p03-r001-cal-20230101T000000Z | Failure | ["V03", "V04"] |
"""

@testset "dataflow" begin
    @testset "processor registry" begin
        @test length(Juleana.PROCESSORS) == 30
        @test all(((name, f),) -> nameof(f) === name, Juleana.PROCESSORS)
        @test all(name -> occursin(r"^(p_)?process_", string(name)), keys(Juleana.PROCESSORS))
        @test count(name -> startswith(string(name), "p_process_"), keys(Juleana.PROCESSORS)) == 12

        n = length(Juleana.PROCESSORS)
        @test_throws "processor `process_dsp_cal` is already registered" Juleana.register_processor!(Juleana.process_dsp_cal)
        @test length(Juleana.PROCESSORS) == n
    end

    @testset "parse_commandline" begin
        args = Juleana.parse_commandline(["-c", "x.json", "-p", "3", "-r", "1", "2", "--reprocess"])
        @test args["config"] == "x.json"
        @test args["periods"] == [["3"]]
        @test args["runs"] == [[1, 2]]
        @test args["reprocess"]
        @test !args["only_runs"] && !args["only_partitions"] && !args["submit_jobs"]
        @test !args["analysis_runs_only"] && !args["ignore_config"] && !args["no_tui"]
        @test isnothing(args["runmode"])
        @test args["log_path"] == ""

        args = Juleana.parse_commandline(["-c", "x.json", "-p", "3", "4", "-p", "6", "--rm", "slurm", "--op"])
        @test args["periods"] == [["3", "4"], ["6"]]
        @test isempty(args["runs"])
        @test args["runmode"] == "slurm"
        @test args["only_partitions"]

        @test Juleana.parse_commandline(["-c", "x.json", "-p", "6,1-3", "-p", "7,2"])["periods"] == [["6,1-3"], ["7,2"]]
        @test Juleana.parse_commandline(["-c", "x.json", "--no-tui"])["no_tui"]
        @test Juleana.parse_commandline(["-c", "x.json", "--no_tui"])["no_tui"]
    end

    @testset "parse_period_runs" begin
        p3, p6, p7 = DataPeriod.((3, 6, 7))
        @test Juleana.parse_period_runs([], []) == (nothing, nothing)
        @test Juleana.parse_period_runs([["3", "6"]], []) == ([p3, p6], nothing)
        @test Juleana.parse_period_runs([["3"], ["6"]], [[2, 1], [4]]) == ([p3, p6], DataRun.([2, 1, 4]))
        periods, runs = Juleana.parse_period_runs([["3", "6, 4-6,1"], ["7,2"]], [])
        @test periods == [p3, p6, p7]
        # periods given without runs keep all their runs
        @test runs == Dict(p6 => DataRun.([1, 4, 5, 6]), p7 => [DataRun(2)])
        @test Juleana.parse_period_runs([["6,2-2,2"]], [])[2] == Dict(p6 => [DataRun(2)])
        @test_throws "invalid period or run `x` in `-p 6,x`" Juleana.parse_period_runs([["6,x"]], [])
        @test_throws "invalid period or run `` in `-p 6,`" Juleana.parse_period_runs([["6,"]], [])
        @test_throws "invalid period or run `p6`" Juleana.parse_period_runs([["p6"]], [])
        @test_throws "period p06 is given more than once" Juleana.parse_period_runs([["6"], ["6,1"]], [])
        @test_throws "run range `3-1` in `-p 6,3-1` ends before it starts" Juleana.parse_period_runs([["6,3-1"]], [])
        @test_throws "`-r` cannot be combined" Juleana.parse_period_runs([["6,1"]], [[2]])

        # per-period runs go to the session, other run selections come from the config
        cfg = ProcessingConfig(; processors = Dict(:run_a => ProcessorSpec(; name = :run_a, level = :run, category = :cal, rank = 1)),
            p_processors = Dict{Symbol,ProcessorSpec}(), periods = [p6], runs = [DataRun(4)])
        args(opts...) = Juleana.parse_commandline(["-c", "x.json", opts...])
        @test Juleana.session_runs(args("-p", "6,1-2"), cfg) == Dict(p6 => DataRun.([1, 2]))
        @test Juleana.session_runs(args("-p", "6"), cfg) == [DataRun(4)]
    end

    @testset "run_processing" begin
        p3, p4 = DataPeriod(3), DataPeriod(4)
        runs = DataRun.(1:2)
        calls = Tuple{Symbol,DataPeriod}[]
        calls_lock = ReentrantLock()
        record!(step, period) = lock(() -> push!(calls, (step, period)), calls_lock)
        run_a(cfg, l200, period, run; reprocess::Bool = false) = (sleep(0.2); record!(:run_a, period); nothing)
        p_part_b(cfg, l200, period; reprocess::Bool = false, only_first_period::Bool = false) = (record!(:p_part_b, period); false)
        cfg = ProcessingConfig(;
            processors = Dict(:run_a => ProcessorSpec(; name = :run_a, level = :run, category = :cal, rank = 1)),
            p_processors = Dict(:p_part_b => ProcessorSpec(; name = :p_part_b, level = :partition, category = :cal, rank = 1, dependencies = [:run_a])))
        stubs = Dict{Symbol,Any}(:run_a => run_a, :p_part_b => p_part_b)

        # The partition step waits for its run dependency in all runs of the period.
        run_status, partition_status = stub_status([p3], runs, [:run_a], [:p_part_b])
        run_processing(cfg, FakeData(), [p3], [:run_a], [:p_part_b], run_status, partition_status;
            processors = stubs, dependency_timeout = 60)
        @test calls == [(:run_a, p3), (:run_a, p3), (:p_part_b, p3)]
        @test all(values(run_status[p3][:run_a])) && partition_status[p3][:p_part_b]

        @test_throws "unregistered processor(s) p_part_b" run_processing(cfg, FakeData(), [p3], Symbol[], [:p_part_b],
            stub_status([p3], runs, [:run_a], [:p_part_b])...; processors = Dict{Symbol,Any}(:run_a => run_a))

        # A processor returning `true` waits for the previous period; when that one throws,
        # the waiting chain stops too and both errors are rethrown.
        p_part_c(cfg, l200, period; reprocess::Bool = false, only_first_period::Bool = false) =
            period == p3 ? error("p03 failed") : true
        cfg_c = ProcessingConfig(; processors = Dict{Symbol,ProcessorSpec}(),
            p_processors = Dict(:p_part_c => ProcessorSpec(; name = :p_part_c, level = :partition, category = :cal, rank = 1)))
        err = try
            run_processing(cfg_c, FakeData(), [p3, p4], Symbol[], [:p_part_c], stub_status([p3, p4], runs, Symbol[], [:p_part_c])...;
                processors = Dict{Symbol,Any}(:p_part_c => p_part_c), dependency_timeout = 60)
        catch e
            e
        end
        @test err isa CompositeException
        messages = [sprint(showerror, Juleana.original_exception(x)) for x in err.exceptions]
        @test any(contains("p03 failed"), messages)
        @test any(contains("another processing task failed"), messages)
    end

    @testset "skipped runs" begin
        p3, r1 = DataPeriod(3), DataRun(1)
        run_a(cfg, l200, period, run; reprocess::Bool = false) = error("run_a must be skipped")
        processors = Dict(:run_a => ProcessorSpec(; name = :run_a, level = :run, category = :cal, rank = 1))
        stubs = Dict{Symbol,Any}(:run_a => run_a)
        for (data, analysis_runs_only, message) in ((NoAnalysisData(), true, "p03-r001-cal is not an analysis run, skip run_a"),
                (NoRunData(), false, "p03-r001-cal is not in runinfo, skip run_a"))
            cfg = ProcessingConfig(; processors, p_processors = Dict{Symbol,ProcessorSpec}(), analysis_runs_only)
            run_status, partition_status = stub_status([p3], [r1], [:run_a], Symbol[])
            @test_logs (:warn, message) match_mode = :any run_processing(cfg, data, [p3], [:run_a], Symbol[],
                run_status, partition_status; processors = stubs)
            # a skipped run counts as finished for the steps that depend on it
            @test run_status[p3][:run_a][r1]
        end
    end

    @testset "selected_steps and runprocs_mode" begin
        processors = Dict(:run_a => ProcessorSpec(; name = :run_a, level = :run, category = :cal, rank = 1))
        p_processors = Dict(:p_part_b => ProcessorSpec(; name = :p_part_b, level = :partition, category = :cal, rank = 1))
        @test Juleana.selected_steps(ProcessingConfig(; processors, p_processors)) == ([:run_a], [:p_part_b])
        @test Juleana.selected_steps(ProcessingConfig(; processors, p_processors, only_runs = true)) == ([:run_a], Symbol[])
        @test Juleana.selected_steps(ProcessingConfig(; processors, p_processors, only_partitions = true)) == (Symbol[], [:p_part_b])

        env_variables = Dict("A" => "1")
        mode = Juleana.runprocs_mode(ProcessingConfig(; processors, p_processors, local_n = 3, env_variables,
            local_julia_settings = ["--heap-size-hint=2G"]))
        @test mode isa Juleana.ParallelProcessingTools.OnLocalhost
        @test mode.n == 3
        @test mode.julia_flags == `--startup-file=no --heap-size-hint=2G`
        @test mode.env == env_variables
        mode = Juleana.runprocs_mode(ProcessingConfig(; processors, p_processors, runmode = :slurm,
            slurm_flags = ["--nodes=2"], env_variables))
        @test mode isa Juleana.ParallelProcessingTools.OnSlurm
        @test mode.slurm_flags == `--nodes=2`
        @test mode.julia_flags == `--startup-file=no`
        @test mode.env == env_variables
    end

    @testset "report_failures" begin
        report = mktemp() do path, io
            write(io, REPORT)
            close(io)
            Juleana.read_report(path)
        end
        @test report.n_entries == 3
        @test report.n_failed == 2
        @test report.failures == [("V02 (trap)", "fit failed"), ("V03", ""), ("V04", "")]
    end
end
