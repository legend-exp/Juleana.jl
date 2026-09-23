@testset "options.jl" begin
    @testset "defaults" begin
        o = parse_options(String[])
        @test o.host == "cslg4"
        @test o.remote_root == "/mnt/scratch/projects/legend/data/l200"
        @test o.production == "test"
        @test o.local_root == DEFAULT_LOCAL_ROOT
        @test o.mount_root === nothing
        @test o.from === nothing
        @test o.dry_run == false
        @test o.yes == false
        # The selection file is named after the production.
        @test o.out == joinpath(DEFAULT_SELECTION_DIR, "test.json")
    end

    @testset "overrides" begin
        o = parse_options(["--host", "other", "--production", "preprod",
                           "--remote-root", "/data/l200",
                           "--local-root", "/tmp/mirror",
                           "--mount-root", "/Volumes/cslg4",
                           "--from", "/tmp/sel.json", "--dry-run", "--yes"])
        @test o.host == "other"
        @test o.production == "preprod"
        @test o.remote_root == "/data/l200"
        @test o.local_root == "/tmp/mirror"
        @test o.mount_root == "/Volumes/cslg4"
        @test o.from == "/tmp/sel.json"
        @test o.dry_run && o.yes
        @test o.out == joinpath(DEFAULT_SELECTION_DIR, "preprod.json")
        @test parse_options(["--out", "/tmp/x.json"]).out == "/tmp/x.json"
    end

    @testset "user-supplied paths are made absolute" begin
        o = parse_options(["--local-root", "relative/mirror"])
        @test o.local_root == abspath("relative/mirror")

        o2 = parse_options(["--mount-root", "relative/mount"])
        @test o2.mount_root == abspath("relative/mount")

        o3 = parse_options(["--remote-root", "relative/remote"])
        @test o3.remote_root == abspath("relative/remote")
    end

    @testset "flags that need --from" begin
        @test_throws "only mean something together with --from" parse_options(["--dry-run"])
        @test_throws "only mean something together with --from" parse_options(["--yes"])
    end

    @testset "headless dry run" begin
        local_root = mktempdir()
        h = LocalHost()
        p = Production(h, "test", FIXTURE_ROOT, local_root)
        evt = joinpath("temp", "jl-dev", "generated", "tier", "jlevt", "phy", "p18", "r000")
        sel = Selection("local", "test", FIXTURE_ROOT, local_root, nothing,
                        [joinpath("test", "config.json"), evt], String[], now())
        selpath = save_selection(joinpath(mktempdir(), "test.json"), sel)

        options = Options("local", FIXTURE_ROOT, local_root, nothing, "test",
                          selpath, selpath, true, false)
        path = tempname()
        code = open(path, "w") do io
            redirect_stdout(() -> main(options, h), io)
        end
        text = read(path, String)
        @test code == 0
        @test occursin("selected: ", text)
        @test occursin("copy (3 files)", text)
        @test !isdir(joinpath(local_root, "temp"))
    end

    @testset "headless transfer" begin
        local_root = mktempdir()
        h = LocalHost()
        p = Production(h, "test", FIXTURE_ROOT, local_root)
        evt = joinpath("temp", "jl-dev", "generated", "tier", "jlevt", "phy", "p18", "r000")
        sel = Selection("local", "test", FIXTURE_ROOT, local_root, nothing,
                        [joinpath("test", "config.json"), evt], String[], now())
        selpath = save_selection(joinpath(mktempdir(), "test.json"), sel)

        options = Options("local", FIXTURE_ROOT, local_root, nothing, "test",
                          selpath, selpath, false, true)
        path = tempname()
        code = open(path, "w") do io
            redirect_stdout(() -> main(options, h), io)
        end
        text = read(path, String)
        @test code == 0
        @test isfile(joinpath(local_root, evt,
                              "l200-p18-r000-phy-20251107T191821Z-tier_jlevt.lh5"))
        @test occursin("LEGEND_DATA_CONFIG=", text)
        @test occursin("transferred ", text)
    end

    @testset "a selection for another production is refused" begin
        local_root = mktempdir()
        h = LocalHost()
        sel = Selection("local", "preprod", FIXTURE_ROOT, local_root, nothing,
                        String[], String[], now())
        selpath = save_selection(joinpath(mktempdir(), "preprod.json"), sel)
        options = Options("local", FIXTURE_ROOT, local_root, nothing, "test",
                          selpath, selpath, true, true)
        @test_throws "is for production preprod" main(options, h)
    end
end
