# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Juleana
using Test
using LegendTestData: legend_test_data_path
using LegendDataManagement: LegendDataManagement, DataPeriod, DataRun, LegendData, readlprops,
    start_filekey, writelprops
using LegendDataManagement.LDMUtils: get_preportfilename, get_rreportfilename

const TEST_METADATA = joinpath(legend_test_data_path(), "data", "legend", "metadata")

# Write a data config in `root` with the LegendTestData metadata and tiers under
# `root/tier`, create the run directories `dirs` (relative to the tier root) and
# return the path of the data config.
function legend_test_setup(root::AbstractString, dirs)
    config = joinpath(root, "config.json")
    write(config, """
        {"setups": {"l200": {
            "paths": {"metadata": "$TEST_METADATA", "tier": "$root/tier", "par": "$root/par",
                      "log": "$root/log", "plt": "$root/plt"},
            "dataset": "valid"}}}
        """)
    for d in dirs
        mkpath(joinpath(root, "tier", d))
    end
    return config
end

# `LegendData(:l200)` for the data config `config`.
legend_test_data(config::AbstractString) = withenv(() -> LegendData(:l200), "LEGEND_DATA_CONFIG" => config)

const TEST_DIRS = ["raw/cal/p02/r006", "raw/cal/p02/r007", "raw/cal/p03/r000", "raw/cal/p13", "raw/phy/p16/r006"]

const RUN_REPORT = """
| Detector | Status | Filter Type | Error |
|:---|:---|:---|:---|
| V01 | <span style="color:green">Success</span> | trap | - |
| V02 | <span style="color:red">Failure</span> | trap | fit failed |
"""

const PARTITION_REPORT = """
| Detector | Status | Partition | Error |
|:---|:---|:---|:---|
| V01 | Success | 1 | - |
"""

spec(name, level, rank; kwargs...) = ProcessorSpec(; name, level, category = :cal, rank, kwargs...)

