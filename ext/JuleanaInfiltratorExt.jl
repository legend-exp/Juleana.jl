# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

module JuleanaInfiltratorExt

import Infiltrator
import Juleana

# `run_step` with `debug = :infiltrate` or `pause` opens the Infiltrator prompt at its stops.
# Infiltrator refuses to stop in code that the REPL did not start, which includes code run
# from the VS Code editor; its check is switched off for the whole session.
function __init__()
    Infiltrator.toggle_async_check(false)
    Juleana.STOP_HOOK[] = Infiltrator.infiltrate
end

end # module JuleanaInfiltratorExt
