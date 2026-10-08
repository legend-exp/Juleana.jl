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
    register_processor!(name::Symbol, f)

Add the processor function `f` to [`PROCESSORS`](@ref) under `name` and return `f`.
Throw an `ArgumentError` when `name` is already registered or differs from
`nameof(f)`.
"""
function register_processor!(name::Symbol, f)
    nameof(f) == name ||
        throw(ArgumentError("register_processor!: name `$name` does not match function name `$(nameof(f))`"))
    haskey(PROCESSORS, name) &&
        throw(ArgumentError("register_processor!: processor `$name` is already registered"))
    PROCESSORS[name] = f
    return f
end
