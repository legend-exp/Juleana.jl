# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Juleana
using Juleana: @process_step, ProcessStepError
using Test
using Logging
using Base.ScopedValues: with
using LegendDataManagement: DataPeriod, DataRun, DetectorId, FileKey, ProcessStatus

# At top level, so that `Base.@locals` sees no variables of an enclosing scope
function capture_nested(x)
    outer = x
    @process_step "outer" begin
        mid = 2x
        @process_step "inner $x" begin
            inner_new = 3x
            error("boom")
        end
    end
end

module RerunTarget
    using Juleana: @process_step
    # visible only in this module, so a rerun must run in it
    above(values, threshold) = filter(>(threshold), values)
    function mean_above(values, threshold)
        @process_step "mean above $threshold" begin
            selected = above(values, threshold)
            isempty(selected) && error("nothing above $threshold")
            sum(selected) / length(selected)
        end
    end
end

function rerun_nested(x)
    @process_step "outer" begin
        y = @process_step "inner" sqrt(x)
        y > 2 || error("too small")
        y
    end
end

function rerun_continue()
    for i in 1:2
        @process_step "loop step" begin
            i == 2 && continue
            error("first")
        end
    end
end

rerun_context(fail) = @process_step "context" begin
    fail && error("x")
    (Juleana.WRITE_PARS[], Juleana.CURRENT_ITEM[])
end

# The single failure that `f()` captures, also as the failures of the last `run_step` call
function capture_failure(f, item = nothing)
    capture = (; step = :proc, args = (), failures = Juleana.Failure[], lock = ReentrantLock())
    with_logger(NullLogger()) do
        try with(f, Juleana.DEBUG_CAPTURE => capture, Juleana.CURRENT_ITEM => item) catch end
    end
    Juleana.LAST_FAILURES[] = capture.failures
    return only(capture.failures)
end

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

    @testset "capture" begin
        module_for_locals = Module()
        failures = Juleana.Failure[]
        capture = (; step = :proc, args = (DataPeriod(3), DataRun(1)), failures, lock = ReentrantLock())
        row = (detector = DetectorId(:V00048B), usability = :on)
        err = with_logger(NullLogger()) do
            try with(() -> capture_nested(5), Juleana.DEBUG_CAPTURE => capture, Juleana.CURRENT_ITEM => row) catch e; e end
        end
        @test err isa ProcessStepError
        # only the innermost step captures; the variables first assigned in it are not visible
        f = only(failures)
        @test propertynames(f) == (:mid, :outer, :x)
        @test (f.x, f.outer, f.mid) == (5, 5, 10)
        @test_throws "the failure of \"inner 5\" captured no variable `inner_new`; it captured mid, outer, x" f.inner_new
        info = Juleana.failure_info(f)
        @test info.name == "inner 5" && info.step == :proc && info.item === row && info.detector == DetectorId(:V00048B)
        @test info.exception == ErrorException("boom") && !isempty(info.backtrace)
        @test info.block isa Expr && info.file == @__FILE__
        @test Juleana.failure_variables(f) == Dict(:x => 5, :outer => 5, :mid => 10)
        @test sprint(show, f) == "Failure(\"inner 5\" for V00048B)"
        @test sprint(show, MIME"text/plain"(), f) == "\"inner 5\" failed for V00048B in proc p03 r001 at $(info.file):$(info.line)\n" *
            "  error: ErrorException(\"boom\")\n  variables: mid, outer, x"
        @test Juleana.define_locals(module_for_locals, f) == [:mid, :outer, :x]
        @test module_for_locals.mid == 10 && module_for_locals.x == 5
        @test occursin("2 failed `@process_step` captured", sprint(Juleana.print_failures, [f, f]))
        @test sprint(Juleana.print_failures, Juleana.Failure[]) == "run_step: no failed `@process_step` was captured\n"

        # without debug mode nothing is captured
        with_logger(NullLogger()) do
            try capture_nested(1) catch end
        end
        @test length(failures) == 1
    end

    @testset "rerun" begin
        f = capture_failure(() -> RerunTarget.mean_above([1, 2], 5))
        @test Juleana.failure_info(f).mod === RerunTarget
        # unchanged, it fails in the same way and replaces the failure
        @test_throws ErrorException("nothing above 5") with_logger(() -> Juleana.rerun(f), NullLogger())
        f2 = Juleana.failure()
        @test f2 !== f && only(Juleana.failures()) === f2 && Juleana.failure_info(f2).name == "mean above 5"
        @test f2.values == [1, 2]
        # an override fixes it
        @test Juleana.rerun(f2; values = [4, 6, 8]) == 7.0
        @test Juleana.rerun(f2; values = [1, 3], threshold = 0) == 2.0
        @test_throws "rerun: thresh is not a captured variable of \"mean above 5\"; the captured variables are threshold, values" Juleana.rerun(f2; thresh = 0)

        # a failed outer step with an inner one
        f = capture_failure(() -> rerun_nested(1))
        @test Juleana.failure_info(f).name == "outer" && propertynames(f) == (:x,)
        @test Juleana.rerun(f; x = 9) == 3.0

        # the item of the failure, and no parameters are written
        row = (detector = DetectorId(:V00048B), usability = :on)
        f = capture_failure(() -> rerun_context(true), row)
        @test Juleana.rerun(f; fail = false) == (false, row)

        f = capture_failure(rerun_continue)
        @test_throws "rerun: the block of \"loop step\" contains `continue`, which leaves the block" Juleana.rerun(f)
        @test Juleana.block_exit(:(return 1)) == "return"
        @test Juleana.block_exit(:(if a; break; end)) == "break"
        @test Juleana.block_exit(:(@goto done)) == "@goto"
        @test Juleana.block_exit(:(for i in 1:2; i == 1 && continue; break; end)) === nothing
        @test Juleana.block_exit(:(while true; break; end)) === nothing
        @test Juleana.block_exit(:(g(x) = return x)) === nothing
        @test Juleana.block_exit(:(map(x -> return x, 1:2))) === nothing
        @test Juleana.block_exit(:(function g(); return 1; end)) === nothing
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
