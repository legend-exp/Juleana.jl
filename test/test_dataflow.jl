# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Juleana
using Test
using Distributed: addprocs, myid, rmprocs, @everywhere
using LegendDataManagement: LegendDataManagement, DataPeriod, DataRun, FileKey, LegendData, lreport
using LegendDataManagement.LDMUtils: create_logtbl
using ParallelProcessingTools: FlexWorkerPool, ppt_worker_pool, ppt_worker_pool!

# Records what `display` hands to it: shown text as is, `image/png` as `mime => x`.
struct RecordingDisplay <: AbstractDisplay
    shown::Vector{Any}
end
Base.display(d::RecordingDisplay, x) = (push!(d.shown, x); nothing)
Base.display(d::RecordingDisplay, mime::MIME"image/png", x) = (push!(d.shown, mime => x); nothing)

# Stands in for `LegendData`: every run is in the run info, and every period is its own
# partition.
struct FakeData end
LegendDataManagement.is_lrun(::FakeData, key) = true
Juleana.partition_periods(::FakeData, period) = [period]
# Periods 3 and 4 share a partition.
struct SpanData end
LegendDataManagement.is_lrun(::SpanData, key) = true
Juleana.partition_periods(::SpanData, period) = period.no in (3, 4) ? DataPeriod.([3, 4]) : [period]
# Runs that are in the run info but are no analysis runs.
struct NoAnalysisData end
LegendDataManagement.is_lrun(::NoAnalysisData, key) = true
LegendDataManagement.is_analysis_run(::NoAnalysisData, key) = false
# Runs that are not in the run info.
struct NoRunData end
LegendDataManagement.is_lrun(::NoRunData, key) = false
Juleana.partition_periods(::Union{NoAnalysisData,NoRunData}, period) = [period]

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
        @test length(Juleana.PROCESSORS) == 32
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

    @testset "config folder of the data production" begin
        production = mktempdir()
        shipped = joinpath(dirname(@__DIR__), "config", "processing_config.yaml")
        withenv("LEGEND_DATA_CONFIG" => joinpath(production, "config.json")) do
            @test Juleana.production_config_dir() == joinpath(production, "config")
            # without --config: the shipped config is copied into the production
            installed = joinpath(production, "config", "processing_config.yaml")
            @test Juleana.default_config_file() == installed && !ispath(installed)
            @test_logs (:info, r"Copied the processing config shipped with Juleana") @test Juleana.parse_commandline(String[])["config"] == installed
            @test read(installed) == read(shipped)
            # an existing config is kept
            write(installed, "{}")
            @test_logs Juleana.parse_commandline(["-p", "3"])["config"] == installed
            @test read(installed, String) == "{}"
            # an old processing_config.json is ignored with a warning, the yaml is installed
            rm(installed)
            legacy = joinpath(production, "config", "processing_config.json")
            write(legacy, "{\"config\": {}}")
            @test_logs (:warn, r"Ignoring .*processing_config\.json") (:info, r"Copied the processing config") Juleana.install_default_config()
            @test read(installed) == read(shipped)
            @test read(legacy, String) == "{\"config\": {}}"
            @test_logs Juleana.install_default_config()
            # with --config nothing is copied
            fresh = mktempdir()
            withenv("LEGEND_DATA_CONFIG" => joinpath(fresh, "config.json")) do
                @test Juleana.parse_commandline(["-c", "x.json"])["config"] == "x.json"
                @test !ispath(joinpath(fresh, "config"))
            end
            @test Juleana.parse_commandline(["-c", "x.json"])["config"] == "x.json"
        end
        other = mktempdir()
        withenv("LEGEND_DATA_CONFIG" => "$(joinpath(production, "a.json")):$(joinpath(production, "b.json"))") do
            @test Juleana.production_config_dir() == joinpath(production, "config")
        end
        # a site override before the data config of the production
        site = joinpath(other, "site.yaml")
        withenv("LEGEND_DATA_CONFIG" => "$site:$(joinpath(production, "config.json"))") do
            @test Juleana.data_config_files() == [site, joinpath(production, "config.json")]
            @test Juleana.production_config_dir() == joinpath(production, "config")
            @test Juleana.current_production() == (basename(production), dirname(production))
            @test Juleana.with_production_config("/elsewhere/config.json") == "$site:/elsewhere/config.json"
        end
        withenv("LEGEND_DATA_CONFIG" => nothing) do
            # without a data production there is no default config
            @test isnothing(Juleana.parse_commandline(String[])["config"])
            @test Juleana.parse_commandline(["--new-production"])["new_production"]
            @test_throws "the environment variable LEGEND_DATA_CONFIG is not set" Juleana.production_config_dir()
            @test Juleana.with_production_config("/elsewhere/config.json") == "/elsewhere/config.json"
        end
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
            processors = stubs)
        @test calls == [(:run_a, p3), (:run_a, p3), (:p_part_b, p3)]
        @test all(values(run_status[p3][:run_a])) && partition_status[p3][:p_part_b]

        @test_throws "unregistered processor(s) p_part_b" run_processing(cfg, FakeData(), [p3], Symbol[], [:p_part_b],
            stub_status([p3], runs, [:run_a], [:p_part_b])...; processors = Dict{Symbol,Any}(:run_a => run_a))

        # A processor returning `true` finishes after the previous period; when that one
        # throws, only its failure is reported.
        p_part_c(cfg, l200, period; reprocess::Bool = false, only_first_period::Bool = false) =
            period == p3 ? (sleep(0.2); error("p03 failed")) : true
        cfg_c = ProcessingConfig(; processors = Dict{Symbol,ProcessorSpec}(),
            p_processors = Dict(:p_part_c => ProcessorSpec(; name = :p_part_c, level = :partition, category = :cal, rank = 1)))
        store = ProgressStore()
        err = try
            run_processing(cfg_c, FakeData(), [p3, p4], Symbol[], [:p_part_c], stub_status([p3, p4], runs, Symbol[], [:p_part_c])...;
                processors = Dict{Symbol,Any}(:p_part_c => p_part_c), progress_store = store)
        catch e
            e
        end
        @test err isa CompositeException
        @test [sprint(showerror, Juleana.original_exception(x)) for x in err.exceptions] == ["p03 failed"]
        @test Dict(e.period => e.state for e in progress(store).steps) == Dict(p3 => :failed, p4 => :cancelled)

        # A partition step waits for the run dependencies of the unselected partition
        # step before it, and for those runs in all periods of its partitions.
        empty!(calls)
        run_slow(cfg, l200, period, run; reprocess::Bool = false) = (sleep(period == p4 ? 0.6 : 0.2); record!(:run_a, period); nothing)
        p_part_d(cfg, l200, period; reprocess::Bool = false, only_first_period::Bool = false) = (record!(:p_part_d, period); false)
        cfg_d = ProcessingConfig(;
            processors = Dict(:run_a => ProcessorSpec(; name = :run_a, level = :run, category = :cal, rank = 1)),
            p_processors = Dict(
                :p_part_b => ProcessorSpec(; name = :p_part_b, level = :partition, category = :cal, rank = 1, dependencies = [:run_a]),
                :p_part_d => ProcessorSpec(; name = :p_part_d, level = :partition, category = :cal, rank = 2, dependencies = [:p_part_b])))
        run_processing(cfg_d, SpanData(), [p3, p4], [:run_a], [:p_part_d], stub_status([p3, p4], runs, [:run_a], [:p_part_d])...;
            processors = Dict{Symbol,Any}(:run_a => run_slow, :p_part_d => p_part_d))
        # both partition steps start only after all four runs
        @test count(==(:run_a) ∘ first, calls[1:4]) == 4
        @test sort(calls[5:6]) == [(:p_part_d, p3), (:p_part_d, p4)]
    end

    @testset "parallel steps" begin
        p3 = DataPeriod(3)
        runs = DataRun.(1:2)
        events = Tuple{Symbol,Symbol,DataRun}[]
        events_lock = ReentrantLock()
        log!(what, step, run) = lock(() -> push!(events, (what, step, run)), events_lock)
        step(name) = (cfg, l200, period, run; reprocess::Bool = false) -> (log!(:start, name, run); sleep(0.3); log!(:end, name, run); nothing)
        spec(name, rank, deps = Symbol[]) = ProcessorSpec(; name, level = :run, category = :cal, rank, dependencies = deps)
        # a and b do not depend on each other; c depends on both
        cfg = ProcessingConfig(; processors = Dict(:a => spec(:a, 2), :b => spec(:b, 1), :c => spec(:c, 3, [:a, :b])),
            p_processors = Dict{Symbol,ProcessorSpec}())
        stubs = Dict{Symbol,Any}(n => step(n) for n in (:a, :b, :c))
        steps = [:b, :a, :c]
        run_processing(cfg, FakeData(), [p3], steps, Symbol[], stub_status([p3], runs, steps, Symbol[])...; processors = stubs)
        position(what, name, run) = findfirst(==((what, name, run)), events)
        for r in runs
            # a and b of a run overlap, c starts after both
            @test position(:start, :a, r) < position(:end, :b, r) && position(:start, :b, r) < position(:end, :a, r)
            @test position(:start, :c, r) > max(position(:end, :a, r), position(:end, :b, r))
        end

        # with one step at a time, the ready steps start by rank, then run
        empty!(events)
        run_processing(cfg, FakeData(), [p3], steps, Symbol[], stub_status([p3], runs, steps, Symbol[])...;
            processors = stubs, max_parallel_steps = 1)
        @test [(n, r) for (what, n, r) in events if what === :start] ==
            [(:b, runs[1]), (:b, runs[2]), (:a, runs[1]), (:a, runs[2]), (:c, runs[1]), (:c, runs[2])]
        @test_throws "max_parallel_steps must be zero (no limit) or positive" run_processing(cfg, FakeData(), [p3], steps, Symbol[],
            stub_status([p3], runs, steps, Symbol[])...; processors = stubs, max_parallel_steps = -1)

        # without dependency checks, a step still waits for its own level, but not for the other
        empty!(events)
        cfg_x = ProcessingConfig(; processors = Dict(:a => spec(:a, 1), :c => spec(:c, 2, [:a, :p])),
            p_processors = Dict(:p => ProcessorSpec(; name = :p, level = :partition, category = :cal, rank = 1)))
        p_stub(cfg, l200, period; reprocess::Bool = false, only_first_period::Bool = false) = (sleep(1.0); log!(:end, :p, runs[1]); false)
        run_processing(cfg_x, FakeData(), [p3], [:a, :c], [:p], stub_status([p3], runs, [:a, :c], [:p])...;
            processors = Dict{Symbol,Any}(:a => step(:a), :c => step(:c), :p => p_stub), check_dependencies = false)
        @test position(:start, :c, runs[1]) > position(:end, :a, runs[1])
        @test position(:start, :c, runs[1]) < position(:end, :p, runs[1])
    end

    @testset "run_step" begin
        Row = NamedTuple{(:Detector, :usability, :Status, :Error)}
        items = [(detector = :V1, usability = :on), (detector = :V2, usability = :on), (detector = :V3, usability = :off)]
        prod = mktempdir()
        setup = LegendDataManagement.SetupConfig(sort([["metadata"] => mkpath(joinpath(prod, "metadata")),
            ["par"] => mkpath(joinpath(prod, "par")), ["tier"] => mkpath(joinpath(prod, "tier"))]), "valid")
        l200 = LegendData(setup, :l200, :default)
        pars_file = joinpath(prod, "pars.yaml")
        calls = []
        # Stands in for a processor: V1 and V2 are already processed, plots go to the plot tier.
        function run_proc(cfg, l200, period, run; reprocess = false, scale = 1)
            push!(calls, (; period, run, reprocess, scale))
            result = parallel(items, Row) do itr
                det = itr.detector
                if !reprocess && !Juleana.redo_detector(det) && det in (:V1, :V2)
                    return (processed = false, log = Row((det, :on, 1, "Already processed --> skipped.")))
                end
                plot_dir = mkpath(joinpath(l200.tier[:jlplt], "rplt", "cal", string(period), string(run), "proc"))
                for name in ("proc_fit", "proc_check")
                    Juleana.CairoMakie.save(joinpath(plot_dir, "l200-$period-$run-cal-$det-$name.png"), Juleana.Makie.Figure(size = (40, 30)))
                end
                (processed = true, log = Row((det, :on, 1, "")), value = scale)
            end
            Juleana.write_pars(pars_file, Juleana.PropDict(:n => length(result)))
            Juleana.write_report(joinpath(mkpath(l200.tier[:jlrep]), "proc.md"), lreport("# Results", create_logtbl(result)))
            return nothing
        end
        part_proc(cfg, l200, period; reprocess = false, only_first_period = true) =
            (push!(calls, (; period, only_first_period)); nothing)
        cfg = ProcessingConfig(;
            processors = Dict(:run_proc => ProcessorSpec(; name = :run_proc, level = :run, category = :cal, rank = 1, kwargs = Dict(:scale => 2))),
            p_processors = Dict(:part_proc => ProcessorSpec(; name = :part_proc, level = :partition, category = :cal, rank = 1)))
        processors = Dict{Symbol,Any}(:run_proc => run_proc, :part_proc => part_proc)
        # the processors of the config by level and rank, then the others
        tbl = Juleana.processors(cfg; processors = merge(processors, Dict{Symbol,Any}(:extra => identity)))
        @test tbl.Processor == [:run_proc, :part_proc, :extra] && isequal(tbl.Level, [:run, :partition, missing])
        @test isequal(tbl.Rank, [1, 1, missing]) && tbl.Detectors == [true, true, true]
        pkg_tbl = Juleana.processors(joinpath(pkgdir(Juleana), "config", "processing_config.yaml"))
        @test first(pkg_tbl.Processor) == :process_daq_energy_calibration_cal && sort(pkg_tbl.Processor) == sort!(collect(keys(Juleana.PROCESSORS)))
        @test !pkg_tbl.Detectors[findfirst(==(:process_evt_phy), pkg_tbl.Processor)]
        output_dir = mktempdir()
        step(args...; kw...) = run_step(args...; config = cfg, l200, processors, output_dir, kw...)
        markdown(out) = sprint(show, MIME"text/markdown"(), out.report)

        # temporary outputs: only V2 runs, nothing is written to the production
        out = step(:run_proc, 3, 1; detectors = ["V2"])
        @test last(calls) == (; period = DataPeriod(3), run = DataRun(1), reprocess = false, scale = 2)
        @test first.(out.results) == items[2:2] && last(only(out.results)).value == 2
        @test !isfile(pars_file) && !isdir(joinpath(prod, "tier", "jlplt")) && !isdir(joinpath(prod, "tier", "jlrep"))
        @test isfile(joinpath(out.output_dir, "jlrep", "proc.md")) && length(out.reports) == 1
        @test out.report_file == joinpath(output_dir, "reports", "run_proc.md")
        @test sprint(show, out) == "StepOutput(run_proc p03 r001: 1 results, report in $(out.report_file))"
        report = markdown(out)
        @test occursin("# run_proc: p03 r001", report) && occursin("Detectors: V2", report)
        @test occursin("## V2", report) && occursin("<img src=\"data:image/png;base64,", report) && !occursin("V1", report)
        # plots in the order they were saved
        @test findfirst("### l200-p03-r001-cal-V2-proc_fit", report) < findfirst("### l200-p03-r001-cal-V2-proc_check", report)
        @test read(out.report_file, String) == report * "\n"
        # outside a terminal, a plot is shown by its file name
        plain = sprint(show, MIME"text/plain"(), out.report)
        @test occursin(joinpath(output_dir, "jlplt"), plain) && occursin("proc_check.png", plain) && !occursin('\e', plain)
        # display_report: the text as a report, each plot as `image/png`, in report order
        recorder = RecordingDisplay([])
        pushdisplay(recorder)
        try
            Juleana.display_report(out.report)
        finally
            popdisplay(recorder)
        end
        @test !(first(recorder.shown) isa Pair) && occursin("# run_proc: p03 r001", sprint(show, MIME"text/markdown"(), first(recorder.shown)))
        @test [basename(last(x).file) for x in recorder.shown if x isa Pair] ==
            ["l200-p03-r001-cal-V2-proc_fit.png", "l200-p03-r001-cal-V2-proc_check.png"]

        # production outputs: the other detectors are skipped as processed, everything is written there
        out = step(:run_proc, 3, 1; detectors = [:V2], outputs = :production, scale = 3)
        @test last(calls).scale == 3 && first.(out.results) == items
        @test [r.log.Error for r in last.(out.results)] == ["Already processed --> skipped.", "", ""]
        @test isfile(pars_file) && isfile(joinpath(prod, "tier", "jlrep", "proc.md"))
        report = markdown(out)
        @test occursin("## V2", report) && !occursin("## V3", report) && !occursin("V1", report) && !occursin("| V3", report)
        # the report of each call is appended
        @test count("# run_proc: p03 r001", read(out.report_file, String)) == 2
        rm(pars_file)

        # all detectors: reprocess is on unless given
        out = step(:run_proc, 3, 1)
        @test last(calls).reprocess && first.(out.results) == items && occursin("Detectors: all", markdown(out))
        @test occursin("## V1", markdown(out))
        @test Juleana.session_output_dir() == Juleana.session_output_dir() && isdir(Juleana.session_output_dir())
        step(:run_proc, 3, 1; reprocess = false)
        @test !last(calls).reprocess
        # partition level
        step(:part_proc, 3; detectors = [:V1])
        @test last(calls) == (; period = DataPeriod(3), only_first_period = false)

        @test_throws "the run-level processor `run_proc` needs a run" step(:run_proc, 3)
        @test_throws "the partition-level processor `part_proc` takes no run" step(:part_proc, 3, 1)
        @test_throws "unregistered processor `missing_proc`" step(:missing_proc, 3, 1)
        @test_throws "`outputs` is :tmp, expected :temp or :production" step(:run_proc, 3, 1; outputs = :tmp)
        @test_throws "processor `process_evt_phy` cannot select detectors" run_step(:process_evt_phy, 3, 1; detectors = [:V1])
        # a chosen detector that is not among the items stops the step before any item runs
        n_calls = length(calls)
        for outputs in (:temp, :production)
            @test_throws "the detectors V9 chosen in `run_step` are not among the items; the items have the detectors V1, V2, V3" step(:run_proc, 3, 1; detectors = [:V2, :V9], outputs)
        end
        @test length(calls) == n_calls + 2 && !isfile(pars_file)

        # the selection reaches the workers
        original_pool = ppt_worker_pool()
        pool = FlexWorkerPool(withmyid = false, label = "run_step test"; maxoccupancy = 1)
        ppt_worker_pool!(pool)
        pid = only(addprocs(1; exeflags = "--project=$(Base.active_project())"))
        try
            @everywhere [pid] using Juleana
            push!(pool, pid)
            on_worker(cfg, l200, period, run; reprocess = false) = parallel(items, Row) do itr
                (processed = true, log = Row((itr.detector, :on, 1, "")), worker = myid(), redo = Juleana.redo_detector(itr.detector))
            end
            out = run_step(:on_worker, 3, 1; config = ProcessingConfig(;
                processors = Dict(:on_worker => ProcessorSpec(; name = :on_worker, level = :run, category = :cal, rank = 1)),
                p_processors = Dict{Symbol,ProcessorSpec}()), l200, processors = Dict{Symbol,Any}(:on_worker => on_worker),
                detectors = [:V1, :V3], outputs = :production)
            @test [(r.worker, r.redo) for r in last.(out.results)] == [(pid, true), (pid, false), (pid, true)]
        finally
            ppt_worker_pool!(original_pool)
            rmprocs(pid)
        end
    end

    @testset "skipped runs" begin
        p3, r1 = DataPeriod(3), DataRun(1)
        run_a(cfg, l200, period, run; reprocess::Bool = false) = error("run_a must be skipped")
        partition_calls = DataPeriod[]
        p_b(cfg, l200, period; reprocess::Bool = false, only_first_period::Bool = true) = (push!(partition_calls, period); nothing)
        processors = Dict(:run_a => ProcessorSpec(; name = :run_a, level = :run, category = :cal, rank = 1))
        p_processors = Dict(:p_b => ProcessorSpec(; name = :p_b, level = :partition, category = :cal, rank = 1, dependencies = [:run_a]))
        stubs = Dict{Symbol,Any}(:run_a => run_a, :p_b => p_b)
        for (data, analysis_runs_only, message) in ((NoAnalysisData(), true, "p03-r001-cal is not an analysis run, skip run_a"),
                (NoRunData(), false, "p03-r001-cal is not in runinfo, skip run_a"))
            cfg = ProcessingConfig(; processors, p_processors, analysis_runs_only)
            run_status, partition_status = stub_status([p3], [r1], [:run_a], [:p_b])
            # the partition step that waits for the skipped run still runs
            task = Threads.@spawn @test_logs (:warn, message) match_mode = :any run_processing(cfg, data, [p3], [:run_a], [:p_b],
                run_status, partition_status; processors = stubs)
            @test timedwait(() -> istaskdone(task), 60) === :ok
            fetch(task)
            # a skipped run counts as finished for the steps that depend on it
            @test run_status[p3][:run_a][r1] && partition_status[p3][:p_b]
            @test last(partition_calls) == p3
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
        @test mode.julia_flags == `--startup-file=no --threads=$(Juleana.local_worker_threads(3)) --heap-size-hint=2G`
        @test mode.env == env_variables
        # a thread count in the settings replaces the one shared out
        mode = Juleana.runprocs_mode(ProcessingConfig(; processors, p_processors, local_n = 3,
            local_julia_settings = ["--threads=5"]))
        @test mode.julia_flags == `--startup-file=no --threads=5`
        @test Juleana.local_worker_threads(Sys.CPU_THREADS) == 1
        @test Juleana.local_worker_threads(2 * Sys.CPU_THREADS) == 1
        @test Juleana.local_worker_threads(1) == Sys.CPU_THREADS
        mode = Juleana.runprocs_mode(ProcessingConfig(; processors, p_processors, runmode = :slurm,
            slurm_flags = ["--nodes=2"], env_variables))
        @test mode isa Juleana.ParallelProcessingTools.OnSlurm
        @test mode.slurm_flags == `--nodes=2`
        @test mode.julia_flags == `--startup-file=no`
        @test mode.redirect_output
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
