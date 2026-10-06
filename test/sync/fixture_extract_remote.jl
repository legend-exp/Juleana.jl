"""
    make_extract_remote()::String

A miniature remote root in a temporary directory with real HDF5 tier files: the
production `xprod` holds two `jldsp` runs (three detector-like groups per file) and
one `jlevt` run (a single group named after the tier). It is separate from the
committed fixture so that the tests of the other modules keep their file counts.
"""
function make_extract_remote()
    root = mktempdir()
    prod = joinpath(root, "xprod")
    mkpath(joinpath(prod, "legend-metadata"))
    write(joinpath(prod, "legend-metadata", "README.md"), "metadata\n")
    write(joinpath(prod, "config.json"), raw"""
    {"setups": {"l200": {"paths": {"metadata": "$_/legend-metadata/", "tier": "$_/generated/tier/"}}}}
    """)
    tier = joinpath(prod, "generated", "tier")
    dsp(run, ts, scale) = write_lh5(joinpath(tier, "jldsp", "cal", "p18", run,
        "l200-p18-$run-cal-$ts-tier_jldsp.lh5"); scale)
    dsp("r000", "20251107T191821Z", 1)
    dsp("r000", "20251107T192416Z", 2)
    dsp("r001", "20251108T101010Z", 1)
    for ts in ("20251107T191821Z", "20251107T192416Z")
        write_lh5(joinpath(tier, "jlevt", "phy", "p18", "r000",
                           "l200-p18-r000-phy-$ts-tier_jlevt.lh5");
                  groups = ["jlevt"], inner = "tables")
    end
    root
end
