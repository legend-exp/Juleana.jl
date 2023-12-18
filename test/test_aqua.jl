# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

import Test
import Aqua
import Juleana

Test.@testset "Package ambiguities" begin
    Test.@test isempty(Test.detect_ambiguities(Juleana))
end # testset

Test.@testset "Aqua tests" begin
    Aqua.test_all(
        Juleana,
        ambiguities = true
    )
end # testset
