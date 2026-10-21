# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Juleana
import TOML
using Test

# git settings for the local test repositories: an identity, and cloning submodules from
# local paths, which git refuses by default
const GIT_TEST_ENV = (
    "GIT_AUTHOR_NAME" => "Test", "GIT_AUTHOR_EMAIL" => "test@example.org",
    "GIT_COMMITTER_NAME" => "Test", "GIT_COMMITTER_EMAIL" => "test@example.org",
    "GIT_CONFIG_COUNT" => "1", "GIT_CONFIG_KEY_0" => "protocol.file.allow", "GIT_CONFIG_VALUE_0" => "always")

git(dir, args...) = run(pipeline(`git -C $dir $args`; stdout = devnull, stderr = devnull))

# A git repository in `dir` with a commit of `file` on `main` and, for each of `branches`,
# a branch with one more file named after it.
function test_repo(dir, file; branches = String[])
    mkpath(dir)
    git(dir, "init", "-b", "main")
    write(joinpath(dir, file), file)
    git(dir, "add", ".")
    git(dir, "commit", "-m", "init")
    for branch in branches
        git(dir, "checkout", "-b", branch)
        write(joinpath(dir, "$branch.txt"), branch)
        git(dir, "add", ".")
        git(dir, "commit", "-m", branch)
        git(dir, "checkout", "main")
    end
    return dir
end

