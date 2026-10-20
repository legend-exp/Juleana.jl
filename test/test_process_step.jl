# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Juleana
using Juleana: @process_step, ProcessStepError
using Test
using Logging
using Base.ScopedValues: with
using LegendDataManagement: DetectorId, FileKey, ProcessStatus

@testset "process_step" begin
    @testset "value and scope" begin
        function assigns(x)
            declared = 0
            value = @process_step "assign" begin
                declared = x + 1
                inner = 2x
                declared + inner
            end
            return value, declared, @isdefined(inner)
        end
        @test assigns(1) == (4, 2, false)

        function fails_after_assigning()
            declared = 0
            try
                @process_step "fails" begin
                    declared = 1
                    error("boom")
                end
            catch
            end
            return declared
        end
        @test (@test_logs (:error,) fails_after_assigning()) == 1
    end

    @testset "error and log" begin
        e_type = :e_cusp
        err = @test_logs (:error, "e_cusp simple calibration failed: ErrorException(\"no peaks\")") try
            @process_step "$e_type simple calibration" begin
                error("no peaks")
            end
        catch e
            e
        end
        @test err isa ProcessStepError
        @test err.name == "e_cusp simple calibration"
        @test err.item === nothing
        @test err.exception == ErrorException("no peaks")
        @test string(err) == "e_cusp simple calibration: ErrorException(\"no peaks\")"
        @test Juleana.root_exception(err) === err
        @test truncate_error(err) == "e_cusp simple calibration: ErrorException(\"no peaks\")"

        # the root exception of a wrapped failure is reported
        wrapped = @test_logs (:error, "spawned failed: ErrorException(\"inner\")") try
            @process_step "spawned" begin
                wait(Threads.@spawn error("inner"))
            end
        catch e
            e
        end
        @test wrapped.exception == ErrorException("inner")
    end

    @testset "nested steps log once" begin
        nested() = @process_step "outer" begin
            @process_step "middle" begin
                @process_step "inner" begin
                    throw(ArgumentError("bad window"))
                end
            end
        end
        err = @test_logs (:error, "inner failed: ArgumentError(\"bad window\")") try nested() catch e; e end
        @test err.name == "inner"
        @test err.exception == ArgumentError("bad window")
    end

    @testset "detector of the item" begin
        row = (detector = DetectorId(:V00048B), usability = :on, channel = 1)
        err = @test_logs (:error, "fit failed for V00048B: ErrorException(\"x\")") try
            with(Juleana.CURRENT_ITEM => row) do
                @process_step "fit" error("x")
            end
        catch e
            e
        end
        @test err.item === row

        # through `parallel`, the failure reaches the log table as "<name>: <error>"
        DetLog = NamedTuple{(:Detector, :usability, :Status, :X, :Error)}
        result = with_logger(NullLogger()) do
            Juleana.parallel([row], DetLog) do r
                @process_step "fit" error("x")
            end
        end
        @test only(result).second.log.Error == "fit: ErrorException(\"x\")"

        fk = FileKey("l200-p03-r000-cal-20230311T235840Z")
        FkLog = NamedTuple{(:Filekey, :Status, :A, :B, :Error)}
        logger = Test.TestLogger()
        with_logger(logger) do
            Juleana.parallel(k -> (@process_step "load" error("missing file")), [fk], FkLog)
        end
        @test only(filter(r -> r.level == Logging.Error, logger.logs)).message == "load failed: ErrorException(\"missing file\")"
    end

    @testset "log location" begin
        logger = Test.TestLogger()
        line = @__LINE__() + 2
        with_logger(logger) do
            try @process_step "located" error("x") catch end
        end
        record = only(logger.logs)
        @test record.file == @__FILE__
        @test record.line == line
    end
end
