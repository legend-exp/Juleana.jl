# The mirror sits beside the dataflow checkout, so a production's relative
# layout is the same here as on the remote.
const DEFAULT_LOCAL_ROOT = normpath(joinpath(@__DIR__, "..", "..", "..", "data"))
const DEFAULT_SELECTION_DIR = normpath(joinpath(@__DIR__, "..", "..", "config", "sync"))

"""
    Options

The parsed command line. `mount_root` and `from` are `nothing` when the flag was
not given; every other field always has a value.
"""
struct Options
    host::String
    remote_root::String
    local_root::String
    mount_root::Union{Nothing,String}
    production::String
    out::String
    from::Union{Nothing,String}
    dry_run::Bool
    yes::Bool
end

"""
    parse_options(args::AbstractVector{<:AbstractString})::Options
"""
function parse_options(args::AbstractVector{<:AbstractString})
    settings = ArgParseSettings(
        prog = "juleana sync",
        description = "Mirror part of a remote LEGEND data production into a local " *
                      "directory that LegendDataManagement can open unchanged.")
    @add_arg_table settings begin
        "--host"
            help = "ssh alias of the machine holding the production"
            arg_type = String
            default = "cslg4"
        "--remote-root"
            help = "remote directory holding the productions"
            dest_name = "remote_root"
            arg_type = String
            default = "/mnt/scratch/projects/legend/data/l200"
        "--local-root"
            help = "local directory mirroring the remote root"
            dest_name = "local_root"
            arg_type = String
            default = DEFAULT_LOCAL_ROOT
        "--mount-root"
            help = "where the remote root is mounted; enables link mode"
            dest_name = "mount_root"
            arg_type = String
            default = ""
        "--production"
            help = "production to sync"
            arg_type = String
            default = "test"
        "--out"
            help = "where the interface saves the selection"
            arg_type = String
            default = ""
        "--from"
            help = "apply a saved selection without starting the interface"
            arg_type = String
            default = ""
        "--dry-run"
            help = "with --from: ask rsync what would move and print it"
            dest_name = "dry_run"
            action = :store_true
        "--yes"
            help = "with --from: transfer without asking"
            action = :store_true
    end
    parsed = parse_args(args, settings)

    from = isempty(parsed["from"]) ? nothing : parsed["from"]
    (from === nothing && (parsed["dry_run"] || parsed["yes"])) && throw(ArgumentError(
        "--dry-run and --yes only mean something together with --from"))
    mount = isempty(parsed["mount_root"]) ? nothing : abspath(parsed["mount_root"])
    out = isempty(parsed["out"]) ?
          joinpath(DEFAULT_SELECTION_DIR, parsed["production"] * ".json") : parsed["out"]

    # check_mount compares a path's device with its parent's, which only works
    # for an absolute path; --remote-root feeds path arithmetic that assumes
    # the same.
    Options(parsed["host"], abspath(parsed["remote_root"]), abspath(parsed["local_root"]),
            mount, parsed["production"], out, from, parsed["dry_run"], parsed["yes"])
end

"""
    main(args::AbstractVector{<:AbstractString})::Int
    main(options::Options, host::RemoteHost = SSHHost(options.host))::Int

Run the tool and return the process exit code. Every failure is thrown; a
nonzero return means the tool declined the request, not that it hid an error.
"""
main(args::AbstractVector{<:AbstractString}) = main(parse_options(args))

main(options::Options, host::RemoteHost = SSHHost(options.host)) =
    options.from === nothing ? run_tui(options, host) : run_headless(options, host)

"""
    run_headless(options::Options, host::RemoteHost)::Int

Apply a saved selection without starting the interface. The estimate is always
shown first; `--yes` skips the question that follows it, `--dry-run` stops there.
Returns 1 when the user answers no.
"""
function run_headless(options::Options, host::RemoteHost)
    production = Production(host, options.production, options.remote_root,
                            options.local_root; mount_root = options.mount_root)
    selection = load_selection(options.from, production)

    println(format_estimate(apply!(host, production, selection; dry_run = true)))
    options.dry_run && return 0

    if !options.yes
        print("transfer? [y/N] ")
        startswith(lowercase(readline()), "y") || return 1
    end

    result = apply!(host, production, selection; progress = function (p)
        print("\r", format_bytes(p.bytes), "  ", round(Int, 100 * p.fraction), "%  ",
              p.rate, "  ETA ", p.eta, "   ")
    end)
    println()
    println(summary_text(result))
    0
end
