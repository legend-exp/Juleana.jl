# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Juleana
using Dates: Day, Minute, Second, UTC, now
using Test

# Wait until `cond()` holds, at most `timeout` seconds.
function wait_until(cond; timeout = 30)
    t0 = time()
    while !cond()
        time() - t0 > timeout && return false
        sleep(0.05)
    end
    return true
end

process_alive(pid) = success(ignorestatus(`kill -0 $pid`))

state_of(mgr, id) = only(filter(a -> a.id == id, Juleana.allocations(mgr))).state

@testset "worker allocations" begin
    production = mktempdir()
    script_file = joinpath(production, "config", "startjlworkers.sh")

    withenv("LEGEND_DATA_CONFIG" => joinpath(production, "config.json")) do
        @testset "local start script and allocations" begin
            mgr = Juleana.WorkerManager()
            @test_throws "no processing config is set" Juleana.start_script!(mgr)
            Juleana.set_worker_config!(mgr, ProcessingConfig(; processors = Dict(), p_processors = Dict(), local_n = 2))
            script = Juleana.start_script!(mgr)
            @test script.path == script_file
            @test read(script_file, String) == script.text
            @test occursin("xargs -n1 -P2", script.text) && occursin("elastic_worker", script.text)
            @test Juleana.start_script!(mgr) == script
            # a new config generates the script anew and keeps the previous file
            write(script_file, "edited")
            Juleana.set_worker_config!(mgr, ProcessingConfig(; processors = Dict(), p_processors = Dict(), local_n = 3))
            @test occursin("xargs -n1 -P3", Juleana.start_script!(mgr).text)
            @test read(script_file * ".bak", String) == "edited"

            # output and exit of the script
            Juleana.edit_start_script!(mgr, "echo out; echo err 1>&2")
            @test read(script_file, String) == "echo out; echo err 1>&2"
            ok = Juleana.add_workers!(mgr)
            @test ok.id == 1 && ok.backend === :local && isnothing(ok.job_name)
            @test wait_until(() -> state_of(mgr, 1) !== :running)
            a = only(Juleana.allocations(mgr))
            @test a.state === :ended && a.exit_code == 0 && !isnothing(a.finished)
            @test sort(a.output) == ["err", "out"]
            @test !haskey(only(Juleana.allocations(mgr; output = false)), :output)
            Juleana.edit_start_script!(mgr, "exit 3")
            Juleana.add_workers!(mgr)
            @test wait_until(() -> state_of(mgr, 2) !== :running)
            @test state_of(mgr, 2) === :failed && Juleana.allocations(mgr)[2].exit_code == 3

            # cancelling ends the whole process group of the script
            pidfile = joinpath(production, "child.pid")
            Juleana.edit_start_script!(mgr, "sleep 60 & echo \$! > $pidfile; echo started; wait")
            Juleana.add_workers!(mgr)
            @test wait_until(() -> isfile(pidfile) && !isempty(read(pidfile, String)))
            child = parse(Int, strip(read(pidfile, String)))
            @test process_alive(child)
            Juleana.cancel_allocation!(mgr, 3)
            @test state_of(mgr, 3) === :cancelled
            @test wait_until(() -> !process_alive(child))
            @test wait_until(() -> !isnothing(Juleana.allocations(mgr)[3].finished))
            @test state_of(mgr, 3) === :cancelled
            # cancelling an allocation that ended changes nothing
            Juleana.cancel_allocation!(mgr, 1)
            @test state_of(mgr, 1) === :ended
            @test_throws "there is no worker allocation 9" Juleana.cancel_allocation!(mgr, 9)

            rm(pidfile)
            Juleana.edit_start_script!(mgr, "sleep 60 & echo \$! > $pidfile; wait")
            Juleana.add_workers!(mgr)
            @test wait_until(() -> isfile(pidfile) && !isempty(read(pidfile, String)))
            child = parse(Int, strip(read(pidfile, String)))
            Juleana.cancel_all!(mgr)
            @test state_of(mgr, 4) === :cancelled
            @test wait_until(() -> !process_alive(child))
        end

        @testset "SLURM allocations" begin
            dir = mktempdir()
            # squeue lists jobs of this allocation, of another allocation of this process,
            # of another process and of another user's job name
            squeue = joinpath(dir, "squeue.sh")
            write(squeue, """
                echo "\$@" >> $dir/squeue.args
                echo "101 julia-$(getpid())-1"
                echo "102 julia-99999-1"
                echo "103 julia-$(getpid())-10"
                echo "104 interactive"
                """)
            scancel = joinpath(dir, "scancel.sh")
            write(scancel, "echo \"\$@\" >> $dir/scancel.args\n")
            sinfo = joinpath(dir, "sinfo.sh")
            write(sinfo, "echo \"sinfo \$@\"\n")
            mgr = Juleana.WorkerManager(; squeue = `bash $squeue`, scancel = `bash $scancel`, sinfo = `bash $sinfo`)
            Juleana.set_worker_config!(mgr, ProcessingConfig(; processors = Dict(), p_processors = Dict(), runmode = :slurm,
                slurm_flags = ["--ntasks=2"]))
            text = Juleana.start_script!(mgr).text
            @test occursin(r"srun --job-name=julia-\d+-\d+", text)
            @test_throws "must contain `--job-name=julia-<n>-<m>`" Juleana.edit_start_script!(mgr, "srun sleep 60")
            @test Juleana.start_script!(mgr).text == text

            Juleana.edit_start_script!(mgr, "echo --job-name=julia-1-1; sleep 60")
            alloc = Juleana.add_workers!(mgr)
            @test alloc.job_name == "julia-$(getpid())-1"
            @test wait_until(() -> !isempty(Juleana.allocations(mgr)[1].output))
            @test only(Juleana.allocations(mgr)[1].output) == "--job-name=julia-$(getpid())-1"
            Juleana.update_job_ids!(mgr)
            @test Juleana.allocations(mgr)[1].job_ids == ["101"]
            @test occursin("-u $(get(ENV, "USER", ""))", read(joinpath(dir, "squeue.args"), String))
            Juleana.cancel_allocation!(mgr, 1)
            # only the job of the allocation is cancelled
            @test read(joinpath(dir, "scancel.args"), String) == "101\n"
            @test state_of(mgr, 1) === :cancelled
            @test wait_until(() -> !isnothing(Juleana.allocations(mgr)[1].finished))
            # the overview runs squeue and sinfo
            overview = Juleana.workers_overview(Juleana.WorkerManager(; squeue = `bash $squeue`, scancel = `bash $scancel`, sinfo = `bash $sinfo`))
            @test occursin("julia-99999-1", overview.slurm.queue) && overview.slurm.idle == "sinfo -t idle\n"
            @test overview.script == "ArgumentError: start_script!: no processing config is set"
            @test isempty(overview.allocations) && overview.workers == []
            overview = Juleana.workers_overview(mgr)
            @test overview.script.path == script_file && only(overview.allocations).job_ids == ["101"]
            @test Juleana.workers_overview(Juleana.WorkerManager(; squeue = `juleana-no-such-command`)).slurm === nothing
            # the next allocation gets its own job name
            @test Juleana.add_workers!(mgr).job_name == "julia-$(getpid())-2"
            Juleana.cancel_all!(mgr)
            @test state_of(mgr, 2) === :cancelled
        end

        @testset "idle cancel" begin
            mgr = Juleana.WorkerManager()
            cfg(minutes) = ProcessingConfig(; processors = Dict(), p_processors = Dict(), idle_timeout_minutes = minutes)
            @test isnothing(Juleana.idle_deadline(mgr; processing = false))
            Juleana.set_worker_config!(mgr, cfg(2))
            Juleana.edit_start_script!(mgr, "sleep 60")
            # no countdown without a running allocation
            @test isnothing(Juleana.idle_deadline(mgr; processing = false))
            alloc = Juleana.add_workers!(mgr)
            deadline = Juleana.idle_deadline(mgr; processing = false)
            @test deadline == alloc.started + Minute(2)
            @test isnothing(Juleana.idle_deadline(mgr; processing = true))
            @test !Juleana.check_idle!(mgr; processing = false, time = deadline - Second(1))
            @test !Juleana.check_idle!(mgr; processing = true, time = deadline + Minute(5))
            # activity restarts the countdown; an earlier time does not
            Juleana.mark_activity!(mgr, deadline)
            Juleana.mark_activity!(mgr, alloc.started)
            @test Juleana.idle_deadline(mgr; processing = false) == deadline + Minute(2)
            @test !Juleana.check_idle!(mgr; processing = false, time = deadline + Second(119))
            @test Juleana.check_idle!(mgr; processing = false, time = deadline + Minute(2))
            @test state_of(mgr, 1) === :cancelled
            @test isnothing(Juleana.idle_deadline(mgr; processing = false))
            # `0` never cancels
            Juleana.set_worker_config!(mgr, cfg(0))
            Juleana.edit_start_script!(mgr, "sleep 60")
            Juleana.add_workers!(mgr)
            @test isnothing(Juleana.idle_deadline(mgr; processing = false))
            @test !Juleana.check_idle!(mgr; processing = false, time = now(UTC) + Day(1))
            Juleana.cancel_all!(mgr)
        end
    end
end