@testset "config" begin
    root = mktempdir()
    data_config = legend_test_setup(root, TEST_DIRS)
    l200 = legend_test_data(data_config)
    p2, p3, p13, p16 = DataPeriod.((2, 3, 13, 16))

    @testset "find_data_tier" begin
        @test Juleana.find_data_tier(l200) == (:raw, :cal)
        @test Juleana.find_data_tier(l200, p2) == (:raw, :cal)
        @test Juleana.find_data_tier(l200, p16) == (:raw, :phy)
        @test isnothing(Juleana.find_data_tier(l200, DataPeriod(99)))
    end

    @testset "available periods and runs" begin
        # p13 has no runs on disk
        @test Juleana.available_periods(l200) == [p2, p3]
        @test Juleana.available_runs(l200, p2) == DataRun.([6, 7])
        @test Juleana.available_runs(l200, p16) == [DataRun(6)]
        @test (@test_logs (:warn, r"No `DataRun` found for period p99") Juleana.available_runs(l200, DataPeriod(99))) == DataRun[]

        empty_l200 = legend_test_data(legend_test_setup(mktempdir(), String[]))
        @test (@test_logs (:warn, r"No `DataPeriod` found") Juleana.available_periods(empty_l200)) == DataPeriod[]
    end

    @testset "processable_runs" begin
        @test Juleana.processable_runs(l200, p2, nothing) == DataRun.([6, 7])
        @test Juleana.processable_runs(l200, p2, [DataRun(7)]) == [DataRun(7)]
        @test (@test_logs (:warn, "Run r008 not found in period p02") Juleana.processable_runs(l200, p2, DataRun.([6, 8]))) == [DataRun(6)]
    end

    cfg = ProcessingConfig(;
        processors = Dict(
            :process_energy_calibration => spec(:process_energy_calibration, :run, 1),
            :process_dsp_cal => spec(:process_dsp_cal, :run, 2; enabled = false)),
        p_processors = Dict(:p_process_aoe_cut => spec(:p_process_aoe_cut, :partition, 1)))

    @testset "setup_dependency_graph" begin
        periods, run_status, partition_status = Juleana.setup_dependency_graph(
            l200, cfg, [p2, p3, p13], nothing, [:process_energy_calibration], Symbol[])
        @test periods == [p2, p3]
        @test sort(collect(keys(run_status[p2][:process_energy_calibration]))) == DataRun.([6, 7])
        # only the selected steps start as unfinished
        @test !any(values(run_status[p2][:process_energy_calibration]))
        @test all(values(run_status[p2][:process_dsp_cal]))
        @test partition_status[p3][:p_process_aoe_cut]

        periods, run_status, _ = @test_logs (:warn, "Run r007 not found in period p03") Juleana.setup_dependency_graph(
            l200, cfg, [p2, p3], [DataRun(7)], Symbol[], [:p_process_aoe_cut])
        @test periods == [p2]
        @test collect(keys(run_status[p2][:process_energy_calibration])) == [DataRun(7)]
    end

    @testset "DataflowSession" begin
        periods, run_status, partition_status = Juleana.setup_dependency_graph(
            l200, cfg, [p2], nothing, Symbol[], Symbol[])
        session = DataflowSession(; args = Dict{String,Any}(), l200, config = cfg, periods,
            run_steps = [:process_energy_calibration], partition_steps = [:p_process_aoe_cut],
            run_status, partition_status)
        @test isnothing(session.runs)

        # resetting marks the session's scheduled steps as unfinished
        @test all(values(session.run_status[p2][:process_energy_calibration]))
        @test Juleana.reset_dependency_graph!(session) === session
        @test !any(values(session.run_status[p2][:process_energy_calibration]))
        @test !session.partition_status[p2][:p_process_aoe_cut]

        session.runs = [DataRun(6)]
        Juleana.reset_dependency_graph!(session)
        @test collect(keys(session.run_status[p2][:process_energy_calibration])) == [DataRun(6)]

        shown = sprint(show, session)
        @test occursin("1 period(s)", shown)
        @test occursin("1 run(s)", shown)
        @test occursin("1 run and 1 partition steps", shown)
        session.runs = nothing
        @test occursin("all runs", sprint(show, session))

        # `run_processing(session)` runs the session's steps and marks them as finished
        calls = Tuple{Symbol,DataPeriod,Any}[]
        calls_lock = ReentrantLock()
        run_stub(cfg, l200, period, run; kwargs...) = (lock(() -> push!(calls, (:run, period, run)), calls_lock); nothing)
        partition_stub(cfg, l200, period; kwargs...) = (lock(() -> push!(calls, (:partition, period, nothing)), calls_lock); false)
        Juleana.reset_dependency_graph!(session)
        run_processing(session; processors = Dict{Symbol,Any}(
            :process_energy_calibration => run_stub, :p_process_aoe_cut => partition_stub), dependency_timeout = 60)
        @test sort(calls; by = string) == sort([(:run, p2, DataRun(6)), (:run, p2, DataRun(7)), (:partition, p2, nothing)]; by = string)
        @test all(values(session.run_status[p2][:process_energy_calibration]))
        @test session.partition_status[p2][:p_process_aoe_cut]
    end

    @testset "check_reports" begin
        fk6 = start_filekey(l200, (p2, DataRun(6), :cal))
        for (filename, report) in ((get_rreportfilename(l200, fk6, :energy_calibration), RUN_REPORT),
                (get_preportfilename(l200, fk6, :aoe_cut), PARTITION_REPORT))
            mkpath(dirname(filename))
            write(filename, report)
        end
        session = DataflowSession(; args = Dict{String,Any}(), l200, config = cfg, periods = [p2],
            run_steps = Symbol[], partition_steps = Symbol[],
            run_status = Juleana.RunStatus(), partition_status = Juleana.PartitionStatus())
        output = mktemp() do path, io
            redirect_stdout(() -> Juleana.check_reports(session, [:process_energy_calibration], [:p_process_aoe_cut]), io)
            close(io)
            read(path, String)
        end
        @test occursin(r"p02-r006\s+1 of 2 entries failed: V02 \(trap\)", output)
        @test occursin(r"p02-r007\s+no report", output)
        @test occursin(r"Summary process_energy_calibration: 1 detector\(s\) with failures", output)
        @test occursin(r"V02\s+1 run\(s\): p02-r006", output)
        @test occursin("fit failed", output)
        @test occursin(r"p02\s+OK \(1 entries\)", output)
        @test occursin("All detectors passed in all checked reports of p_process_aoe_cut", output)
    end

    @testset "load_qc_evaluator" begin
        fk = start_filekey(l200, (p2, DataRun(6), :cal))
        @test ismissing(@test_logs (:info, r"ML training file not found") match_mode = :any load_qc_evaluator(l200, fk))
    end

    @testset "setup_processing" begin
        props = readlprops(joinpath(dirname(@__DIR__), "config", "processing_config.json"))
        props.config.env_variables = Dict("LEGEND_DATA_CONFIG" => data_config)
        processing_config = joinpath(root, "processing_config.json")
        writelprops(processing_config, props)
        log_path = joinpath(root, "logs")
        args = Juleana.parse_commandline(["-c", processing_config, "-p", "2", "13", "-p", "3", "-r", "6", "-o", log_path, "--or"])
        # `setup_processing` sets `ENV` from the config's `env_variables`
        l200_setup, config, periods = withenv("LEGEND_DATA_CONFIG" => nothing) do
            Juleana.setup_processing(args)
        end
        @test l200_setup isa LegendData
        @test periods == [p2, p3]
        @test config.periods == [p2, p13, p3]
        @test config.runs == [DataRun(6)]
        @test config.only_runs
        @test config.log_path == log_path
        @test isdir(log_path)
        @test config.env_variables == Dict("LEGEND_DATA_CONFIG" => data_config)
    end
end
