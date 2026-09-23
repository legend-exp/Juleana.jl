@testset "tui.jl" begin
    h = LocalHost()

    # Render the model the way the app loop does: its own Frame over a TestBackend
    # buffer, so row_text and find_text can read the result back.
    function draw(m::SyncModel; width = 100, height = 30)
        tb = TestBackend(width, height)
        reset!(tb.buf)
        view(m, Frame(tb.buf, Rect(1, 1, width, height),
                      GraphicsRegion[], PixelSnapshot[]))
        tb
    end

    # Wait for the background listing and deliver it exactly as the app loop does.
    # TaskQueue offers no predicate for "an event is waiting", so this reads the
    # channel drain_tasks! itself reads: a change to that field would break the
    # public reader with it and surface here.
    function settle!(m::SyncModel)
        timedwait(() -> isready(m.tasks.channel), 30.0) == :ok ||
            error("the background listing did not finish within 30 s")
        drain_tasks!(e -> update!(m, e), m.tasks)
    end

    function model(; mount_root = nothing, out = joinpath(mktempdir(), "test.json"))
        local_root = mktempdir()
        p = Production(h, "test", FIXTURE_ROOT, local_root; mount_root)
        options = Options("local", FIXTURE_ROOT, local_root, mount_root, "test",
                          out, nothing, false, false)
        SyncModel(h, p, options)
    end

    @testset "initial render" begin
        m = model()
        tb = draw(m)
        @test find_text(tb, "Production: test") !== nothing
        @test find_text(tb, "config.json") !== nothing
        @test find_text(tb, "legend-metadata") === nothing   # sections show their key
        @test find_text(tb, "metadata") !== nothing
        @test find_text(tb, "tier/jlhit") !== nothing
        @test occursin("selected: 0 B copy (0 files), 0 links", row_text(tb, 30))
        @test find_text(tb, "Details") !== nothing
        @test find_text(tb, "space copy") !== nothing
        @test occursin("unsaved", row_text(tb, 30))
    end

    @testset "enter lists a section in the background" begin
        m = model()
        # Move onto the "tier" section: root, config.json, metadata, par, tier.
        for _ in 1:4
            update!(m, KeyEvent(:down))
        end
        @test current_node(m).label == "tier"
        update!(m, KeyEvent(:enter))
        @test occursin("listing", row_text(draw(m), 30))
        settle!(m)
        tb = draw(m)
        @test find_text(tb, "jlevt") !== nothing
        @test find_text(tb, "jlhit") !== nothing
        @test occursin(format_bytes(4096 + 8192), row_text(tb, find_text(tb, "jlevt").y))

        # Enter again collapses without listing again.
        update!(m, KeyEvent(:enter))
        @test find_text(draw(m), "jlevt") === nothing
        update!(m, KeyEvent(:enter))
        @test find_text(draw(m), "jlevt") !== nothing
    end

    @testset "space toggles copy and updates the total" begin
        m = model()
        update!(m, KeyEvent(:down))
        node = current_node(m)
        @test node.label == "config.json"
        update!(m, KeyEvent(' '))
        @test node.mode == :copy
        tb = draw(m)
        @test find_text(tb, "[x] config.json") !== nothing
        @test occursin(format_bytes(filesize(joinpath(FIXTURE_ROOT, "test", "config.json"))),
                       row_text(tb, 30))
        @test occursin("(1 files)", row_text(tb, 30))
        # The production row above it shows the partial marker.
        @test find_text(tb, "[-] Production: test") !== nothing

        update!(m, KeyEvent(' '))
        @test node.mode == :none
        @test occursin("selected: 0 B", row_text(draw(m), 30))
    end

    @testset "link mode needs a mount root" begin
        m = model()
        update!(m, KeyEvent(:down))
        update!(m, KeyEvent('l'))
        @test current_node(m).mode == :none
        @test occursin("mount", row_text(draw(m), 30))

        mounted = model(; mount_root = "/Volumes/cslg4")
        update!(mounted, KeyEvent(:down))
        update!(mounted, KeyEvent('l'))
        @test current_node(mounted).mode == :link
        @test find_text(draw(mounted), "[~] config.json") !== nothing
    end

    @testset "s saves the selection" begin
        out = joinpath(mktempdir(), "sync", "test.json")
        m = model(; out)
        update!(m, KeyEvent(:down))
        update!(m, KeyEvent(' '))
        @test m.dirty
        update!(m, KeyEvent('s'))
        @test !m.dirty
        @test isfile(out)
        # A wider bar: StatusBar gives the left span priority and clips the right
        # one, and an absolute selection path is longer than 100 columns leave.
        @test occursin(out, row_text(draw(m; width = 160), 30))
        back = load_selection(out, m.production)
        @test joinpath("test", "config.json") in back.copy
        @test joinpath("test", "legend-metadata") in back.copy
    end

    @testset "a failing listing reports the error" begin
        m = model()
        for _ in 1:4
            update!(m, KeyEvent(:down))
        end
        # Point the section at a directory that is not there. This keeps the test
        # offline: nothing in the suite may reach cslg4.
        current_node(m).remote_path = joinpath(FIXTURE_ROOT, "no-such-directory")
        update!(m, KeyEvent(:enter))
        settle!(m)
        @test occursin("error", lowercase(row_text(draw(m), 30)))
        @test occursin("not a directory", lowercase(row_text(draw(m), 30)))
        # The tool stays usable.
        update!(m, KeyEvent(:up))
        @test current_node(m) !== nothing
    end

    @testset "q quits" begin
        m = model()
        @test !should_quit(m)
        update!(m, KeyEvent('q'))
        @test should_quit(m)
        @test task_queue(m) === m.tasks
    end
end
