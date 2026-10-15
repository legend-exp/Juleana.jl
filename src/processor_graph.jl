# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

# Kinds of edges of a `ProcessorGraph`, strongest first: a step of both an edge of a
# stronger and of a weaker kind keeps the stronger one.
const EDGE_KINDS = (:declared, :implied, :order)

"""
    ProcessorGraph

Dependency graph of the run-level and partition-level processors of a configuration, as
returned by [`processor_graph`](@ref).

Node `i` is the processor `names[i]` of level `levels[i]` (`:run` or `:partition`) and
rank `ranks[i]`. An edge `u → v` of `graph` (a `Graphs.SimpleDiGraph`) means that `u`
must finish before `v`, in a period, starts; `kinds[(u, v)]` says why:

- `:declared`: `v` names `u` in its `dependencies`.
- `:implied`: `v` names a processor of `u`'s level ranked at or after `u`, and
  [`run_processing`](@ref) waits for all processors of a level up to the named one.
- `:order`: `u` and `v` are processors of the same level with `v` next in rank order;
  the steps of a level run one after another in this order.

Edges of the kinds `:declared` and `:implied` are requirements: [`required_processors`](@ref)
follows them. `:order` edges only order the processors that are selected together.
"""
struct ProcessorGraph
    names::Vector{Symbol}
    levels::Vector{Symbol}
    ranks::Vector{Int}
    graph::Graphs.SimpleDiGraph{Int}
    kinds::Dict{Tuple{Int,Int},Symbol}
end

"""
    processor_graph(cfg::ProcessingConfig)
    processor_graph(specs)

Return the [`ProcessorGraph`](@ref) of all processors of `cfg`, enabled or not, or of
`specs`, an iterable of objects with the properties `name`, `level` (`:run` or
`:partition`), `rank` and `dependencies` like [`ProcessorSpec`](@ref).

Throws an `ArgumentError` if a processor name occurs twice, a dependency names an unknown
processor, or the edges form a cycle: processing would then wait forever. The error names
the processors of the cycle.
"""
processor_graph(cfg::ProcessingConfig) = processor_graph(vcat(collect(values(cfg.processors)), collect(values(cfg.p_processors))))

function processor_graph(specs)
    specs = collect(specs)
    names = [Symbol(s.name) for s in specs]
    allunique(names) || throw(ArgumentError("processor graph: processor names must be unique, got $(names)"))
    index = Dict(n => i for (i, n) in pairs(names))
    levels = [Symbol(s.level) for s in specs]
    ranks = [Int(s.rank) for s in specs]
    # processors of each level in run order, as `run_steps`/`partition_steps` sort them
    order = Dict(level => sort!([i for i in eachindex(names) if levels[i] === level]; by = i -> (ranks[i], names[i]))
        for level in unique(levels))

    kinds = Dict{Tuple{Int,Int},Symbol}()
    strength(kind) = findfirst(==(kind), EDGE_KINDS)
    function add!(u, v, kind)
        old = get(kinds, (u, v), kind)
        kinds[(u, v)] = strength(old) < strength(kind) ? old : kind
    end
    for (v, s) in pairs(specs), dep in s.dependencies
        u = get(index, Symbol(dep), nothing)
        isnothing(u) && throw(ArgumentError("processor graph: `$(names[v])` depends on unknown processor `$dep`"))
        add!(u, v, :declared)
        steps = order[levels[u]]
        for w in steps[firstindex(steps):findfirst(==(u), steps)]
            w == u || add!(w, v, :implied)
        end
    end
    for steps in values(order), k in firstindex(steps):lastindex(steps)-1
        add!(steps[k], steps[k+1], :order)
    end

    graph = Graphs.SimpleDiGraph(length(names))
    for (u, v) in keys(kinds)
        Graphs.add_edge!(graph, u, v)
    end
    if Graphs.is_cyclic(graph)
        cycles = filter(c -> length(c) > 1, Graphs.strongly_connected_components(graph))
        throw(ArgumentError("processor graph: the dependencies and ranks of these processors form a cycle, " *
            "so processing would wait forever: " * join((join(sort(names[c]), ", ") for c in cycles), "; ")))
    end
    return ProcessorGraph(names, levels, ranks, graph, kinds)
