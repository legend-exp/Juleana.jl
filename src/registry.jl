# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

"""
    PROCESSORS::Dict{Symbol,Function}

Registry of the processor functions of the dataflow, keyed by processor name. The
names are the keys of the `processors` and `p_processors` tables of a processing
config. Every file in `src/processors/` adds its processor with
[`register_processor!`](@ref) when the module is defined.
"""
const PROCESSORS = Dict{Symbol,Function}()

"""
    register_processor!(f)

Add the processor function `f` to [`PROCESSORS`](@ref) under `nameof(f)` and return `f`.
Throw an `ArgumentError` when a processor of that name is already registered.
"""
function register_processor!(f)
    name = nameof(f)
    haskey(PROCESSORS, name) &&
        throw(ArgumentError("register_processor!: processor `$name` is already registered"))
    PROCESSORS[name] = f
    return f
end
