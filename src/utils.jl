# kill all open sessions at end of the script
function kill_sessions()
    @info "Kill all sessions"
    # kill all sessions
    rmprocs(workers()...)
    run(`pkill -u $(ENV["USER"]) -f worker`)
end