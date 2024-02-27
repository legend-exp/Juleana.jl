# kill all open sessions at end of the script
function kill_sessions()
    @info "Kill all sessions"
    # kill all sessions
    rmprocs(workers()...)
    sleep(5)
    # kill all workers
    # run(`pkill -u $(ENV["USER"]) -f worker`)
end


function get_totalTimer(result::NamedTuple)
    totalTimer = TimerOutput()
    for (key, value) in result
        if key isa Symbol && occursin("timer", string(key))
            merge!(totalTimer, value)
        end
    end
    totalTimer
end