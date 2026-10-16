# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Juleana
using Test
using Logging: Logging
using ProgressLogging: ProgressLogging
using LegendDataManagement: LegendDataManagement, DataPeriod, DataRun, FileKey, ProcessStatus

# Stand in for `LegendData`: every run is in the run info, or no run is an analysis run.
struct ProgressData end
LegendDataManagement.is_lrun(::ProgressData, key) = true
struct ProgressNoAnalysisData end
LegendDataManagement.is_lrun(::ProgressNoAnalysisData, key) = true
LegendDataManagement.is_analysis_run(::ProgressNoAnalysisData, key) = false

const ProgressLog = NamedTuple{(:Filekey, :Status, :Error)}

function progress_status(periods, runs, run_steps, partition_steps)
    run_status, partition_status = Juleana.RunStatus(), Juleana.PartitionStatus()
    for p in periods
        run_status[p] = Juleana.ConcurrentDict{Symbol,Juleana.ConcurrentDict{DataRun,Bool}}(
            [s => Juleana.ConcurrentDict{DataRun,Bool}(runs .=> false) for s in run_steps])
        partition_status[p] = Juleana.ConcurrentDict{Symbol,Bool}([s => false for s in partition_steps])
    end
    return run_status, partition_status
end

waitfor(cond; timeout = 60) = timedwait(cond, timeout; pollint = 0.05) === :ok

