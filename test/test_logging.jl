# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Test
using Juleana
using Distributed: addprocs, remotecall_fetch, rmprocs, @everywhere
using Logging: Logging, with_logger

module LogTestModule
f() = @debug "debug from LogTestModule"
end

# Log records written by `f()` through a file-only `processing_logger`.
function logged_lines(f; log_level, debug_modules = "")
    log_file = tempname()
    withenv("JULIA_DEBUG" => debug_modules) do
        with_logger(f, Juleana.processing_logger(; log_file, log_level, console_level = nothing))
    end
    return readlines(log_file)
end

@testset "logging" begin
    @testset "parse_log_level" begin
        @test Juleana.parse_log_level("debug") == Logging.Debug
        @test Juleana.parse_log_level("info") == Logging.Info
        @test Juleana.parse_log_level("warn") == Logging.Warn
        @test Juleana.parse_log_level("error") == Logging.Error
        @test_throws "key `config.log_level` must be one of" Juleana.parse_log_level("verbose")
    end

    @testset "record format" begin
        lines = logged_lines(; log_level = Logging.Info) do
            @info "first line\nsecond line" n = 3
            @warn "careful"
        end
        @test occursin(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z Info  \[Main\] first line$", lines[1])
        @test lines[2] == "    second line"
        @test lines[3] == "    n = 3"
        @test occursin(r"Warn  \[Main\] careful$", lines[4])
        @test startswith(lines[5], "    @ ") && occursin("test_logging.jl:", lines[5])
        @test length(lines) == 5

        lines = logged_lines(; log_level = Logging.Info) do
            try
                error("boom")
            catch e
                @error "failed" exception = (e, catch_backtrace())
            end
        end
        @test "    exception = boom" in lines
        @test any(startswith("        Stacktrace:"), lines)
    end

    @testset "levels" begin
        log_all() = (@debug "debug record"; @info "info record"; @warn "warn record"; @error "error record"; LogTestModule.f())
        messages(lines) = filter(l -> !startswith(l, "    "), lines)

        @test length(messages(logged_lines(log_all; log_level = Logging.Info))) == 3
        @test length(messages(logged_lines(log_all; log_level = Logging.Warn))) == 2
        @test length(messages(logged_lines(log_all; log_level = Logging.Error))) == 1
        # `debug` adds only the debug records of the modules in `JULIA_DEBUG`
        lines = logged_lines(log_all; log_level = Logging.Debug, debug_modules = "LogTestModule")
        @test length(messages(lines)) == 4
        @test any(contains("debug from LogTestModule"), lines)
        @test !any(contains("debug record"), lines)
        # other levels drop debug records even of the `JULIA_DEBUG` modules
        @test !any(contains("debug from LogTestModule"), logged_lines(log_all; log_level = Logging.Info, debug_modules = "LogTestModule"))
        @test !any(contains("info record"), logged_lines(log_all; log_level = Logging.Warn, debug_modules = "LogTestModule"))
    end

    @testset "progress records" begin
        lines = logged_lines(; log_level = Logging.Debug) do
            id = Juleana.uuid4()
            @info Juleana.ProgressLogging.Progress(id, 0.5; name = "bar")
            @info "after the bar"
        end
        @test length(lines) == 1 && occursin("after the bar", only(lines))
    end

    @testset "sinks" begin
        @test_throws "no log file and no console output" Juleana.processing_logger(; console_level = nothing)
        @test Juleana.process_log_file("logs") == joinpath("logs", "head.log")
    end

    @testset "worker log file" begin
        log_path = mktempdir()
        pid = only(addprocs(1; exeflags = "--project=$(Base.active_project())"))
        try
            @everywhere [pid] using Juleana
            remotecall_fetch(pid, log_path) do log_path
                Juleana.init_process(log_path, Juleana.parse_log_level("info"))
                @info "worker record"
                @debug "hidden worker record"
            end
            log_file = joinpath(log_path, "worker-$pid-$(gethostname()).log")
            @test remotecall_fetch(Juleana.process_log_file, pid, log_path) == log_file
            lines = readlines(log_file)
            @test any(contains("Info  [Main] worker record"), lines)
            @test !any(contains("hidden worker record"), lines)
        finally
            rmprocs(pid)
        end
    end
end
