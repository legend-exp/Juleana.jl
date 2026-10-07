@testset "remote/extract.jl" begin
    script = joinpath(@__DIR__, "..", "..", "src", "sync", "remote", "extract.jl")
    project = dirname(Base.active_project())
    work = mktempdir()
    sources = [write_lh5(joinpath(work, "src", "a.lh5"); scale = 1),
               write_lh5(joinpath(work, "src", "b.lh5"); scale = 2)]

    # Run the script as the sync tool does: a TOML job file in, one TOML record
    # per line on standard output.
    function run_script(command, spec; jobs = nothing, jobfile = nothing)
        if jobfile === nothing
            jobfile = joinpath(mktempdir(), "job.toml")
            open(io -> TOML.print(io, spec), jobfile, "w")
        end
        extra = jobs === nothing ? String[] : ["--jobs", string(jobs)]
        out = IOBuffer()
        err = IOBuffer()
        proc = run(pipeline(ignorestatus(
            `$(Base.julia_cmd()) --project=$project $script $command $jobfile $extra`);
            stdout = out, stderr = err))
        lines = filter(!isempty, split(String(take!(out)), '\n'))
        (; code = proc.exitcode, records = [TOML.parse(l)["r"] for l in lines],
           stderr = String(take!(err)))
    end

    extract_spec(dest) = Dict("job" => [
        Dict("source" => sources[i], "groups" => ["B00000C", "aux"],
             "destination" => joinpath(dest, "o$i.lh5")) for i in 1:2])

    @testset "inspect reports each group's stored bytes" begin
        r = run_script("inspect", Dict("files" => sources))
        @test r.code == 0
        @test [rec["file"] for rec in r.records] == sources
        @test r.records[1]["groups"] == ["B00000C", "V01234A", "aux"]
        @test r.records[1]["bytes"] == [4 * 100, 4 * 200, 4 * 300]
        @test r.records[2]["bytes"] == [4 * 200, 4 * 400, 4 * 600]
        @test [rec["layout"] for rec in r.records] == ["", ""]
    end

    @testset "extract copies the chosen groups in the main process" begin
        dest = joinpath(work, "out-main")
        r = run_script("extract", extract_spec(dest))
        @test r.code == 0
        files = filter(rec -> rec["event"] == "file", r.records)
        @test [rec["status"] for rec in files] == ["extracted", "extracted"]
        summary = only(filter(rec -> rec["event"] == "summary", r.records))
        @test summary["files"] == 2
        @test summary["extracted"] == 2
        @test summary["skipped"] == 0
        @test summary["groups"] == 4
        @test summary["workers"] == 0
        for i in 1:2
            h5open(joinpath(dest, "o$i.lh5"), "r") do out
                h5open(sources[i], "r") do src
                    @test collect(keys(out)) == ["B00000C", "aux"]
                    for name in ("B00000C", "aux")
                        @test read(out[name]["jldsp"]["waveform"]) ==
                              read(src[name]["jldsp"]["waveform"])
                        @test read_attribute(out[name], "unit") == "keV"
                    end
                    @test read_attribute(out, "juleana_sync_groups") == ["B00000C", "aux"]
                    @test read_attribute(out, "juleana_sync_source") == sources[i]
                end
            end
            @test !isfile(joinpath(dest, "o$i.lh5.partial"))
        end
    end

    @testset "a finished file is skipped until its source changes" begin
        dest = joinpath(work, "out-main")
        r = run_script("extract", extract_spec(dest))
        @test [rec["status"] for rec in r.records if rec["event"] == "file"] ==
              ["skipped", "skipped"]
        sleep(1.1)
        touch(sources[1])
        r2 = run_script("extract", extract_spec(dest))
        @test sort([rec["status"] for rec in r2.records if rec["event"] == "file"]) ==
              ["extracted", "skipped"]
        # A different group list is not a finished file.
        spec = extract_spec(dest)
        spec["job"][2]["groups"] = ["V01234A"]
        r3 = run_script("extract", spec)
        @test [rec["status"] for rec in r3.records if rec["event"] == "file"] ==
              ["skipped", "extracted"]
        h5open(joinpath(dest, "o2.lh5"), "r") do out
            @test collect(keys(out)) == ["V01234A"]
        end
    end

    @testset "two workers produce the same files" begin
        dest = joinpath(work, "out-workers")
        r = run_script("extract", extract_spec(dest); jobs = 2)
        @test r.code == 0
        @test sort([rec["status"] for rec in r.records if rec["event"] == "file"]) ==
              ["extracted", "extracted"]
        @test only(filter(rec -> rec["event"] == "summary", r.records))["workers"] == 2
        @test any(rec["worker"] != 1 for rec in r.records if rec["event"] == "file")
        for i in 1:2
            h5open(joinpath(dest, "o$i.lh5"), "r") do out
                h5open(sources[i], "r") do src
                    @test read(out["B00000C"]["jldsp"]["waveform"]) ==
                          read(src["B00000C"]["jldsp"]["waveform"])
                end
            end
        end
        r2 = run_script("inspect", Dict("files" => sources); jobs = 2)
        @test r2.code == 0
        @test sort([rec["file"] for rec in r2.records]) == sort(sources)
    end

    @testset "--jobs caps the workers by the file count" begin
        one = Dict("job" => extract_spec(joinpath(work, "out-one"))["job"][1:1])
        r = run_script("extract", one; jobs = 2)
        @test r.code == 0
        @test only(filter(rec -> rec["event"] == "summary", r.records))["workers"] == 0
    end

    @testset "a failing file stops the job with a nonzero exit" begin
        for jobs in (nothing, 2)
            dest = joinpath(work, "out-bad-$(jobs)")
            spec = extract_spec(dest)
            spec["job"][1]["groups"] = ["missing"]
            r = run_script("extract", spec; jobs)
            @test r.code == 1
            jobs === nothing || @test occursin("On worker", r.stderr)
            @test occursin("$(sources[1]): group missing not found in $(sources[1])", r.stderr)
            @test !isfile(joinpath(dest, "o1.lh5"))
            @test !isfile(joinpath(dest, "o1.lh5.partial"))
        end
    end

    @testset "an unreadable source names the file" begin
        notes = joinpath(work, "src", "notes.lh5")
        write(notes, "not an HDF5 file")
        spec = Dict("job" => [Dict("source" => notes, "groups" => ["aux"],
                                   "destination" => joinpath(work, "out-notes", "n.lh5"))])
        r = run_script("extract", spec)
        @test r.code == 1
        @test occursin(notes, r.stderr)
    end

    @testset "no further file is started after a failure" begin
        many = [write_lh5(joinpath(work, "many", "m$i.lh5")) for i in 1:6]
        dest = joinpath(work, "out-many")
        spec = Dict("job" => [Dict("source" => many[i],
                                   "groups" => i == 1 ? ["missing"] : ["aux"],
                                   "destination" => joinpath(dest, "o$i.lh5")) for i in 1:6])
        r = run_script("extract", spec; jobs = 2)
        @test r.code == 1
        @test occursin("group missing not found in $(many[1])", r.stderr)
    end

    @testset "a corrupt destination stops the job and names both files" begin
        dest = joinpath(work, "out-corrupt", "o1.lh5")
        mkpath(dirname(dest))
        write(dest, "garbage bytes")
        spec = Dict("job" => [Dict("source" => sources[1], "groups" => ["aux"],
                                   "destination" => dest)])
        r = run_script("extract", spec)
        @test r.code == 1
        @test occursin(sources[1], r.stderr)
        @test occursin(dest, r.stderr)
        @test read(dest, String) == "garbage bytes"
    end

    @testset "a destination that is not a reduced file is never overwritten" begin
        dest = joinpath(work, "out-plain", "o1.lh5")
        mkpath(dirname(dest))
        h5open(f -> f["x"] = [1, 2, 3], dest, "w")
        before = read(dest)
        spec = Dict("job" => [Dict("source" => sources[1], "groups" => ["aux"],
                                   "destination" => dest)])
        r = run_script("extract", spec)
        @test r.code == 1
        @test occursin("existing destination $dest is not a reduced file written by this tool", r.stderr)
        @test read(dest) == before
    end

    @testset "the destination may not be the source" begin
        copy = joinpath(work, "src", "copy.lh5")
        cp(sources[1], copy; force = true)
        before = read(copy)
        spec = Dict("job" => [Dict("source" => copy, "groups" => ["aux"], "destination" => copy)])
        r = run_script("extract", spec)
        @test r.code == 1
        @test occursin("destination $copy is the source $copy", r.stderr)
        @test read(copy) == before
        @test !isfile(copy * ".partial")
    end

    @testset "a missing job file fails with a message" begin
        r = run_script("inspect", Dict("files" => sources); jobfile = joinpath(work, "nope.toml"))
        @test r.code == 1
        @test occursin("extract.jl:", r.stderr)
    end

    @testset "--jobs below one is rejected" begin
        r = run_script("inspect", Dict("files" => sources); jobs = 0)
        @test r.code == 2
        @test occursin("usage:", r.stderr)
    end

    @testset "a bad command line is rejected" begin
        r = run_script("frobnicate", Dict("files" => String[]))
        @test r.code == 2
        @test occursin("usage:", r.stderr)
    end

    @testset "inspect classifies the group layouts" begin
        both = write_lh5_tier_det(joinpath(work, "src", "n.lh5"))
        one_detector = write_lh5(joinpath(work, "src", "one.lh5"); groups = ["B00000C"])
        only_aux = write_lh5_tier_det(joinpath(work, "src", "aux.lh5"); groups = ["aux"])
        events = write_lh5(joinpath(work, "src", "evt.lh5"); groups = ["jlevt"], inner = "tables")
        plain = write_lh5(joinpath(work, "src", "plain.lh5"); groups = ["x", "y"])
        two_tiers = joinpath(work, "src", "two.lh5")
        h5open(two_tiers, "w") do f
            for tier in ("jldsp", "jlhit")
                create_group(create_group(f, tier), "B00000C")
            end
        end
        channels = write_lh5(joinpath(work, "src", "ch.lh5"); groups = ["ch1104000", "ch1110402"])
        files = [both, one_detector, only_aux, events, plain, two_tiers, channels]
        r = run_script("inspect", Dict("files" => files); jobs = 1)
        @test r.code == 0
        got = Dict(rec["file"] => (rec["groups"], rec["layout"]) for rec in r.records)
        @test got[both] == (["B00000C", "V01234A", "aux"], "jldsp")
        @test only(filter(rec -> rec["file"] == both, r.records))["bytes"] == [400, 800, 1200]
        # A single top-level detector group is the older layout, not a tier group.
        @test got[one_detector] == (["B00000C"], "")
        # No detector id anywhere: no detector axis, and no group is reported.
        @test got[only_aux] == ([], "")
        @test got[events] == ([], "")
        @test got[plain] == ([], "")
        # Channel-id groups (jl-v0.4 form) are detectors of the older layout.
        @test got[channels] == (["ch1104000", "ch1110402"], "")
        # The new layout needs exactly one top-level group.
        @test got[two_tiers] == ([], "")
    end

    @testset "the helper recognizes the detector names" begin
        names = ["B00000C", "P00664B", "V01234A", "C000RG1", "C00ANG3", "S001", "PMT001",
                 "PULS01", "PULS01ANA", "AUX01", "DUMMY1", "DUMMY12", "BSLN01", "MUON01",
                 "ch1110402", "ch1104000", "ch123",
                 "b00000c", "B0000C", "B00000Q", "ch0010402", "ch12", "aux", "jlevt", "S01", "PMT1"]
        files = [write_lh5_tier_det(joinpath(work, "ids", "$i.lh5"); groups = [name])
                 for (i, name) in pairs(names)]
        r = run_script("inspect", Dict("files" => files); jobs = 1)
        layout_of = Dict(rec["file"] => rec["layout"] for rec in r.records)
        # The helper follows the strict detector id forms, one pattern per detector
        # family, so these names are not detectors even where the installed
        # LegendDataManagement accepts them.
        loose = ["B0000C", "B00000Q", "S01", "PMT1"]
        for (file, name) in zip(files, names)
            if name in loose
                @test layout_of[file] == ""
            else
                expected = LegendDataManagement._can_convert_to(LegendDataManagement.DetectorId, name) ||
                           LegendDataManagement._can_convert_to(LegendDataManagement.ChannelId, name)
                @test (layout_of[file] == "jldsp") == expected
            end
        end
        @test count(f -> layout_of[f] == "jldsp", files) == 17
    end

    @testset "the tier/detector fixture run" begin
        dir = joinpath(TIER_DET_ROOT, "tprod", "generated", "tier", "jlpks", "cal", "p18")
        files = [joinpath(dir, "r000", "l200-p18-r000-cal-20251107T191821Z-tier_jlpks.lh5"),
                 joinpath(dir, "r000", "l200-p18-r000-cal-20251107T192416Z-tier_jlpks.lh5"),
                 joinpath(dir, "r001", "l200-p18-r001-cal-20251108T101010Z-tier_jlpks.lh5")]
        r = run_script("inspect", Dict("files" => files); jobs = 1)
        @test [rec["layout"] for rec in r.records] == ["jlpks", "jlpks", "jlpks"]
        @test [rec["groups"] for rec in r.records] ==
              [["B00000C", "V01234A", "aux"], ["B00000C", "V01234A", "aux"], ["B00000C", "V01234A"]]
        @test [rec["bytes"] for rec in r.records] ==
              [[400, 800, 1200], [800, 1600, 2400], [400, 800]]
    end
end
