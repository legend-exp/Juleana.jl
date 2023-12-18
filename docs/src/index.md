# Juleana.jl

Juleana.jl provides a Julia implementation of LEGEND global event analysis tools.

Juleana is a meta package that represents the LEGEND Julia software stack. This stack comprises (mainly) the following Julia packages:

* [LegendDataManagement](@ref)
* [LegendDataTypes](@ref)
* [LegendHDF5IO](@ref)
* [LegendTextIO](@ref)
* [LegendDSP](@ref)
* [LegendSpecFits](@ref)
* [LegendEventAnalysis](@ref)
* [LegendTestData](@ref)
* [RadiationDetectorSignals](@ref)
* [RadiationDetectorDSP](@ref)
* [SolidStateDetectors](@ref)
* [BAT](@ref)

Juleana depends on, imports and exports all the packages listed above.

*(As a consequence, any breaking version change in one of these package has to result in a breaking version change of the Juleana package itself.)*

So one can, for example, do (but **see caveats below**)


```julia
using Juleana

data = LegendDataManagement.LegendData(:l200)

using LegendHDF5IO
input = lh5open(...)
```

without (in this example) `import LegendDataManagement` and without adding LegendDataManagement and LegendHDF5IO to the dependencies (`Project.toml`) of the active project.

But: note that this approach is intended **only** for easy **interactive exploration** of the LEGEND Julia software stack and for convenient use in **scripts and notebooks**! Also note that due to it's heavy dependencies, using Juleana will result in longer load times than using only the individual packages that you need.

This approach must **not** be used **in packages**. Packages must not depend on Juleana at all, instead packages must only and directly depend on the packages they use! `using Juleana` and `import Juleana` have no place in package code and Juleana should **never** be added to package `Project.toml` files.
