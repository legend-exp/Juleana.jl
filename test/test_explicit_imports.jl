# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

import Test
import ExplicitImports
import Juleana

Test.@testset "ExplicitImports" begin
    # The Logging interface methods are documented extension points but are not
    # marked public in the Logging stdlib. `Base.kwarg_decl` is the only way to list
    # the keyword arguments a method declares (used by `check_processor_kwargs`).
    ExplicitImports.test_explicit_imports(
        Juleana;
        ignore = (:catch_exceptions, :handle_message, :min_enabled_level, :shouldlog, :kwarg_decl)
    )
end # testset
