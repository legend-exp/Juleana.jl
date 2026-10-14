# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

import Test

Test.@testset "Package Juleana" begin
    include("test_aqua.jl")
    include("test_explicit_imports.jl")
    include("test_juleana.jl")
    include("test_processing_config.jl")
    include("test_dataflow.jl")
    include("test_config.jl")
    include("test_generic_axes.jl")
    include("test_docs.jl")
    include("test_tui.jl")
end # testset