end

"""
    topological_order(g::ProcessorGraph)

Return the processor names of `g` in an order in which every processor comes after all
processors it waits for. Among processors that are free at the same point, run-level
processors come first, then lower rank, then name.
"""
topological_order(g::ProcessorGraph) = g.names[topological_nodes(g)]

function topological_nodes(g::ProcessorGraph)
    indegree = [length(Graphs.inneighbors(g.graph, v)) for v in Graphs.vertices(g.graph)]
    key(v) = (g.levels[v] === :run ? 0 : 1, g.ranks[v], g.names[v])
    free = sort!([v for v in Graphs.vertices(g.graph) if indegree[v] == 0]; by = key)
    result = Int[]
    while !isempty(free)
        v = popfirst!(free)
        push!(result, v)
        for w in Graphs.outneighbors(g.graph, v)
            indegree[w] -= 1
            indegree[w] == 0 && push!(free, w)
        end
        sort!(free; by = key)
    end
    return result
end

"""
    required_processors(g::ProcessorGraph, names)

Return the set of the processors in `names` together with all processors they require,
directly or through other required processors: the sources of `:declared` and
`:implied` edges, followed transitively. Processors that are only ordered before them
by rank are not added.
"""
function required_processors(g::ProcessorGraph, names)
    index = Dict(n => i for (i, n) in pairs(g.names))
    chosen = Set{Symbol}(Symbol.(names))
    todo = [index[n] for n in chosen]
    while !isempty(todo)
        v = pop!(todo)
        for u in Graphs.inneighbors(g.graph, v)
            g.kinds[(u, v)] === :order && continue
            g.names[u] in chosen || (push!(chosen, g.names[u]); push!(todo, u))
        end
    end
    return chosen
end

"""
    layered_layout(g::ProcessorGraph; kinds = (:declared, :order))

Place the processors of `g` in layers for drawing: return a vector with one `(layer,
position)` pair per node of `g`, both starting at 1. The layer of a processor is one more
than the highest layer of the processors it waits for through edges of the given
`kinds`, so these edges always point to a higher layer. Within a layer, processors are
ordered to reduce edge crossings: by the mean position of their neighbors in the layers
above, then below, a few times over.
"""
function layered_layout(g::ProcessorGraph; kinds = (:declared, :order))
    all(in(EDGE_KINDS), kinds) || throw(ArgumentError("layered_layout: unknown edge kind in $(kinds), expected some of $(EDGE_KINDS)"))
    use(u, v) = g.kinds[(u, v)] in kinds
    nodes = Graphs.vertices(g.graph)
    layer = ones(Int, length(nodes))
    for v in topological_nodes(g), u in Graphs.inneighbors(g.graph, v)
        use(u, v) && (layer[v] = max(layer[v], layer[u] + 1))
    end
    layers = [sort!([v for v in nodes if layer[v] == l]; by = v -> (g.levels[v] === :run ? 0 : 1, g.ranks[v], g.names[v]))
        for l in 1:maximum(layer; init = 0)]
    position = zeros(Int, length(nodes))
    renumber!(l) = foreach(((p, v),) -> position[v] = p, pairs(layers[l]))
    foreach(renumber!, eachindex(layers))
    for _ in 1:4, (range, neighbors) in ((2:length(layers), v -> filter(u -> use(u, v), Graphs.inneighbors(g.graph, v))),
            (length(layers)-1:-1:1, v -> filter(w -> use(v, w), Graphs.outneighbors(g.graph, v))))
        for l in range
            barycenter(v) = (ns = neighbors(v); isempty(ns) ? position[v] : sum(position[ns]) / length(ns))
            sort!(layers[l]; by = barycenter)
            renumber!(l)
        end
    end
    return [(layer[v], position[v]) for v in nodes]
end