@testset "progress" begin
    p3, r1, r2 = DataPeriod(3), DataRun(1), DataRun(2)

    @testset "ProgressStore" begin
        store = ProgressStore()
        p = progress(store)
        @test p.fraction == 0 && isempty(p.steps) && isempty(p.groups)
        @test isnothing(p.started) && isnothing(p.eta)

        a, b = (p3, r1, :run_a), (p3, nothing, :p_part_b)
        @test_throws "progress: step" Juleana.reset_progress!(store, [a, a])
        Juleana.reset_progress!(store, [a, b])
        p = progress(store)
        @test [(e.period, e.run, e.step) for e in p.steps] == [a, b]
        @test all(e -> e.state === :waiting && e.fraction == 0 && isnothing(e.rate), p.steps)
        @test p.counts.waiting == 2 && p.counts.running == 0
        @test !isnothing(p.started) && isnothing(p.finished)

        Juleana.set_step_state!(store, a, :running)
        first_id = Juleana.items_queued!(store, a, 3)
        Juleana.item_started!(store, a, first_id, 2, "fk1")
        Juleana.item_started!(store, a, first_id + 1, 3, "fk2")
        @test only(filter(e -> e.step === :run_a, progress(store).steps)).workers == [2, 3]
        Juleana.item_finished!(store, a, first_id, :done)
        Juleana.item_finished!(store, a, first_id + 1, :failed)
        # a retried item moves to its new worker
        Juleana.item_started!(store, a, first_id + 2, 4, "fk3")
        Juleana.item_started!(store, a, first_id + 2, 5, "fk3")
        e = first(progress(store).steps)
        @test (e.state, e.total, e.done, e.failed, e.notrun, e.workers) == (:running, 3, 1, 1, 0, [5])
        @test e.fraction ≈ 2 / 4
        @test [(b.worker, b.item) for b in busy_workers(store)] == [(5, "fk3")]
        @test !isnothing(e.started) && !isnothing(e.eta) && e.rate > 0
        Juleana.item_finished!(store, a, first_id + 2, :notrun)
        p = progress(store)
        # all items finished, but the step still runs: neither the step nor the run is complete
        @test first(p.steps).fraction ≈ 3 / 4
        @test p.fraction ≈ (3 / 4 + 0) / 2
        @test !isnothing(p.eta)
        @test Juleana.items_queued!(store, a, 2) == first_id + 3

        @test_throws "unknown step state :bogus" Juleana.set_step_state!(store, a, :bogus)
        @test_throws "unknown item outcome :bogus" Juleana.item_finished!(store, a, 1, :bogus)
        @test_throws KeyError Juleana.set_step_state!(store, (p3, r2, :run_a), :running)
        @test_throws ":running is not a final step state" Juleana.finish_progress!(store, :running)

        # every started item is listed as busy until it ends
        @test isempty(busy_workers(store))

        Juleana.set_step_state!(store, a, :done)
        Juleana.finish_progress!(store, :cancelled)
        p = progress(store)
        @test [e.state for e in p.steps] == [:done, :cancelled]
        @test p.fraction == 1 && isnothing(p.eta) && !isnothing(p.finished)
        # a finished step keeps its rate up to its end and has no eta
        @test first(p.steps).rate > 0 && isnothing(first(p.steps).eta)
        @test first(p.steps).rate == first(progress(store).steps).rate
        @test isnothing(last(p.steps).rate)
        @test p.counts.done == 1 && p.counts.cancelled == 1
        @test [(g.period, g.run, g.nsteps) for g in p.groups] == [(p3, r1, 1), (p3, nothing, 1)]
        @test all(e -> isnothing(e.error) && e.nmessages == 0, p.steps)
        # the progress has the same type before, while and after a run
        @test p isa Juleana.ProgressSummary && progress(ProgressStore()) isa Juleana.ProgressSummary
    end

    @testset "step messages and errors" begin
        store = ProgressStore()
        a, b = (p3, r1, :run_a), (p3, nothing, :p_part_b)
        Juleana.reset_progress!(store, [a, b])
        Juleana.step_message!(store, a, Logging.Info, "first")
        Juleana.step_message!(store, a, Logging.Warn, "second\n  detail")
        # a step of another run is ignored
        Juleana.step_message!(store, (p3, r2, :run_a), Logging.Info, "elsewhere")
        msgs = step_messages(store, a)
        @test [(m.level, m.text) for m in msgs] == [(Logging.Info, "first"), (Logging.Warn, "second\n  detail")]
        @test isempty(step_messages(store, b)) && isempty(step_messages(store, (p3, r2, :run_a)))
        # a copy: later messages do not change it
        Juleana.step_message!(store, a, Logging.Info, "third")
        @test length(msgs) == 2
        for i in 1:Juleana.STEP_MESSAGE_CAPACITY
            Juleana.step_message!(store, a, Logging.Info, "m$i")
        end
        msgs = step_messages(store, a)
        @test length(msgs) == Juleana.STEP_MESSAGE_CAPACITY && last(msgs).text == "m$(Juleana.STEP_MESSAGE_CAPACITY)"
        @test first(progress(store).steps).nmessages == Juleana.STEP_MESSAGE_CAPACITY

        Juleana.set_step_state!(store, b, :failed; error = "fit failed")
        @test [e.error for e in progress(store).steps] == [nothing, "fit failed"]
        # a new run starts without messages and errors
        Juleana.reset_progress!(store, [a, b])
        @test isempty(step_messages(store, a)) && all(e -> isnothing(e.error), progress(store).steps)
    end

    @testset "busy workers and abandoned items" begin
        store = ProgressStore()
        a = (p3, r1, :run_a)
        Juleana.reset_progress!(store, [a])
        Juleana.set_step_state!(store, a, :running)
        first_id = Juleana.items_queued!(store, a, 3)
        Juleana.item_started!(store, a, first_id, 2, "fk1")
        sleep(0.01)
        Juleana.item_started!(store, a, first_id + 1, 3, "fk2")
        Juleana.item_finished!(store, a, first_id, :done)
        busy = only(busy_workers(store))
        @test (busy.worker, busy.item, busy.period, busy.run, busy.step, busy.abandoned) == (3, "fk2", p3, r1, :run_a, false)

        Juleana.items_abandoned!(store, a)
        e = only(progress(store).steps)
        @test (e.done, e.notrun) == (1, 2) && isempty(e.workers)
        @test only(busy_workers(store)).abandoned
        # a new run keeps the abandoned item until it ends; its end changes no counts
        Juleana.reset_progress!(store, [a])
        @test only(busy_workers(store)).worker == 3
        Juleana.item_finished!(store, a, first_id + 1, :done)
        @test isempty(busy_workers(store))
        @test only(progress(store).steps).done == 0
        # item ids are unique across runs
        @test Juleana.items_queued!(store, a, 1) == first_id + 3
    end

    cfg = ProcessingConfig(;
        processors = Dict(:run_a => ProcessorSpec(; name = :run_a, level = :run, category = :cal, rank = 1)),
        p_processors = Dict(:p_part_b => ProcessorSpec(; name = :p_part_b, level = :partition, category = :cal,
            rank = 1, dependencies = [:run_a])))

    @testset "run_processing records steps and items" begin
        item_gate, release = Base.Event(), Base.Event()
        filekeys = [FileKey("l200-p03-r001-cal-20230101T00000$(i)Z") for i in 1:3]
        function run_a(cfg, l200, period, run; reprocess = false)
            parallel(filekeys, ProgressLog) do fk
                fk == filekeys[1] && error("item failure")
                fk == filekeys[3] && wait(item_gate)
                (processed = true, log = ProgressLog((fk, ProcessStatus(1), "")))
            end
            # work after the last item, e.g. writing reports
            wait(release)
            return nothing
        end
        p_part_b(cfg, l200, period; reprocess = false, only_first_period = false) = false
        store = ProgressStore()
        run_status, partition_status = progress_status([p3], [r1, r2], [:run_a], [:p_part_b])
        task = Threads.@spawn run_processing(cfg, ProgressData(), [p3], [:run_a], [:p_part_b], run_status, partition_status;
            processors = Dict{Symbol,Any}(:run_a => run_a, :p_part_b => p_part_b), dependency_timeout = 60, progress_store = store)
        run_entries() = filter(e -> e.step === :run_a, progress(store).steps)

        # without workers, the pool hands the main process to one item at a time
        @test waitfor(() -> any(e -> e.workers == [1], run_entries()))
        @test sum(e -> length(e.workers), run_entries()) == 1
        notify(item_gate)
        @test waitfor(() -> all(e -> e.done + e.failed == 3, run_entries()))
        p = progress(store)
        for e in run_entries()
            @test (e.state, e.total, e.done, e.failed, e.notrun) == (:running, 3, 2, 1, 0)
            @test isempty(e.workers) && e.fraction ≈ 3 / 4
        end
        part = only(filter(e -> e.step === :p_part_b, p.steps))
        @test part.state === :waiting && isnothing(part.run)
        @test p.fraction < 1 && p.counts.running == 2
        @test [(g.run, g.nsteps) for g in p.groups] == [(nothing, 1), (r1, 1), (r2, 1)]

        notify(release)
        wait(task)
        p = progress(store)
        @test all(e -> e.state === :done, p.steps)
        @test p.fraction == 1 && !isnothing(p.finished)
        @test all(e -> e.finished >= e.started, p.steps)
    end

    @testset "failed, cancelled and skipped steps" begin
        run_a(cfg, l200, period, run; reprocess = false) = error("run failure")
        p_part_b(cfg, l200, period; reprocess = false, only_first_period = false) = false
        stubs = Dict{Symbol,Any}(:run_a => run_a, :p_part_b => p_part_b)
        store = ProgressStore()
        @test_throws CompositeException run_processing(cfg, ProgressData(), [p3], [:run_a], [:p_part_b],
            progress_status([p3], [r1], [:run_a], [:p_part_b])...; processors = stubs, dependency_timeout = 60, progress_store = store)
        states = Dict(e.step => e.state for e in progress(store).steps)
        # the partition step waited for the failed run step and never started
        @test states == Dict(:run_a => :failed, :p_part_b => :cancelled)
        failed = only(filter(e -> e.step === :run_a, progress(store).steps))
        @test occursin("run failure", failed.error)

        # the interface's logger keeps the messages of a step with the step
        function run_logging(cfg, l200, period, run; reprocess = false)
            @info "fitting $run"
            @warn "low statistics" channel = 7
            error("run failure")
        end
        buf = Juleana.MessageBuffer()
        Logging.with_logger(buf) do
            @test_throws CompositeException run_processing(cfg, ProgressData(), [p3], [:run_a], [:p_part_b],
                progress_status([p3], [r1], [:run_a], [:p_part_b])...;
                processors = Dict{Symbol,Any}(:run_a => run_logging, :p_part_b => p_part_b), dependency_timeout = 60,
                progress_store = store)
        end
        msgs = step_messages(store, (p3, r1, :run_a))
        @test [m.text for m in msgs] == ["fitting r001", "low statistics\n  channel = 7"]
        @test [m.level for m in msgs] == [Logging.Info, Logging.Warn]
        @test isempty(step_messages(store, (p3, nothing, :p_part_b)))
        # the messages also stay in the buffer
        @test any(l -> occursin("fitting r001", l), Juleana.message_lines(buf))

        cfg_runs = ProcessingConfig(; processors = cfg.processors, p_processors = Dict{Symbol,ProcessorSpec}(), analysis_runs_only = true)
        @test_logs (:warn, r"not an analysis run") match_mode = :any run_processing(cfg_runs, ProgressNoAnalysisData(),
            [p3], [:run_a], Symbol[], progress_status([p3], [r1], [:run_a], Symbol[])...; processors = stubs, progress_store = store)
        @test only(progress(store).steps).state === :skipped
        @test progress(store).fraction == 1
    end

    @testset "show_progress" begin
        store = ProgressStore()
        a = (p3, r1, :run_a)
        Juleana.reset_progress!(store, [a, (p3, r2, :run_a)])
        logger = Test.TestLogger(; min_level = Logging.Info)
        result = Logging.with_logger(logger) do
            show_progress(store; interval = 0.05) do
                Juleana.set_step_state!(store, a, :running)
                Juleana.items_queued!(store, a, 4)
                Juleana.item_finished!(store, a, 1, :done)
                sleep(0.3)
                Juleana.set_step_state!(store, a, :done)
                sleep(0.3)
                :result
            end
        end
        @test result === :result
        bars = [r.message for r in logger.logs if r.message isa ProgressLogging.Progress]
        @test length(bars) == length(logger.logs)
        overall = first(bars).id
        @test first(bars).name == "Processing: 0/2 steps done, 0 failed"
        step_bars = filter(b -> b.parentid == overall, bars)
        @test any(b -> b.name == "p03-r001 run_a: 1/4 items" && b.fraction ≈ 1 / 5, step_bars)
        # every bar is closed, the overall one last
        @test all(id -> any(b -> b.id == id && b.done, bars), unique(b.id for b in bars))
        @test last(bars).id == overall && last(bars).done
    end
end
