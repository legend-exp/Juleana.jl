# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Juleana
using Test

@testset "processor graph" begin
    rspec(name, rank; deps = Symbol[]) = ProcessorSpec(; name, level = :run, category = :cal, rank, dependencies = deps)
    pspec(name, rank; deps = Symbol[]) = ProcessorSpec(; name, level = :partition, category = :cal, rank, dependencies = deps)
    kind(g, u, v) = get(g.kinds, (findfirst(==(u), g.names), findfirst(==(v), g.names)), nothing)
    # every edge of the given kinds goes from a lower to a higher layer, and the positions
    # of each layer are 1:n
    function valid_layout(g, layout; kinds = (:declared, :order))
        edges_ok = all(((u, v),) -> !(g.kinds[(u, v)] in kinds) || first(layout[u]) < first(layout[v]), keys(g.kinds))
        layers_ok = all(unique(first.(layout))) do l
            sort([p for (k, p) in layout if k == l]) == 1:count(x -> first(x) == l, layout)
        end
        return edges_ok && layers_ok
    end

    @testset "chain within a level" begin
        g = processor_graph([rspec(:c, 3), rspec(:a, 1), rspec(:b, 2)])
        @test topological_order(g) == [:a, :b, :c]
        @test kind(g, :a, :b) === :order && kind(g, :b, :c) === :order && isnothing(kind(g, :a, :c))
        # ordered steps do not require each other
        @test required_processors(g, [:c]) == Set([:c])
        layout = layered_layout(g)
        @test [first(layout[findfirst(==(n), g.names)]) for n in (:a, :b, :c)] == [1, 2, 3]
        @test valid_layout(g, layout)
        # equal ranks are ordered by name, as `run_steps` does
        @test topological_order(processor_graph([rspec(:y, 1), rspec(:x, 1)])) == [:x, :y]
    end

    @testset "cross-level dependencies" begin
        specs = [rspec(:r1, 1), rspec(:r2, 2), rspec(:r3, 3; deps = [:p2]), pspec(:p1, 1; deps = [:r2]), pspec(:p2, 2)]
        g = processor_graph(specs)
        @test kind(g, :r2, :p1) === :declared
        # waiting for r2 means waiting for every run step ranked up to r2
        @test kind(g, :r1, :p1) === :implied
        @test kind(g, :p2, :r3) === :declared && kind(g, :p1, :r3) === :implied
        @test kind(g, :p1, :p2) === :order
        @test required_processors(g, [:r3]) == Set([:r3, :p2, :p1, :r2, :r1])
        @test required_processors(g, [:p2]) == Set([:p2])
        @test dependent_processors(g, [:r2]) == Set([:r2, :p1, :r3])
        @test dependent_processors(g, [:p2]) == Set([:p2, :r3])
        @test dependent_processors(g, [:r3]) == Set([:r3])
        @test all(a -> all(b -> (b in required_processors(g, [a])) == (a in dependent_processors(g, [b])), g.names), g.names)
        order = topological_order(g)
        for ((u, v), _) in g.kinds
            @test findfirst(==(g.names[u]), order) < findfirst(==(g.names[v]), order)
        end
        @test valid_layout(g, layered_layout(g))
        @test valid_layout(g, layered_layout(g; kinds = Juleana.EDGE_KINDS); kinds = Juleana.EDGE_KINDS)
        @test_throws "unknown edge kind" layered_layout(g; kinds = (:bogus,))
    end

    @testset "a declared edge is not weakened by a rank order" begin
        # p2 depends on r1, and r1 is ranked before r2, which p2 also waits for
        g = processor_graph([rspec(:r1, 1), rspec(:r2, 2), pspec(:p2, 1; deps = [:r2, :r1])])
        @test kind(g, :r1, :p2) === :declared && kind(g, :r2, :p2) === :declared
        @test kind(g, :r1, :r2) === :order
    end

    @testset "diamond" begin
        g = processor_graph([rspec(:a, 1), pspec(:b, 1; deps = [:a]), pspec(:c, 2; deps = [:a]), rspec(:d, 2; deps = [:c])])
        @test required_processors(g, [:d]) == Set([:a, :b, :c, :d])
        layout = layered_layout(g)
        @test valid_layout(g, layout)
        @test first(layout[findfirst(==(:d), g.names)]) == 4
    end

    @testset "cycles and bad input" begin
        # r2 waits for p1, which waits for r2 through r3's rank
        @test_throws "form a cycle" processor_graph([rspec(:r2, 2; deps = [:p1]), rspec(:r3, 3), pspec(:p1, 1; deps = [:r3])])
        err = try
            processor_graph([rspec(:r1, 1; deps = [:p1]), pspec(:p1, 1; deps = [:r1]), rspec(:r0, 0)])
        catch e
            e
        end
        @test err isa ArgumentError && occursin("p1, r1", err.msg) && !occursin("r0", err.msg)
        @test_throws "unknown processor `nope`" processor_graph([rspec(:r1, 1; deps = [:nope])])
        @test_throws "must be unique" processor_graph([rspec(:r1, 1), pspec(:r1, 1)])
        @test_throws "form a cycle" ProcessingConfig(; processors = Dict(:r1 => rspec(:r1, 1; deps = [:p1])),
            p_processors = Dict(:p1 => pspec(:p1, 1; deps = [:r1])))
    end

    @testset "configs and snapshot entries" begin
        cfg = ProcessingConfig(joinpath(dirname(@__DIR__), "config", "processing_config.json"))
        g = processor_graph(cfg)
        @test Set(g.names) == union(keys(cfg.processors), keys(cfg.p_processors))
        @test !Juleana.Graphs.is_cyclic(g.graph)
        @test valid_layout(g, layered_layout(g))
        # any objects with name, level, rank and dependencies work, e.g. snapshot entries
        entries = [(; name = :a, level = :run, rank = 1, dependencies = Symbol[]),
            (; name = :b, level = :partition, rank = 1, dependencies = [:a])]
        @test topological_order(processor_graph(entries)) == [:a, :b]
    end
end
