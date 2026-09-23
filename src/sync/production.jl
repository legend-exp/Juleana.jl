"""
    Production(h::RemoteHost, name, remote_root, local_root; mount_root = nothing)

A production of `remote_root` on `h`, together with the local directory that
mirrors it. Reading a production resolves its `config.json`: `\$_` expands to the
production's own directory and every resulting path must lie inside
`remote_root`, because a path outside it has no place in the mirror.

`raw_config` keeps the config as it was read. `config_local.json` is produced by
expanding `\$_` a second time, against the mirror, which needs the unexpanded text.
"""
struct Production
    name::String
    remote_root::String
    local_root::String
    mount_root::Union{Nothing,String}
    config::PropDict
    roots::Vector{Pair{String,String}}
    raw_config::String
end

function Production(h::RemoteHost, name::AbstractString,
                    remote_root::AbstractString, local_root::AbstractString;
                    mount_root::Union{Nothing,AbstractString} = nothing)
    root = rstrip(normpath(String(remote_root)), '/')
    dir = joinpath(root, String(name))
    raw = read_file(h, joinpath(dir, "config.json"))
    config = parse_production_config(raw, dir)
    mount = mount_root === nothing ? nothing : rstrip(normpath(String(mount_root)), '/')
    # Stripping the separator from the filesystem root leaves nothing behind.
    mount == "" && (mount = "/")
    Production(String(name), root, rstrip(normpath(String(local_root)), '/'),
               mount, config, production_roots(config, root), raw)
end

"""
    parse_production_config(json::AbstractString, config_dir::AbstractString)::PropDict

Parse a production `config.json` that was read as text, expanding `\$_` to
`config_dir`. Environment variables are not expanded: the config describes the
remote machine, so a variable resolved against this one would be a different path.
Any variable other than `_` is an error.
"""
function parse_production_config(json::AbstractString, config_dir::AbstractString)
    config = mktempdir() do dir
        path = joinpath(dir, "config.json")
        write(path, json)
        readprops(path; subst_pathvar = false, subst_env = false, trim_null = false)
    end
    PropDicts.substitute_vars!(PropDicts._dict(config),
                               Dict("_" => String(config_dir));
                               use_env = false, ignore_missing = false, recursive = true)
    config
end

"""
    production_roots(config::PropDict, remote_root::AbstractString)

The configured path keys and their absolute remote directories, sorted by key.
"""
function production_roots(config::PropDict, remote_root::AbstractString)
    setups = config.setups
    length(setups) == 1 || throw(ArgumentError(
        "a production config must contain exactly one setup, found $(length(setups)): " *
        join(string.(keys(setups)), ", ")))
    root = rstrip(normpath(String(remote_root)), '/')
    roots = Pair{String,String}[]
    for (key, value) in PropDicts._dict(only(values(setups)).paths)
        dir = rstrip(normpath(String(value)), '/')
        dir == root || startswith(dir, root * "/") || throw(ArgumentError(
            "path key $key resolves to $dir, which is outside the remote root $root and cannot be mirrored"))
        push!(roots, String(key) => dir)
    end
    sort!(roots; by = first)
end

"""
    relative(p::Production, remote_path)::String

`remote_path` expressed relative to the remote root — the form rsync's
`--files-from` list consumes. The remote root itself maps to `""`.
"""
function relative(p::Production, remote_path::AbstractString)
    path = rstrip(normpath(String(remote_path)), '/')
    root = rstrip(normpath(p.remote_root), '/')
    path == root && return ""
    startswith(path, root * "/") || throw(ArgumentError(
        "$path is not inside the remote root $root"))
    relpath(path, root)
end

"""
    to_local(p::Production, remote_path)::String

Where `remote_path` lives in the local mirror.
"""
to_local(p::Production, remote_path::AbstractString) =
    rstrip(normpath(joinpath(p.local_root, relative(p, remote_path))), '/')

"""
    to_mount(p::Production, remote_path)::String

Where `remote_path` appears under the mounted remote filesystem. Link mode needs
a mount root; without one there is nothing for a symlink to point at.
"""
function to_mount(p::Production, remote_path::AbstractString)
    p.mount_root === nothing && throw(ArgumentError(
        "no mount root configured; pass --mount-root to use link mode"))
    rstrip(normpath(joinpath(p.mount_root, relative(p, remote_path))), '/')
end

"""
    local_config(p::Production)::PropDict

The production's config with every path pointing into the mirror. `\$_` entries
are re-expanded against the mirrored production directory; entries that were
absolute remote paths are mapped through [`to_local`](@ref).
"""
function local_config(p::Production)
    config = parse_production_config(p.raw_config,
                                     to_local(p, joinpath(p.remote_root, p.name)))
    paths = PropDicts._dict(only(values(config.setups)).paths)
    prefix = rstrip(normpath(p.remote_root), '/') * "/"
    for (key, value) in collect(paths)
        dir = rstrip(normpath(String(value)), '/')
        # Every value is written back normalized. A "$_" entry already points into
        # the mirror and only needs its trailing separator dropped; an absolute
        # remote path is mapped across as well.
        paths[key] = startswith(dir, prefix) ? to_local(p, dir) : dir
    end
    config
end

"""
    write_local_config(p::Production)::String

Write `config_local.json` next to the mirrored `config.json` and return its path.
The mirrored `config.json` stays byte-identical to the remote one, so rsync never
sees it as locally modified.
"""
function write_local_config(p::Production)
    path = joinpath(p.local_root, p.name, "config_local.json")
    mkpath(dirname(path))
    writeprops(path, local_config(p))
    path
end
