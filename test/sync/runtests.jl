using Test
using Dates
using PropDicts
using LegendDataManagement: LegendDataConfig, data_path
using Tachikoma: TestBackend, Frame, Rect, KeyEvent, GraphicsRegion, PixelSnapshot,
                 reset!, row_text, find_text, drain_tasks!, render_widget!

include(joinpath(@__DIR__, "..", "..", "src", "sync", "JuleanaSync.jl"))

# JuleanaSync exports nothing, so every name the tests use is named here. Each
# task appends the names from its Interfaces/Produces block to this line.
using .JuleanaSync: main,
    RemoteHost, SSHHost, LocalHost, DirEntry,
    run_remote, list_dir, dir_sizes, read_file, rsync_source,
    ssh_command, parse_dir_listing

# A fresh copy of the fixture per run: tests write into the mirror and must never
# touch the committed tree. The copy's absolute path is what `@REMOTE_ROOT@` and
# PropDicts' `$_` both have to resolve to, so it can only be known at run time.
const FIXTURE_ROOT = let dest = joinpath(mktempdir(), "remote")
    cp(joinpath(@__DIR__, "fixtures", "remote"), dest)
    template = read(joinpath(dest, "test", "config.json.in"), String)
    write(joinpath(dest, "test", "config.json"),
          replace(template, "@REMOTE_ROOT@" => dest))
    rm(joinpath(dest, "test", "config.json.in"))
    dest
end

const LOCAL_ROOT = mktempdir()

@testset "JuleanaSync" begin
    include("test_remote.jl")
end