@testset "data productions" begin
    withenv(GIT_TEST_ENV...) do
        root = mktempdir()
        hardware = test_repo(joinpath(root, "hardware"), "hw.txt"; branches = ["dev"])
        jlconfig = test_repo(joinpath(root, "jlconfig"), "jl.txt"; branches = ["jl-dev"])
        simconfig = test_repo(joinpath(root, "simconfig"), "sim.txt"; branches = ["dev"])
        metadata = test_repo(joinpath(root, "metadata"), "README.md")
        for (path, url) in (
            "hardware" => hardware, joinpath("jldataprod", "config") => jlconfig,
            joinpath("simprod", "config") => simconfig)
            git(metadata, "submodule", "add", url, path)
        end
        git(metadata, "commit", "-m", "submodules")
        git(metadata, "checkout", "-b", "dev")
        write(joinpath(metadata, "dev.txt"), "dev")
        git(metadata, "add", ".")
        git(metadata, "commit", "-m", "dev")
        git(metadata, "checkout", "main")

        parent = mkpath(joinpath(root, "productions"))
        inside = mkpath(joinpath(parent, "rawdata"))
        outside = mkpath(joinpath(root, "elsewhere"))
        pars = mkpath(joinpath(root, "old", "generated", "jlpar", "rpars", "ecal", "p03"))
        write(joinpath(pars, "r000.json"), "{}")
        home = mkpath(joinpath(root, "home"))

        @testset "checks" begin
            spec(; kw...) = Juleana.ProductionSpec(;
                name = "prod", parent, metadata_url = metadata,
                copy_software = false, kw...)
            @test Juleana.check_production(spec()) == joinpath(parent, "prod")
            @test_throws "may contain only letters" Juleana.check_production(spec(name = "a b"))
            @test_throws "must be an absolute path" Juleana.check_production(spec(parent = "relative"))
            @test_throws "$inside exists" Juleana.check_production(spec(name = "rawdata"))
            @test_throws "the branch name \"x;y\"" Juleana.check_production(spec(dataprod_branch = "x;y"))
            @test_throws "the branch name \"-f\"" Juleana.check_production(spec(metadata_ref = "-f"))
            @test_throws "tier labels must be unique" Juleana.check_production(spec(tier_paths = [
                "raw" => inside, "raw" => outside]))
            @test_throws "the tier label \"r w\"" Juleana.check_production(spec(tier_paths = ["r w" =>
                inside]))
            @test_throws "is not a folder" Juleana.check_production(spec(tier_paths = ["raw" =>
                joinpath(root, "missing")]))
            @test_throws "has no /rpars or /ppars component" Juleana.check_production(spec(pars = [outside]))
            @test_throws "the parameter folder $(joinpath(root, "missing")) does not exist" Juleana.check_production(spec(pars = [joinpath(
                root, "missing")]))
            @test_throws "for the shell \"fish\"" Juleana.check_production(spec(;
                set_default = true, shell = "fish", home))
            # nothing was created
            @test readdir(parent) == ["rawdata"]
        end

        @testset "create" begin
            lines = String[]
            config = Juleana.create_production(
                Juleana.ProductionSpec(; name = "prod", parent, metadata_url = metadata,
                    jldataprod_branch = "jl-dev", dataprod_branch = "dev",
                    tier_paths = ["raw" => inside, "ext" => outside],
                    pars = [joinpath(root, "old", "generated", "jlpar", "rpars", "ecal")], set_default = true, shell = "zsh", home,
                    copy_software = false);
                log = line -> push!(lines, line))
            path = joinpath(parent, "prod")
            @test config == joinpath(path, "config.json")
            meta = joinpath(path, "legend-metadata")
            # the branches: dev in the metadata and the hardware, jl-dev in the jldataprod config,
            # the simprod config as cloned
            @test isfile(joinpath(meta, "dev.txt"))
            @test isfile(joinpath(meta, "hardware", "dev.txt"))
            @test isfile(joinpath(meta, "jldataprod", "config", "jl-dev.txt"))
            @test isfile(joinpath(meta, "simprod", "config", "sim.txt")) &&
                  !isfile(joinpath(meta, "simprod", "config", "dev.txt"))
            @test all(d -> isdir(joinpath(path, "generated", d)),
                ["tier", "jllog", "jlplt", "jlreport", "jlpar/rpars", "jlpar/ppars"])
            @test read(
                joinpath(
                    path, "generated", "jlpar", "rpars", "ecal", "p03", "r000.json"), String) ==
                  "{}"
            # the data config is valid JSON with the extra tiers after `tier`
            text = read(config, String)
            @test occursin(
                "\"tier\": \"\$_/generated/tier/\",\n                \"tier/raw\": \"\$_/../rawdata\",\n                \"tier/ext\": \"$outside\",\n",
                text)
            paths = Juleana.readlprops(config).setups.l200.paths
            @test paths[Symbol("tier/jllog")] ==
                  joinpath(path, "generated", "jllog") * "/" &&
                  normpath(paths[Symbol("tier/raw")]) == inside
            @test read(joinpath(home, ".zshrc"), String) ==
                  "export LEGEND_DATA_CONFIG=$config\n"
            @test any(contains("Cloning $metadata"), lines) &&
                  any(contains("Wrote $config"), lines)

            # a second production replaces the line in the startup file and keeps the others
            write(joinpath(home, ".zshrc"), "alias x=y\nexport LEGEND_DATA_CONFIG=/old/config.json\n")
            second = Juleana.create_production(
                Juleana.ProductionSpec(; name = "second", parent, metadata_url = metadata,
                    set_default = true, shell = "zsh", home, copy_software = false);
                log = _ -> nothing)
            @test read(joinpath(home, ".zshrc"), String) ==
                  "alias x=y\nexport LEGEND_DATA_CONFIG=$second\n"
            @test isfile(joinpath(
                parent, "second", "legend-metadata", "hardware", "hw.txt"))
            @test !isfile(joinpath(parent, "second", "legend-metadata", "dev.txt"))
            # a failing clone throws
            @test_throws "failed with exit code" Juleana.create_production(
                Juleana.ProductionSpec(; name = "third", parent,
                    metadata_url = joinpath(root, "missing"), copy_software = false);
                log = _ -> nothing)
        end

        @testset "metadata ref" begin
            # `main` records the hardware at its first commit, `release` and the tag `v1` at its `dev` branch
            recorded = test_repo(joinpath(root, "recorded"), "README.md")
            git(recorded, "submodule", "add", hardware, "hardware")
            git(recorded, "submodule", "add", jlconfig, joinpath("jldataprod", "config"))
            git(recorded, "commit", "-m", "submodules")
            git(recorded, "checkout", "-b", "release")
            git(joinpath(recorded, "hardware"), "fetch", "origin")
            git(joinpath(recorded, "hardware"), "checkout", "dev")
            git(recorded, "commit", "-am", "release")
            git(recorded, "tag", "v1")
            git(recorded, "checkout", "main")
            metadata = recorded
            for ref in ("release", "v1")
                lines = String[]
                Juleana.create_production(
                    Juleana.ProductionSpec(;
                        name = "ref-$ref", parent, metadata_url = metadata,
                        metadata_ref = ref, copy_software = false);
                    log = line -> push!(lines, line))
                meta = joinpath(parent, "ref-$ref", "legend-metadata")
                # the submodules are at the commits the ref records
                @test isfile(joinpath(meta, "hardware", "dev.txt"))
                @test any(contains("Checking out $ref"), lines) &&
                      any(contains("Updating the submodules"), lines)
            end
            Juleana.create_production(
                Juleana.ProductionSpec(; name = "ref-main", parent,
                    metadata_url = metadata, copy_software = false);
                log = _ -> nothing)
            @test !isfile(joinpath(
                parent, "ref-main", "legend-metadata", "hardware", "dev.txt"))
            # a branch is checked out as a branch, a tag is detached
            @test strip(read(
                `git -C $(joinpath(parent, "ref-release", "legend-metadata")) branch --show-current`,
                String)) == "release"
            @test isempty(strip(read(
                `git -C $(joinpath(parent, "ref-v1", "legend-metadata")) branch --show-current`,
                String)))
            # the branches apply on top of the ref
            Juleana.create_production(
                Juleana.ProductionSpec(; name = "ref-top", parent, metadata_url = metadata,
                    metadata_ref = "v1", jldataprod_branch = "jl-dev", copy_software = false);
                log = _ -> nothing)
            top = joinpath(parent, "ref-top", "legend-metadata")
            @test isfile(joinpath(top, "hardware", "dev.txt")) &&
                  isfile(joinpath(top, "jldataprod", "config", "jl-dev.txt"))
            @test_throws "failed with exit code" Juleana.create_production(
                Juleana.ProductionSpec(; name = "ref-bad", parent,
                    metadata_url = metadata, metadata_ref = "nope", copy_software = false);
                log = _ -> nothing)
        end

        @testset "software snapshot" begin
            juleana = test_repo(joinpath(root, "pkgs", "Juleana.jl"), "Project.toml")
            mkpath(joinpath(juleana, "src"))
            write(joinpath(juleana, "src", "Juleana.jl"), "module Juleana end")
            write(joinpath(juleana, "Manifest.toml"), "not copied")
            foo = test_repo(joinpath(root, "pkgs", "Foo"), "Project.toml")
            env = mkpath(joinpath(root, "env"))
            manifest = joinpath(env, "Manifest.toml")
            write(manifest, """
                julia_version = "1.12.7"
                manifest_format = "2.0"

                [[deps.Bar]]
                git-tree-sha1 = "0123"
                uuid = "00000000-0000-0000-0000-000000000002"
                version = "1.0.0"

                [[deps.Foo]]
                path = "../pkgs/Foo"
                uuid = "00000000-0000-0000-0000-000000000003"
                version = "0.1.0"

                [[deps.Juleana]]
                deps = ["Bar", "Foo"]
                git-tree-sha1 = "4567"
                uuid = "00000000-0000-0000-0000-000000000001"
                version = "0.2.0"
                """)
            dest = joinpath(root, "software")
            @test Juleana.snapshot_software(dest; manifest, source = juleana, log = _ -> nothing) ==
                  dest
            @test isfile(joinpath(dest, "Juleana.jl", "src", "Juleana.jl")) &&
                  isfile(joinpath(dest, "Foo", "Project.toml"))
            @test !ispath(joinpath(dest, "Juleana.jl", ".git")) &&
                  !ispath(joinpath(dest, "Foo", ".git"))
            copied = TOML.parsefile(joinpath(dest, "Juleana.jl", "Manifest.toml"))
            @test copied["deps"]["Juleana"][1]["path"] == "." &&
                  !haskey(copied["deps"]["Juleana"][1], "git-tree-sha1")
            @test copied["deps"]["Foo"][1]["path"] == "../Foo"
            @test copied["deps"]["Bar"][1]["git-tree-sha1"] == "0123" &&
                  copied["julia_version"] == "1.12.7"
            provenance = read(joinpath(dest, "PROVENANCE.md"), String)
            commit = strip(read(`git -C $juleana rev-parse HEAD`, String))
            # the Manifest.toml of the checkout is not tracked, so the checkout counts as modified
            @test occursin("| Juleana | $juleana | $commit | yes |", provenance)
            @test occursin(
                "| Foo | $foo | $(strip(read(`git -C $foo rev-parse HEAD`, String))) | no |",
                provenance)
            @test occursin("Pkg.Apps.develop(path = \"<this folder>/Juleana.jl\")", provenance)
            @test_throws "$dest exists" Juleana.snapshot_software(dest; manifest, source = juleana)
            # the environment of this process
            @test haskey(TOML.parsefile(Juleana.running_manifest())["deps"], "Juleana")
            @test startswith(Juleana.software_version(), "Juleana $(pkgversion(Juleana))") &&
                  endswith(Juleana.software_version(), "Julia $VERSION")
        end
    end
end
