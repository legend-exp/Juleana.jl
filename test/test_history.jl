# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Juleana
using Dates: DateTime
using LegendDataManagement: DataPeriod, DataRun
using Test

@testset "processing history" begin
    p2 = DataPeriod(2)
    step(process, level, run, outcome, started, finished, counts) = (; process, level, category = :cal, period = p2, run, outcome,
        started, finished, done = counts[1], failed = counts[2], notrun = counts[3])
    first_run = (; started = DateTime(2026, 10, 15, 12, 0, 2), finished = DateTime(2026, 10, 15, 13, 1, 5), user = "someone",
        host = "node1", outcome = :stopped, log_path = "/data/jllog/20261015T115958Z",
        steps = [step(:process_dsp_cal, :run, DataRun(6), :done, DateTime(2026, 10, 15, 12, 0, 2), DateTime(2026, 10, 15, 12, 3, 11), (12, 0, 0)),
            step(:p_process_energy_cal, :partition, nothing, :stopped, nothing, nothing, (0, 0, 0))])
    second_run = (; started = DateTime(2026, 10, 16, 8, 0, 0), finished = DateTime(2026, 10, 16, 8, 30, 0), user = "someone",
        host = "node1", outcome = :failed, log_path = "/data/jllog/20261016T080000Z",
        steps = [step(:process_dsp_cal, :run, DataRun(7), :failed, DateTime(2026, 10, 16, 8, 0, 0), DateTime(2026, 10, 16, 8, 30, 0), (3, 1, 2))])

    path = joinpath(mktempdir(), "jllog", "history.md")
    @test Juleana.read_history(path) == []
    Juleana.append_history(path, first_run)
    Juleana.append_history(path, second_run)
    text = read(path, String)
    @test startswith(text, "# Processing history\n\n## 2026-10-15 12:00:02 UTC, someone@node1: stopped\n")
    @test count("# Processing history", text) == 1
    @test occursin("| process_dsp_cal | run | cal | p02 | r006 | done | 2026-10-15 12:00:02 | 2026-10-15 12:03:11 | 12/0/0 |", text)
    @test occursin("| p_process_energy_cal | partition | cal | p02 | – | stopped | – | – | 0/0/0 |", text)
    # the file reads back as written
    @test Juleana.read_history(path) == [first_run, second_run]

    # a line that does not follow the format names the file and the line
    bad = joinpath(mktempdir(), "history.md")
    write(bad, replace(text, "| 12/0/0 |" => "| 12/0 |"))
    @test_throws "line 10 of $bad does not follow the history format" Juleana.read_history(bad)
    write(bad, "some text\n")
    @test_throws "line 1 of $bad" Juleana.read_history(bad)
end
