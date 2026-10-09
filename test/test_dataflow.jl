# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Juleana
using Test

@testset "dataflow" begin
    @testset "processor registry" begin
        @test length(Juleana.PROCESSORS) == 30
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
        @test args["periods"] == [[3]]
        @test args["runs"] == [[1, 2]]
        @test args["reprocess"]
        @test !args["only_runs"] && !args["only_partitions"] && !args["submit_jobs"]
        @test !args["analysis_runs_only"] && !args["ignore_config"]
        @test isnothing(args["runmode"])
        @test args["log_path"] == ""

        args = Juleana.parse_commandline(["-c", "x.json", "-p", "3", "4", "-p", "6", "--rm", "slurm", "--op"])
        @test args["periods"] == [[3, 4], [6]]
        @test isempty(args["runs"])
        @test args["runmode"] == "slurm"
        @test args["only_partitions"]
    end
end
