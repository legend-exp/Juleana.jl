# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Test
using Juleana
import Documenter

Documenter.DocMeta.setdocmeta!(
    Juleana,
    :DocTestSetup,
    :(using Juleana);
    recursive=true,
)
Documenter.doctest(Juleana)
