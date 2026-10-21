# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

module JuleanaInfiltratorExt

import Infiltrator
import Juleana

# `run_step` with `debug = :infiltrate` or `pause` opens the Infiltrator prompt at its stops.
function __init__()
    Juleana.STOP_HOOK[] = Infiltrator.infiltrate
end

end # module JuleanaInfiltratorExt
