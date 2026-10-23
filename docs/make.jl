# Use
#
#     DOCUMENTER_DEBUG=true julia --color=yes make.jl local [nonstrict] [fixdoctests]
#
# for local builds.

using Documenter
using Juleana

# Doctest setup
DocMeta.setdocmeta!(Juleana, :DocTestSetup, :(using Juleana); recursive = true)

makedocs(sitename = "Juleana", modules = [Juleana], checkdocs = :exports,
         format = Documenter.HTML(prettyurls = !("local" in ARGS), canonical = "https://legend-exp.github.io/Juleana.jl/stable/"),
         pages = ["Home" => "index.md", "Running the dataflow" => "running.md", "Working in the REPL" => "repl.md",
                  "Configuration" => "configuration.md",
                  "Processors" => ["Overview" => "processors.md", "HPGe calibration" => "processors_hpge.md",
                                   "Pulse shape discrimination" => "processors_psd.md", "SiPMs, events and stability" => "processors_phy.md"],
                  "API" => ["Dataflow" => "api.md", "Steps, plots and logging" => "api_debug.md", "Terminal interface" => "api_tui.md"],
                  "LICENSE" => "LICENSE.md"], doctest = ("fixdoctests" in ARGS) ? :fix : true, linkcheck = !("nonstrict" in ARGS),
         warnonly = ("nonstrict" in ARGS))

deploydocs(repo = "github.com/legend-exp/Juleana.jl.git", forcepush = true, push_preview = true)
