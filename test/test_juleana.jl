# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Juleana
using Test
using Markdown
using Logging
using TerminalLoggers
# ParallelProcessingTools initializes a process by importing itself into Main; load it
# here so that initialization never has to resolve the package on its own.
import ParallelProcessingTools
using Base.ScopedValues: with
using LegendDataManagement: FileKey, DetectorId, ProcessStatus, DataPeriod, DataRun,
    process_succeeded, process_warning, process_failed

@testset "juleana" begin
    @testset "log underscores" begin
        message = Juleana.escape_log_underscores("process_dsp_cal and e_cusp_ctc; `already_quoted`")
        @test message == "process\\_dsp\\_cal and e\\_cusp\\_ctc; `already_quoted`"
        @test !any(x -> x isa Markdown.Italic, Markdown.parse(message).content[1].content)
        @test Juleana.escape_log_underscores("already\\_escaped") == "already\\_escaped"
        @test Juleana.escape_log_underscores("``code_with_underscores`` and a_b") == "``code_with_underscores`` and a\\_b"

        output = IOBuffer()
        with_logger(UnderscoreSafeLogger(TerminalLogger(output))) do
            @info "process_dsp_cal and e_cusp_ctc; `already_quoted`"
        end
        @test occursin("process_dsp_cal and e_cusp_ctc; already_quoted", String(take!(output)))
        for inner in (TerminalLogger(output), ConsoleLogger(output))
            @test Logging.catch_exceptions(UnderscoreSafeLogger(inner)) == Logging.catch_exceptions(inner)
        end
    end

    @testset "truncation" begin
        @test truncate_string("short", 10) == "short"
        @test truncate_string("αβγδε"^3, 4) == "αβγδ..."
        @test truncate_string(SubString("abcdef", 2), 3) == "bcd..."
        msg = truncate_error(CompositeException([ErrorException("x"^50), ErrorException("second")]), 10)
        @test endswith(msg, "...")
        @test length(msg) == 13
        @test !occursin("second", msg)
        @test truncate_string("abcdef", Int32(3)) == "abc..."
        @test length(truncate_error(ErrorException("x"^50), UInt8(10))) == 13
        failed = Threads.@spawn error("inner failure")
        wrapped = try; wait(failed); catch e; e; end
        @test wrapped isa TaskFailedException
        @test truncate_error(wrapped) == string(ErrorException("inner failure"))
        @test truncate_error(CompositeException([wrapped, ErrorException("second")])) == string(ErrorException("inner failure"))
    end

    @testset "utc_timestamp" begin
        @test occursin(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", Juleana.utc_timestamp())
    end

    @testset "legend_dsp_function" begin
        @test Juleana.legend_dsp_function("dsp_icpc_compressed", "dsp.x") === Juleana.LegendDSP.dsp_icpc_compressed
        @test_throws "dataprod config key `dsp.additional_detectors.V1` selects `dsp_nonexistent`, which LegendDSP does not define" Juleana.legend_dsp_function("dsp_nonexistent", "dsp.additional_detectors.V1")
    end

    @testset "report texts are internal" begin
        texts = filter(n -> endswith(string(n), "_log_text"), names(Juleana; all = true))
        @test length(texts) == 17
        @test all(n -> getfield(Juleana, n) isa String, texts)
        @test !any(n -> Base.isexported(Juleana, n) || Base.ispublic(Juleana, n), texts)
    end

    @testset "detector_status" begin
        @test occursin("color:green", detector_status(:on))
        @test occursin("color:yellow", detector_status(:ac))
        @test occursin("color:red", detector_status(:off))
        @test occursin("color:gray", detector_status(:unknown))
    end

    @testset "master_status" begin
        row(status) = (processed = true, log = (Status = status, usability = "-"))
        det(usability) = (detector = DetectorId(:V00048B), usability = usability)
        @test master_status([det(:on) => row(process_succeeded)]) == process_succeeded
        @test master_status([det(:off) => row(process_warning)]) == process_succeeded
        @test master_status([det(:ac) => row(process_warning)]) == process_warning
        @test master_status([det(:off) => row(process_failed)]) == process_warning
        @test master_status([det(:on) => row(process_warning)]) == process_failed
        @test master_status([det(:ac) => row(process_failed)]) == process_failed
        @test master_status(nothing, [det(:on) => row(process_succeeded)]) == process_succeeded
        @test master_status(Pair[]) == process_failed
    end

    fk = FileKey("l200-p03-r000-cal-20230311T235840Z")
    FkLog = NamedTuple{(:Filekey, :Status, :A, :B, :Error)}

    @testset "failure_log" begin
        @test failure_log(FkLog, fk, "boom") == FkLog((fk, ProcessStatus(0), "-", "-", "boom"))

        DetLog = NamedTuple{(:Detector, :usability, :Status, :X, :Error)}
        det = (detector = DetectorId(:V00048B), usability = :on, channel = 1)
        r = failure_log(DetLog, det, "boom")
        @test r.Detector == det.detector
        @test r.Status == ProcessStatus(0)
        @test r.X == "-"
        @test r.Error == "boom"

        PartLog = NamedTuple{(:Detector, :usability, :Partition, :Status, :X, :Error)}
        r = failure_log(PartLog, (; det..., partition = :p1), "boom")
        @test r.Partition == :p1
        @test r.X == "-"

        @test_throws "needs `detector` and `usability` fields" failure_log(DetLog, (channel = 1,), "boom")
    end

    @testset "parallel" begin
        ok = parallel(k -> (processed = true, log = FkLog((k, ProcessStatus(1), "a", "b", ""))), [fk], FkLog)
        @test only(ok).first == fk
        @test only(ok).second.processed
        @test only(ok).second.log.Status == process_succeeded

        failed = parallel(k -> error("item failed"), [fk], FkLog)
        @test !only(failed).second.processed
        @test only(failed).second.log == FkLog((fk, ProcessStatus(0), "-", "-", "ErrorException(\"item failed\")"))

        @test_throws "no failure_log method for items of type Int64" parallel(identity, [1, 2], FkLog)

        viaDo = parallel([fk], FkLog; process_name = "do-block") do k
            (processed = true, log = FkLog((k, ProcessStatus(1), "a", "b", "")))
        end
        @test viaDo == ok

        # The busy-worker label of a channel row is its detector, that of other items the item itself.
        DetLog = NamedTuple{(:Detector, :usability, :Status, :X, :Error)}
        row = (detector = DetectorId(:V00048B), usability = :on, channel = 1)
        store, key = Juleana.ProgressStore(), (DataPeriod(3), DataRun(0), :label_test)
        Juleana.reset_progress!(store, [key])
        labels = String[]
        # a stop flag makes the items go through the stoppable pool, which reports the busy worker
        with(Juleana.PROGRESS_STEP => (store, key), Juleana.PROCESSING_STOP => Threads.Atomic{Bool}(false)) do
            parallel([row], DetLog) do r
                push!(labels, only(Juleana.busy_workers(store)).item)
                (processed = true, log = DetLog((r.detector, r.usability, ProcessStatus(1), "-", "")))
            end
            parallel([fk], FkLog) do k
                push!(labels, only(Juleana.busy_workers(store)).item)
                (processed = true, log = FkLog((k, ProcessStatus(1), "a", "b", "")))
            end
        end
        @test labels == ["V00048B", string(fk)]

        # Without workers the item runs on the main process, which onworker does not terminate.
        slow = parallel(k -> (sleep(5); (processed = true,)), [fk], FkLog; timeout = 0.2)
        @test !only(slow).second.processed
        @test only(slow).second.log.Status == ProcessStatus(0)

        finished = Threads.Atomic{Int}(0)
        staggered = [Threads.@spawn sleep(0.05 * k) for k in 1:4]
        watcher = Threads.@spawn Juleana.watch_tasks(() -> Threads.atomic_add!(finished, 1), staggered; poll = 0.01)
        @test timedwait(() -> istaskdone(watcher), 10) === :ok
        @test finished[] == length(staggered)

        @test occursin("exceeds `timeout` seconds", string(@doc parallel))
    end

    @testset "wait_for" begin
        abort = Threads.Atomic{Bool}(false)
        @test isnothing(Juleana.wait_for(() -> true, "ready step"; abort, timeout = 1, poll = 0.01))

        flag = Threads.Atomic{Bool}(false)
        t = Threads.@spawn Juleana.wait_for(() -> flag[], "flagged step"; abort, timeout = 10, poll = 0.01)
        sleep(0.05)
        flag[] = true
        @test isnothing(fetch(t))

        @test_throws "Timed out after 0.05 s waiting for slow step" Juleana.wait_for(() -> false, "slow step"; abort, timeout = 0.05, poll = 0.01)
        abort[] = true
        @test_throws "Stopped waiting for blocked step: another processing task failed" Juleana.wait_for(() -> false, "blocked step"; abort, timeout = 10, poll = 0.01)
    end
end
