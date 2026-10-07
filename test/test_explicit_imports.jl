# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

import Test
import ExplicitImports
import Juleana

Test.@testset "ExplicitImports" begin
    # The Logging interface methods are documented extension points but are not
    # marked public in the Logging stdlib.
    ExplicitImports.test_explicit_imports(
        Juleana;
        ignore = (:catch_exceptions, :handle_message, :min_enabled_level, :shouldlog)
    )
end # testset
