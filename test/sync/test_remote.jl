@testset "remote.jl" begin
    h = LocalHost()
    hitdir = joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier",
                      "jlhit", "cal", "p18", "r000")

    @testset "parse_dir_listing" begin
        captured = "d\t4096\tphy\nd\t4096\tcal\nf\t8192\tl200-p18-r000-phy-20251107T192416Z-tier_jlevt.lh5\nl\t12\tcurrent\n"
        entries = parse_dir_listing(captured)
        @test length(entries) == 4
        @test entries[1] == DirEntry("phy", :dir, nothing)
        @test entries[3] == DirEntry("l200-p18-r000-phy-20251107T192416Z-tier_jlevt.lh5", :file, 8192)
        @test entries[4].kind == :link
        @test_throws "cannot parse directory listing line" parse_dir_listing("garbage\n")
    end

    @testset "LocalHost list_dir" begin
        entries = list_dir(h, hitdir)
        by_name = Dict(e.name => e for e in entries)
        @test length(entries) == 3
        @test by_name["l200-p18-r000-cal-B00000C-tier_jlhit.lh5"] ==
              DirEntry("l200-p18-r000-cal-B00000C-tier_jlhit.lh5", :file, 2048)
        @test by_name["README.txt"].kind == :file
        # A directory's own size stays unknown until dir_sizes fills it.
        tierdir = joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier")
        @test all(e -> e.kind == :dir && e.size === nothing, list_dir(h, tierdir))
        @test_throws "not a directory" list_dir(h, joinpath(FIXTURE_ROOT, "nope"))
    end

    @testset "LocalHost dir_sizes" begin
        evtdir = joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier",
                          "jlevt", "phy", "p18", "r000")
        @test dir_sizes(h, [evtdir, hitdir]) == [4096 + 8192, 2048 + 1024 + 18]
        @test_throws "not a directory" dir_sizes(h, [joinpath(FIXTURE_ROOT, "nope")])

        mktempdir() do d
            write(joinpath(d, "data.bin"), "12345")
            symlink("target-name", joinpath(d, "lnk"))
            @test dir_sizes(h, [d]) == [5 + length("target-name")]
        end
    end

    @testset "read_file" begin
        cfg = read_file(h, joinpath(FIXTURE_ROOT, "test", "config.json"))
        @test occursin("\"setups\"", cfg)
        @test occursin(FIXTURE_ROOT, cfg)
        @test_throws "not a file" read_file(h, joinpath(FIXTURE_ROOT, "nope.json"))
    end

    @testset "run_remote failure is an error" begin
        @test strip(run_remote(h, `echo hello`)) == "hello"
        @test_throws "remote command failed" run_remote(h, `false`)
    end

    @testset "SSHHost command construction" begin
        s = SSHHost("cslg4")
        c = ssh_command(s, "du -sb /mnt/scratch/x")
        parts = collect(c.exec)
        @test parts[1] == "ssh"
        @test "cslg4" in parts
        @test last(parts) == "du -sb /mnt/scratch/x"
        @test any(p -> occursin("ControlMaster=auto", p), parts)
        @test any(p -> occursin("ControlPersist", p), parts)
        @test rsync_source(s, "/mnt/scratch/projects/legend/data/l200") ==
              "cslg4:/mnt/scratch/projects/legend/data/l200/"
        @test rsync_source(h, "/tmp/root") == "/tmp/root/"
    end

    @testset "SSH listing command matches a live GNU find" begin
        gfind = Sys.which("gfind")
        if gfind === nothing
            @info "GNU find (gfind) is not installed; the cross-check of parse_dir_listing against live `find -printf` output did not run"
        else
            text = read(`$gfind $hitdir -mindepth 1 -maxdepth 1 -printf "%y\t%s\t%f\n"`, String)
            gnu = sort(parse_dir_listing(text); by = e -> e.name)
            jl = sort(list_dir(h, hitdir); by = e -> e.name)
            @test [(e.name, e.kind) for e in gnu] == [(e.name, e.kind) for e in jl]
            @test [e.size for e in gnu if e.kind == :file] ==
                  [e.size for e in jl if e.kind == :file]
        end
    end
end
