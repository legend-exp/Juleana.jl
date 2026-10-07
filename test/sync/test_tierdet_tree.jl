@testset "tier/detector layout: inventory" begin
    h = LocalHost()
    helper = HelperConfig(; staging = mktempdir())
    p = Production(h, "tprod", TIER_DET_ROOT, mktempdir())
    tier = joinpath(TIER_DET_ROOT, "tprod", "generated", "tier")
    p18 = joinpath(tier, "jlpks", "cal", "p18")
    p19 = joinpath(tier, "jlpks", "cal", "p19")
    first_file = joinpath(p18, "r000", "l200-p18-r000-cal-20251107T191821Z-tier_jlpks.lh5")
    old_file = joinpath(EXTRACT_ROOT, "xprod", "generated", "tier", "jldsp", "cal", "p18", "r000",
                        "l200-p18-r000-cal-20251107T191821Z-tier_jldsp.lh5")

    # A period directory listed with its run directories, as the interface holds it.
    function listed_period(path = p18)
        period = Node(basename(path), path, :dir)
        expand!(h, p, period; detectors = true)
        for run in run_dirs(period)
            expand!(h, p, run; detectors = true)
        end
        period
    end

    @testset "inspect_files reports the layout" begin
        found = inspect_files(h, helper, [first_file, old_file])
        @test found[1] == (["B00000C", "V01234A", "aux"], [400, 800, 1200], "jlpks")
        @test found[2] == (["B00000C", "V01234A", "aux"], [400, 800, 1200], "")
    end

    @testset "a run directory lists the detectors of the tier/detector layout" begin
        period = listed_period()
        run = run_dirs(period)[1]
        detectors = expand_detectors!(h, helper, run.children[end])
        @test [c.label for c in detectors.children] == ["B00000C", "V01234A", "aux"]
        @test [c.size for c in detectors.children] == [400, 800, 1200]
        @test detectors.children[1].remote_path == joinpath(p18, "r000", "detectors", "B00000C")
        @test all(c -> isempty(c.holders), detectors.children)
    end

    @testset "a period directory gets a detectors row when a run holds filekey files" begin
        period = listed_period()
        @test [c.kind for c in period.children] == [:dir, :dir, :detectors]
        row = period.children[3]
        @test (row.label, row.remote_path, row.parent) == ("detectors", joinpath(p18, "detectors"), period)
        @test row.children === nothing
        @test all(r -> any(c -> c.kind == :detectors, r.children), run_dirs(period))
        @test ensure_detectors!(period) === row

        cal = Node("cal", joinpath(tier, "jlpks", "cal"), :dir)
        expand!(h, p, cal; detectors = true)
        @test [c.kind for c in cal.children] == [:dir, :dir, :dir]

        empty_period = listed_period(p19)
        @test [c.kind for c in empty_period.children] == [:dir]
        empty_run = only(run_dirs(empty_period))
        @test !any(c -> c.kind == :detectors, empty_run.children)
        @test_throws "holds no filekey files and no run directories" ensure_detectors!(empty_run)
        @test_throws "has not been listed yet" ensure_detectors!(Node("p", p18, :dir))
    end

    @testset "filekey_files and run_dirs" begin
        @test filekey_files(h, joinpath(p18, "r000")) ==
              [first_file, replace(first_file, "20251107T191821Z" => "20251107T192416Z")]
        @test filekey_files(h, joinpath(p19, "r000")) == String[]
        @test [r.label for r in run_dirs(listed_period())] == ["r000", "r001"]
        @test run_dirs(Node("x", p18, :dir)) == Node[]
    end

    @testset "the period row is the union with summed sizes" begin
        period = listed_period()
        detectors = expand_detectors!(h, helper, period.children[3])
        @test [c.label for c in detectors.children] == ["B00000C", "V01234A", "aux"]
        # first-file bytes times the run's file count: r000 has two files, r001 one
        @test [c.size for c in detectors.children] == [400 * 2 + 400, 800 * 2 + 800, 1200 * 2]
        @test detectors.size == 6000
        @test detectors.children[3].remote_path == joinpath(p18, "detectors", "aux")
        @test detectors.children[1].holders == [joinpath(p18, "r000") => 2, joinpath(p18, "r001") => 1]
        @test detectors.children[3].holders == [joinpath(p18, "r000") => 2]
        @test all(c -> c.kind == :detector && c.parent === detectors, detectors.children)
        @test has_detectors(detectors)

        direct = period_detector_nodes(h, helper, listed_period())
        @test [(c.label, c.size) for c in direct] == [(c.label, c.size) for c in detectors.children]
        @test_throws "has no run directory with filekey files" period_detector_nodes(
            h, helper, listed_period(p19))
    end

    @testset "a period without a detector axis has an empty row" begin
        evt = listed_period(joinpath(tier, "jlevt", "phy", "p18"))
        @test evt.children[end].kind == :detectors
        row = expand_detectors!(h, helper, evt.children[end])
        @test row.children == Node[]
        @test !has_detectors(row)
    end

    @testset "run-level rows inherit a period-level mark" begin
        period = listed_period()
        detectors = expand_detectors!(h, helper, period.children[3])
        runs = run_dirs(period)
        r000 = expand_detectors!(h, helper, runs[1].children[end]).children
        r001 = expand_detectors!(h, helper, runs[2].children[end]).children
        set_mode!(detectors.children[1], :extract)                  # B00000C for the period
        @test covering_extract(r000[1]) === detectors.children[1]
        @test covering_extract(r001[1]) === detectors.children[1]
        @test r000[1].mode == :none && effective_mode(r000[1]) == :extract
        @test checkbox(r000[1]) == "[e]"
        @test checkbox(r000[2]) == "[ ]"
        @test covering_extract(r000[3]) === nothing
        @test covering_extract(detectors.children[1]) === nothing
        @test covering_extract(runs[1]) === nothing
        set_mode!(detectors.children[1], :none)
        @test checkbox(r000[1]) == "[ ]"
    end
end
