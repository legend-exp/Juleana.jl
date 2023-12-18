# Use
#
#     DOCUMENTER_DEBUG=true julia --color=yes make.jl local [nonstrict] [fixdoctests]
#
# for local builds.

using Documenter
using Juleana

using LegendTestData
using SolidStateDetectors

using BAT, LegendDSP, LegendDataManagement, LegendDataTypes, LegendEventAnalysis, LegendHDF5IO, LegendSpecFits, LegendTestData, LegendTextIO, RadiationDetectorDSP, RadiationDetectorSignals, RadiationSpectra, SolidStateDetectors

# Doctest setup
DocMeta.setdocmeta!(
    Juleana,
    :DocTestSetup,
    :(using BAT, Juleana, LegendDSP, LegendDataManagement, LegendDataTypes, LegendEventAnalysis, LegendHDF5IO, LegendSpecFits, LegendTestData, LegendTextIO, RadiationDetectorDSP, RadiationDetectorSignals, RadiationSpectra, SolidStateDetectors);
    recursive=true,
)

makedocs(
    sitename = "Juleana",
    modules = [LegendDSP, LegendDataManagement, LegendDataManagement.LDMUtils, LegendDataTypes, LegendEventAnalysis, LegendHDF5IO, LegendSpecFits, LegendTestData, LegendTextIO, RadiationDetectorDSP, RadiationDetectorSignals, RadiationSpectra],
    format = Documenter.HTML(
        prettyurls = !("local" in ARGS),
        canonical = "https://legend-exp.github.io/Juleana.jl/stable/"
    ),
    pages = [
        "Home" => "index.md",
        #"API" => "api.md",
        "Packages" => [
            "LegendDataManagement" => "packages/LegendDataManagement.md",
            "LegendDataTypes" => "packages/LegendDataTypes.md",
            "LegendHDF5IO" => "packages/LegendHDF5IO.md",
            "LegendTextIO" => "packages/LegendTextIO.md",
            "LegendDSP" => "packages/LegendDSP.md",
            "LegendSpecFits" => "packages/LegendSpecFits.md",
            "LegendEventAnalysis" => "packages/LegendEventAnalysis.md",
            "LegendTestData" => "packages/LegendTestData.md",
            "RadiationDetectorSignals" => "packages/RadiationDetectorSignals.md",
            "RadiationDetectorDSP" => "packages/RadiationDetectorDSP.md",
            "RadiationSpectra" => "packages/RadiationSpectra.md",
            #"SolidStateDetectors" => "packages/SolidStateDetectors.md",
        ],
        "Examples" => [
            "Detector Geometries" => "examples/detector_geometries.md",
        ],
        "LICENSE" => "LICENSE.md",
    ],
    doctest = ("fixdoctests" in ARGS) ? :fix : true,
    linkcheck = !("nonstrict" in ARGS),
    warnonly = ("nonstrict" in ARGS),
)

deploydocs(
    repo = "github.com/legend-exp/Juleana.jl.git",
    forcepush = true,
    push_preview = true,
)
