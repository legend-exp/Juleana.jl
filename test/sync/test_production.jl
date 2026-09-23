@testset "production.jl" begin
    h = LocalHost()
    p = Production(h, "test", FIXTURE_ROOT, LOCAL_ROOT)

    @testset "\$_ expansion and root resolution" begin
        @test p.name == "test"
        @test p.remote_root == FIXTURE_ROOT
        @test p.mount_root === nothing
        @test first.(p.roots) == ["metadata", "par", "tier", "tier/jlhit"]
        roots = Dict(p.roots)
        # "$_" resolves to the directory holding the production's config.json.
        @test roots["metadata"] == joinpath(FIXTURE_ROOT, "test", "legend-metadata")
        @test roots["par"] == joinpath(FIXTURE_ROOT, "test", "generated", "jlpar")
        # An absolute key may point into another top-level directory of the same root.
        @test roots["tier"] ==
              joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier")
        @test roots["tier/jlhit"] ==
              joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier", "jlhit")
    end

    @testset "path mapping" begin
        remote = joinpath(FIXTURE_ROOT, "temp", "jl-dev", "generated", "tier", "jlevt")
        @test relative(p, remote) == joinpath("temp", "jl-dev", "generated", "tier", "jlevt")
        @test relative(p, FIXTURE_ROOT) == ""
        @test to_local(p, remote) ==
              joinpath(LOCAL_ROOT, "temp", "jl-dev", "generated", "tier", "jlevt")
        @test to_local(p, FIXTURE_ROOT) == LOCAL_ROOT
        @test_throws "is not inside the remote root" relative(p, "/elsewhere/x")
        @test_throws "no mount root configured" to_mount(p, remote)

        pm = Production(h, "test", FIXTURE_ROOT, LOCAL_ROOT; mount_root = "/Volumes/cslg4")
        @test to_mount(pm, remote) ==
              joinpath("/Volumes/cslg4", "temp", "jl-dev", "generated", "tier", "jlevt")
    end

    @testset "configs that must be rejected" begin
        outside = """
        {"setups": {"l200": {"paths": {"tier": "/somewhere/else/tier"}}}}
        """
        cfg = parse_production_config(outside, joinpath(FIXTURE_ROOT, "test"))
        @test_throws "outside the remote root" production_roots(cfg, FIXTURE_ROOT)

        two = """
        {"setups": {"l200": {"paths": {"tier": "\$_/a"}},
                    "l1000": {"paths": {"tier": "\$_/b"}}}}
        """
        cfg2 = parse_production_config(two, joinpath(FIXTURE_ROOT, "test"))
        @test_throws "exactly one setup" production_roots(cfg2, FIXTURE_ROOT)

        @test_throws "not a file" Production(h, "nosuch", FIXTURE_ROOT, LOCAL_ROOT)

        unknown = """
        {"setups": {"l200": {"paths": {"tier": "\$NOPE/tier"}}}}
        """
        @test_throws "Unknown variable" parse_production_config(unknown, joinpath(FIXTURE_ROOT, "test"))
    end

    @testset "config_local.json" begin
        mkpath(joinpath(LOCAL_ROOT, "test"))
        path = write_local_config(p)
        @test path == joinpath(LOCAL_ROOT, "test", "config_local.json")
        @test isfile(path)
        # The mirrored config.json itself is never rewritten.
        @test !isfile(joinpath(LOCAL_ROOT, "test", "config.json"))

        back = readprops(path)
        paths = only(values(back.setups)).paths
        @test String(paths[Symbol("metadata")]) ==
              joinpath(LOCAL_ROOT, "test", "legend-metadata")
        @test String(paths[Symbol("tier")]) ==
              joinpath(LOCAL_ROOT, "temp", "jl-dev", "generated", "tier")
        @test String(paths[Symbol("tier/jlhit")]) ==
              joinpath(LOCAL_ROOT, "temp", "jl-dev", "generated", "tier", "jlhit")

        # LegendDataManagement can build a setup from it.
        setup = LegendDataConfig(back).setups[:l200]
        @test data_path(setup, "tier", "jlhit", "cal", "p18", "r000") ==
              joinpath(LOCAL_ROOT, "temp", "jl-dev", "generated", "tier", "jlhit",
                       "cal", "p18", "r000")
    end
end
