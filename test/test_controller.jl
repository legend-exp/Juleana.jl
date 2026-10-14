# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Juleana
using Test
using LegendDataManagement: DataPeriod, DataRun, FileKey, ProcessStatus, readlprops, writelprops
using Distributed: addprocs, rmprocs, workers, @everywhere
using ParallelProcessingTools: FlexWorkerPool, ppt_worker_pool, ppt_worker_pool!

# `legend_test_setup`, `legend_test_data`, `TEST_DIRS` and `spec`
isdefined(@__MODULE__, :legend_test_setup) || include("test_config.jl")

const StopLog = NamedTuple{(:Filekey, :Status, :Error)}

# Wait up to `timeout` seconds for `cond()`.
waituntil(cond; timeout = 60) = timedwait(cond, timeout; pollint = 0.05) === :ok

@testset "DataflowController" begin
    root = mktempdir()
    data_config = legend_test_setup(root, TEST_DIRS)
    l200 = legend_test_data(data_config)
    p2, p3 = DataPeriod.((2, 3))
    shipped_config = joinpath(dirname(@__DIR__), "config", "processing_config.json")

    calls = Tuple{Symbol,DataPeriod,Any,Dict{Symbol,Any}}[]
    calls_lock = ReentrantLock()
    record(step, period, run, kwargs) = lock(() -> push!(calls, (step, period, run, Dict{Symbol,Any}(pairs(kwargs)))), calls_lock)
    energy_stub(cfg, l200, period, run; reprocess = false, max_wvfs = 10) =
        (record(:process_energy_calibration, period, run, (; reprocess, max_wvfs)); nothing)
    aoe_stub(cfg, l200, period; reprocess = false, only_first_period = false) =
        (record(:p_process_aoe_cut, period, nothing, (; reprocess)); false)
    processors = merge(Juleana.PROCESSORS, Dict{Symbol,Any}(
        :process_energy_calibration => energy_stub, :p_process_aoe_cut => aoe_stub))

    cfg = ProcessingConfig(;
        processors = Dict(
            :process_energy_calibration => spec(:process_energy_calibration, :run, 1),
            :process_dsp_cal => spec(:process_dsp_cal, :run, 2; enabled = false)),
        p_processors = Dict(:p_process_aoe_cut => spec(:p_process_aoe_cut, :partition, 1)))

    function new_session(config = cfg)
        periods, run_status, partition_status = Juleana.setup_dependency_graph(
            l200, config, [p2, p3], nothing, run_steps(config), partition_steps(config))
        return DataflowSession(; args = Dict{String,Any}("config" => shipped_config), l200, config, periods,
            run_steps = run_steps(config), partition_steps = partition_steps(config), run_status, partition_status)
    end

    @testset "state and snapshot" begin
        ctrl = DataflowController(new_session(); processors)
        snap = snapshot(ctrl)
        @test snap.state === :ready
        @test isnothing(snap.outcome) && isnothing(snap.last_error)
        @test snap.available_periods == [p2, p3]
        @test snap.available_runs[p2] == DataRun.([6, 7])
        @test snap.periods == [p2, p3]
        @test isnothing(snap.runs)
        @test snap.run_steps == [:process_energy_calibration]
        @test snap.partition_steps == [:p_process_aoe_cut]
        @test [p.name for p in snap.processors] == [:process_energy_calibration, :process_dsp_cal, :p_process_aoe_cut]
        dsp = snap.processors[2]
        @test dsp.level === :run && !dsp.enabled && !dsp.selected && dsp.rank == 2
        @test snap.config_file == shipped_config
        @test isnothing(snap.reprocess) && snap.check_dependencies
        @test occursin("DataflowController(:ready", sprint(show, ctrl))
    end

    @testset "rejected commands" begin
        ctrl = DataflowController(new_session(); processors)
        @test_throws "StopProcessing is not possible while the controller is :ready" dispatch!(ctrl, StopProcessing())
        @test_throws "LoadSession is not possible while the controller is :ready" dispatch!(ctrl, LoadSession())
        @test_throws "periods not available on disk: p99" dispatch!(ctrl, SelectPeriods([99]))
        @test_throws "runs not available in the selected periods: r009" dispatch!(ctrl, SelectRuns([9]))
        @test_throws "not in `processors` of the config: process_bogus" dispatch!(ctrl, SelectSteps([:process_bogus], Symbol[]))
        @test_throws "not in `p_processors` of the config: process_energy_calibration" dispatch!(ctrl, SelectSteps(Symbol[], [:process_energy_calibration]))
        @test_throws "unknown processor `process_bogus`" dispatch!(ctrl, SetKwarg(:process_bogus, :x, 1))
        @test_throws "`process_energy_calibration` does not accept keyword(s) unknown_kw" dispatch!(ctrl, SetKwarg(:process_energy_calibration, :unknown_kw, 1))
        dispatch!(ctrl, SelectSteps(Symbol[], Symbol[]))
        @test_throws "no processing steps selected" dispatch!(ctrl, StartProcessing())
        # rejected commands leave the state unchanged
        snap = snapshot(ctrl)
        @test snap.state === :ready && snap.periods == [p2, p3] && isempty(snap.run_steps)
        @test all(p -> isempty(p.overridden), snap.processors)

        idle = DataflowController(Dict{String,Any}("config" => shipped_config); processors)
        @test snapshot(idle).state === :idle
        @test isempty(snapshot(idle).processors)
        @test_throws "StartProcessing is not possible while the controller is :idle" dispatch!(idle, StartProcessing())
    end

    @testset "select, override and process" begin
        empty!(calls)
        ctrl = DataflowController(new_session(); processors)
        dispatch!(ctrl, SelectPeriods(["p02"]))
        dispatch!(ctrl, SelectRuns([6]))
        dispatch!(ctrl, SelectSteps([:process_energy_calibration], [:p_process_aoe_cut]))
        dispatch!(ctrl, SetKwarg("process_energy_calibration", "max_wvfs", 5))
        dispatch!(ctrl, SetReprocess(true))
        snap = snapshot(ctrl)
        @test snap.periods == [p2] && snap.runs == [DataRun(6)]
        energy = snap.processors[1]
        @test energy.kwargs[:max_wvfs] == 5 && energy.overridden == [:max_wvfs]
        @test snap.reprocess === true
        # the config of the session is unchanged
        @test !haskey(ctrl.session.config.processors[:process_energy_calibration].kwargs, :max_wvfs)

        dispatch!(ctrl, StartProcessing())
        @test snapshot(ctrl).state in (:running, :ready)
        wait(ctrl)
        snap = snapshot(ctrl)
        @test snap.state === :ready && snap.outcome === :finished && isnothing(snap.last_error)
        @test snap.finished >= snap.started
        @test sort(map(c -> c[1:3], calls); by = string) ==
            sort([(:process_energy_calibration, p2, DataRun(6)), (:p_process_aoe_cut, p2, nothing)]; by = string)
        energy_call = only(filter(c -> c[1] === :process_energy_calibration, calls))
        @test energy_call[4] == Dict(:reprocess => true, :max_wvfs => 5)

        dispatch!(ctrl, ResetKwargs(:process_energy_calibration))
        @test isempty(snapshot(ctrl).processors[1].overridden)
        dispatch!(ctrl, SetKwarg(:process_energy_calibration, :max_wvfs, 7))
        dispatch!(ctrl, ResetKwargs())
        @test isempty(snapshot(ctrl).processors[1].overridden)
        dispatch!(ctrl, SelectRuns(nothing))
        @test isnothing(snapshot(ctrl).runs)
        dispatch!(ctrl, ResetDependencyGraph())
        @test !any(values(ctrl.session.run_status[p2][:process_energy_calibration]))
    end

    @testset "failed run" begin
        failing(cfg, l200, period, run; reprocess = false) = error("stub failure")
        ctrl = DataflowController(new_session(); processors = merge(processors, Dict{Symbol,Any}(:process_energy_calibration => failing)))
        dispatch!(ctrl, SelectSteps([:process_energy_calibration], Symbol[]))
        dispatch!(ctrl, StartProcessing())
        wait(ctrl)
        snap = snapshot(ctrl)
        @test snap.state === :ready && snap.outcome === :failed
        @test occursin("stub failure", snap.last_error)
    end

    @testset "stop" begin
        started, finished_batches = Threads.Atomic{Int}(0), Threads.Atomic{Int}(0)
        filekeys = [FileKey("l200-p02-r006-cal-20230101T00000$(i)Z") for i in 1:4]
        function slow_step(cfg, l200, period, run; reprocess = false)
            parallel(filekeys, StopLog) do fk
                Threads.atomic_add!(started, 1)
                sleep(0.5)
                (processed = true, log = StopLog((fk, ProcessStatus(1), "")))
            end
            # only reached when `parallel` returns
            Threads.atomic_add!(finished_batches, 1)
            return nothing
        end
        ctrl = DataflowController(new_session(); processors = merge(processors, Dict{Symbol,Any}(:process_energy_calibration => slow_step)))
        dispatch!(ctrl, SelectPeriods([2]))
        dispatch!(ctrl, SelectRuns([6]))
        dispatch!(ctrl, SelectSteps([:process_energy_calibration], Symbol[]))
        dispatch!(ctrl, StartProcessing())
        @test_throws "SelectPeriods is not possible while the controller is :running" dispatch!(ctrl, SelectPeriods([2]))
        @test waituntil(() -> started[] >= 1)
        dispatch!(ctrl, StopProcessing())
        @test snapshot(ctrl).state in (:stopping, :ready)
        wait(ctrl)
        snap = snapshot(ctrl)
        @test snap.state === :ready && snap.outcome === :stopped && isnothing(snap.last_error)
        # without workers the items run one at a time on the main process
        @test started[] < length(filekeys)
        @test finished_batches[] == 0
        step = only(progress(ctrl).steps)
        @test step.state === :stopped && step.total == length(filekeys)
        @test step.notrun > 0 && step.done + step.notrun == length(filekeys)

        # the next run starts with the stop flag cleared
        dispatch!(ctrl, StartProcessing())
        # the progress of the last run is gone as soon as the next one starts
        @test progress(ctrl).fraction < 1
        wait(ctrl)
        @test snapshot(ctrl).outcome === :finished
        @test finished_batches[] == 1
        @test only(progress(ctrl).steps).state === :done
        @test progress(ctrl).fraction == 1
    end

    @testset "force stop" begin
        # the worker pool of a dataflow session never runs items on the main process
        original_pool = ppt_worker_pool()
        pool = FlexWorkerPool(withmyid = false, label = "force stop test"; maxoccupancy = 1)
        ppt_worker_pool!(pool)
        pid = only(addprocs(1; exeflags = "--project=$(Base.active_project())"))
        try
            @everywhere [pid] using Juleana
            push!(pool, pid)
            filekeys = [FileKey("l200-p02-r006-cal-20230101T00000$(i)Z") for i in 1:3]
            hanging_step(cfg, l200, period, run; reprocess = false) = parallel(filekeys, StopLog) do fk
                sleep(3600)
                (processed = true, log = StopLog((fk, ProcessStatus(1), "")))
            end
            ctrl = DataflowController(new_session(); processors = merge(processors, Dict{Symbol,Any}(:process_energy_calibration => hanging_step)))
            dispatch!(ctrl, SelectPeriods([2]))
            dispatch!(ctrl, SelectRuns([6]))
            dispatch!(ctrl, SelectSteps([:process_energy_calibration], Symbol[]))
            dispatch!(ctrl, StartProcessing())
            sleep(2)
            dispatch!(ctrl, StopProcessing(; force = true))
            # the running item fails with its worker and the waiting items give up
            @test waituntil(() -> snapshot(ctrl).state === :ready; timeout = 60)
            snap = snapshot(ctrl)
            @test snap.outcome === :stopped && isnothing(snap.last_error)
            @test !(pid in workers())
        finally
            ppt_worker_pool!(original_pool)
            pid in workers() && rmprocs(pid)
        end
    end

    @testset "load and reload" begin
        session = new_session()
        ctrl = DataflowController(Dict{String,Any}("config" => shipped_config); processors, loader = args -> session)
        dispatch!(ctrl, LoadSession())
        wait(ctrl)
        @test snapshot(ctrl).state === :ready
        @test ctrl.session === session

        broken = DataflowController(Dict{String,Any}("config" => shipped_config); processors, loader = args -> error("no data"))
        dispatch!(broken, LoadSession())
        wait(broken)
        snap = snapshot(broken)
        @test snap.state === :idle && occursin("no data", snap.last_error)

        # reload reads the config file given on the command line
        props = readlprops(shipped_config)
        props.config.env_variables = Dict("LEGEND_DATA_CONFIG" => data_config)
        config_file = joinpath(root, "controller_config.json")
        writelprops(config_file, props)
        args = Juleana.parse_commandline(["-c", config_file, "-p", "2", "-o", joinpath(root, "controller_logs")])
        session = new_session()
        session = DataflowSession(; args, session.l200, session.config, session.periods, session.run_steps,
            session.partition_steps, session.run_status, session.partition_status)
        ctrl = DataflowController(session; processors)
        dispatch!(ctrl, SetKwarg(:process_energy_calibration, :max_wvfs, 5))
        withenv("LEGEND_DATA_CONFIG" => nothing) do
            dispatch!(ctrl, ReloadConfig())
            wait(ctrl)
        end
        snap = snapshot(ctrl)
        @test snap.state === :ready && isnothing(snap.last_error)
        @test snap.periods == [p2]
        @test snap.run_steps == run_steps(ctrl.session.config)
        @test all(p -> isempty(p.overridden), snap.processors)
    end

    @testset "WriteConfig" begin
        ctrl = DataflowController(new_session(); processors)
        dispatch!(ctrl, SetKwarg(:process_energy_calibration, :max_wvfs, 5))
        written = joinpath(root, "written_config.json")
        dispatch!(ctrl, WriteConfig(written))
        original, props = readlprops(shipped_config), readlprops(written)
        @test props.processors.process_energy_calibration.kwargs.max_wvfs == 5
        @test props.p_processors == original.p_processors
        @test props.config == original.config
        @test ProcessingConfig(written).processors[:process_energy_calibration].kwargs[:max_wvfs] == 5
    end
end
