# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

const METADATA_URL = "git@github.com:legend-exp/legend-metadata"
const PRODUCTION_NAME = r"^[a-zA-Z0-9._-]+$"
const TIER_LABEL = r"^[a-zA-Z0-9_-]+$"
const BRANCH_NAME = r"^[a-zA-Z0-9._/][a-zA-Z0-9._/-]*$"
# folders of a new production below `generated/`
const GENERATED_DIRS = ("tier", "jllog", "jlplt", "jlreport", "jlpar", joinpath("jlpar", "rpars"), joinpath("jlpar", "ppars"))

# `git submodule foreach` scripts that check out `branch` in the metadata submodules: the
# `jldataprod` config and overrides submodules, and all others except those and the
# `simprod` config. `branch` matches `BRANCH_NAME`, so it is safe in the shell script.
jldataprod_checkout(branch) = """
    case "\$name" in
        jldataprod/config*|jldataprod/overrides*)
            git checkout '$branch' && git pull origin '$branch'
            ;;
    esac
    """
dataprod_checkout(branch) = """
    case "\$name" in
        jldataprod/config*|jldataprod/overrides*|simprod/config*)
            ;;
        *)
            git checkout '$branch' && git pull origin '$branch'
            ;;
    esac
    """

"""
    ProductionSpec(; name, parent, metadata_url = $(repr(METADATA_URL)), metadata_ref = nothing,
        jldataprod_branch = nothing, dataprod_branch = nothing, tier_paths = Pair{String,String}[], pars = String[],
        set_default = false, copy_software = true, shell = basename(get(ENV, "SHELL", "")),
        home = homedir())

What [`Juleana.create_production`](@ref) creates: the data production `name` in the folder
`parent` (an absolute path).

- `metadata_url`: the `legend-metadata` repository to clone.
- `metadata_ref`: branch or tag to check out in the metadata repository, with every
  submodule at the commit that ref records; `nothing` to keep the cloned default branch. The
  two branches below are checked out on top of it.
- `jldataprod_branch`: branch to check out in the `jldataprod/config*` and
  `jldataprod/overrides*` submodules of the metadata, `nothing` to keep the cloned ones.
- `dataprod_branch`: branch to check out in the metadata repository and all other
  submodules except `simprod/config*`, `nothing` to keep the cloned ones.
- `tier_paths`: `label => path` pairs of tiers kept in other folders, written to
  `config.json` as `tier/<label>`; each path must be an existing folder.
- `pars`: folders of parameters to copy into `generated/jlpar`; each path must contain a
  `/rpars` or `/ppars` component, and the part from there on is kept below `jlpar`.
- `set_default`: whether to set `LEGEND_DATA_CONFIG` to the new production in the startup
  file of the shell `shell` (`bash`: `.bashrc`, `zsh`: `.zshrc`) in `home`.
- `copy_software`: whether to copy the software of this process into the production (see
  [`Juleana.snapshot_software`](@ref)).
"""
Base.@kwdef struct ProductionSpec
    name::String
    parent::String
    metadata_url::String = METADATA_URL
    metadata_ref::Union{Nothing,String} = nothing
    jldataprod_branch::Union{Nothing,String} = nothing
    dataprod_branch::Union{Nothing,String} = nothing
    tier_paths::Vector{Pair{String,String}} = Pair{String,String}[]
    pars::Vector{String} = String[]
    set_default::Bool = false
    copy_software::Bool = true
    shell::String = basename(get(ENV, "SHELL", ""))
    home::String = homedir()
end

# The startup file of `shell` in `home`, `nothing` for an unsupported shell.
shell_rc_file(shell, home) = shell == "bash" ? joinpath(home, ".bashrc") : shell == "zsh" ? joinpath(home, ".zshrc") : nothing

"""
    Juleana.check_production(spec::ProductionSpec)

Return the folder of the production `spec` describes, after checking `spec` without
changing anything: the name contains only letters, digits, `.`, `_` and `-`, the parent is
an absolute path, the production folder does not exist, the branch names contain only
letters, digits, `.`, `_`, `/` and `-` and do not start with `-` (also the `metadata_ref`), every tier label is unique and
contains only letters, digits, `_` and `-`, every tier path and parameter folder exists,
every parameter folder has a `/rpars` or `/ppars` component, and with `set_default` the
shell is `bash` or `zsh`. Throws an `ArgumentError` that names the first problem.
"""
function check_production(spec::ProductionSpec)
    occursin(PRODUCTION_NAME, spec.name) ||
        throw(ArgumentError("the production name $(repr(spec.name)) may contain only letters, digits, '.', '_' and '-'"))
    isabspath(spec.parent) || throw(ArgumentError("the production folder must be an absolute path, got $(repr(spec.parent))"))
    path = joinpath(spec.parent, spec.name)
    ispath(path) && throw(ArgumentError("$path exists; remove it or choose another name"))
    for branch in (spec.metadata_ref, spec.jldataprod_branch, spec.dataprod_branch)
        isnothing(branch) || occursin(BRANCH_NAME, branch) ||
            throw(ArgumentError("the branch name $(repr(branch)) may contain only letters, digits, '.', '_', '/' and '-' and may not start with '-'"))
    end
    labels = first.(spec.tier_paths)
    allunique(labels) || throw(ArgumentError("tier labels must be unique, got $(join(labels, ", "))"))
    for (label, tier) in spec.tier_paths
        occursin(TIER_LABEL, label) ||
            throw(ArgumentError("the tier label $(repr(label)) may contain only letters, digits, '_' and '-'"))
        isdir(tier) || throw(ArgumentError("the path $tier of tier $label is not a folder"))
    end
    for pars in spec.pars
        isdir(pars) || throw(ArgumentError("the parameter folder $pars does not exist"))
        isnothing(pars_subpath(pars)) && throw(ArgumentError("the parameter folder $pars has no /rpars or /ppars component"))
    end
    spec.set_default && isnothing(shell_rc_file(spec.shell, spec.home)) &&
        throw(ArgumentError("cannot set the default production for the shell $(repr(spec.shell)); set LEGEND_DATA_CONFIG by hand"))
    return path
end

# The part of the parameter folder `pars` from its `/rpars` or `/ppars` component on.
function pars_subpath(pars)
    m = match(r"(/(?:rpars|ppars)(?:/.*)?)$", rstrip(pars, '/'))
    return isnothing(m) ? nothing : String(m[1])
end

# Run `cmd` and pass every line of its standard and error output to `log`; throw if it fails.
function run_logged(cmd::Cmd, log)
    out = Pipe()
    process = run(pipeline(cmd; stdout = out, stderr = out); wait = false)
    close(out.in)
    for line in eachline(out)
        log(line)
    end
    wait(process)
    success(process) || throw(ErrorException("$cmd failed with exit code $(process.exitcode)"))
    return nothing
end

"""
    Juleana.data_config_text(tier_paths, parent)

Return the text of the `config.json` of a new production: the paths of the `l200` setup
relative to the folder of the file (`\$_`), and after the `tier` path one `tier/<label>`
entry per pair of `tier_paths`. A path below `parent`, the folder that holds the
production, is written relative to it as `\$_/..`.
"""
function data_config_text(tier_paths, parent)
    tiers = join(("                \"tier/$label\": \"$(startswith(path, rstrip(parent, '/') * "/") ? "\$_/.." * path[length(rstrip(parent, '/'))+1:end] : path)\",\n"
        for (label, path) in tier_paths))
    return """
        {
            "setups": {
                "l200": {
                    "paths": {
                        "metadata": "\$_/legend-metadata/",

                        "tier": "\$_/generated/tier/",
        $(tiers)                "tier/jllog": "\$_/generated/jllog/",
                        "tier/jlrep": "\$_/generated/jlreport/",
                        "tier/jlplt": "\$_/generated/jlplt/",

                        "par": "\$_/generated/jlpar/"
                    }
                }
            }
        }
        """
end

"""
    Juleana.create_production(spec::ProductionSpec; log = line -> @info(line))

Create the data production `spec` describes and return the path of its data config file
`config.json`, which `LEGEND_DATA_CONFIG` names to use it. Checks `spec` first with
[`Juleana.check_production`](@ref), then

1. creates the production folder and clones the metadata with its submodules into
   `legend-metadata`; with `metadata_ref` it checks out that branch or tag and updates all
   submodules to the commits it records, then it checks out the other branches of `spec`,
2. creates the folders `generated/{tier,jllog,jlplt,jlreport,jlpar/rpars,jlpar/ppars}`,
3. writes `config.json` (see [`Juleana.data_config_text`](@ref)),
4. copies the parameter folders into `generated/jlpar`,
5. copies the software of this process into `software` (see
   [`Juleana.snapshot_software`](@ref)),
6. sets `LEGEND_DATA_CONFIG` in the shell startup file: replaces the lines that export it,
   or appends one.

`log` gets a line for every step and the output of `git`. A failing step throws and
leaves what was created so far.
"""
function create_production(spec::ProductionSpec; log = line -> @info(line))
    path = check_production(spec)
    mkpath(path)
    log("Created $path")
    metadata = joinpath(path, "legend-metadata")
    log("Cloning $(spec.metadata_url) into $metadata")
    run_logged(`git clone --recursive $(spec.metadata_url) $metadata`, log)
    run_logged(`git -C $metadata submodule init`, log)
    run_logged(`git -C $metadata submodule update`, log)
    if !isnothing(spec.metadata_ref)
        # A fresh clone is at the remote tip of every branch, so no pull is needed. `checkout`
        # creates a local branch from `origin/<ref>` and detaches HEAD at a tag.
        log("Checking out $(spec.metadata_ref) in the metadata")
        run_logged(`git -C $metadata -c advice.detachedHead=false checkout $(spec.metadata_ref)`, log)
        log("Updating the submodules to the commits of $(spec.metadata_ref)")
        run_logged(`git -C $metadata submodule update --init --recursive`, log)
    end
    if !isnothing(spec.jldataprod_branch)
        log("Checking out $(spec.jldataprod_branch) in the jldataprod config and overrides submodules")
        run_logged(`git -C $metadata -c advice.detachedHead=false submodule foreach --recursive $(jldataprod_checkout(spec.jldataprod_branch))`, log)
    end
    if !isnothing(spec.dataprod_branch)
        log("Checking out $(spec.dataprod_branch) in the metadata and its other submodules")
        run_logged(`git -C $metadata checkout $(spec.dataprod_branch)`, log)
        run_logged(`git -C $metadata pull origin $(spec.dataprod_branch)`, log)
        run_logged(`git -C $metadata -c advice.detachedHead=false submodule foreach --recursive $(dataprod_checkout(spec.dataprod_branch))`, log)
    end
    foreach(d -> mkpath(joinpath(path, "generated", d)), GENERATED_DIRS)
    log("Created the folders in $(joinpath(path, "generated"))")
    config = joinpath(path, "config.json")
    write(config, data_config_text(spec.tier_paths, spec.parent))
    log("Wrote $config")
    for pars in spec.pars
        dest = mkpath(joinpath(path, "generated", "jlpar", lstrip(pars_subpath(pars), '/')))
        for entry in readdir(pars)
            cp(joinpath(pars, entry), joinpath(dest, entry))
        end
        log("Copied $pars to $dest")
    end
    if spec.copy_software
        snapshot_software(joinpath(path, "software"); log)
    end
    if spec.set_default
        rc = shell_rc_file(spec.shell, spec.home)
        line = "export LEGEND_DATA_CONFIG=$(with_production_config(config))"
        lines = isfile(rc) ? readlines(rc) : String[]
        exports = findall(startswith("export LEGEND_DATA_CONFIG="), lines)
        isempty(exports) ? push!(lines, line) : (lines[exports] .= line)
        write(rc, join(lines, "\n") * "\n")
        log((isempty(exports) ? "Added" : "Updated") * " LEGEND_DATA_CONFIG in $rc")
    end
    return config
end

# Folders of a package folder that is not a git checkout that are not copied.
const SNAPSHOT_SKIP = (".git", joinpath("docs", "build"))

# Copy the package `src` to `dest` without its manifests: for a git checkout the files git
# tracks (as they are now) and the untracked files it does not ignore, else every file
# outside `SNAPSHOT_SKIP`.
function copy_package_tree(src, dest)
    files = String[]
    if isnothing(git_state(src))
        for (root, dirs, fs) in walkdir(src)
            # pruning `dirs` keeps `walkdir` out of the skipped folders
            filter!(d -> !(normpath(joinpath(relpath(root, src), d)) in SNAPSHOT_SKIP), dirs)
            append!(files, relpath.(joinpath.(root, fs), src))
        end
    else
        listed = split(read(`git -C $src ls-files -z --cached --others --exclude-standard`, String), '\0'; keepempty = false)
        append!(files, filter(f -> isfile(joinpath(src, f)), listed))
    end
    for f in files
        dirname(f) == "" && startswith(f, "Manifest") && endswith(f, ".toml") && continue
        mkpath(dirname(joinpath(dest, f)))
        cp(joinpath(src, f), joinpath(dest, f); follow_symlinks = true)
    end
    return dest
end

# `(; commit, modified)` of the git checkout `dir`, or `nothing` if it is not one.
function git_state(dir)
    isdir(joinpath(dir, ".git")) || isfile(joinpath(dir, ".git")) || return nothing
    commit = strip(read(`git -C $dir rev-parse HEAD`, String))
    modified = !isempty(strip(read(`git -C $dir status --porcelain`, String)))
    return (; commit, modified)
end

"""
    Juleana.running_manifest()

Return the path of the manifest of the environment this process loaded Juleana from: the
first environment of `Base.load_path()` whose manifest has a `Juleana` entry. Throws an
`ErrorException` if there is none.
"""
function running_manifest()
    for project in Base.load_path()
        isfile(project) || continue
        dir = dirname(project)
        for name in ("Manifest-v$(VERSION.major).$(VERSION.minor).toml", "Manifest.toml")
            manifest = joinpath(dir, name)
            isfile(manifest) && haskey(get(TOML.parsefile(manifest), "deps", Dict()), "Juleana") && return manifest
        end
    end
    throw(ErrorException("running_manifest: no environment of the load path has Juleana in its manifest"))
end

"""
    Juleana.snapshot_software(dest::AbstractString; manifest = Juleana.running_manifest(),
        source = pkgdir(Juleana), log = line -> @info(line))

Copy the software of this process to the folder `dest`, so that it can be installed again
with `Pkg.Apps.develop(path = "<dest>/Juleana.jl")`:

- the package `source` of Juleana to `dest/Juleana.jl`: for a git checkout the files git
  tracks, with their uncommitted changes, and the untracked files it does not ignore, else
  every file except `.git` and `docs/build`; its own manifests are not copied;
- every other package that `manifest` takes from a path (developed packages) to
  `dest/<name>`, likewise;
- `manifest` to `dest/Juleana.jl/Manifest.toml`, with the Juleana entry taken from `.`
  and the copied packages from `../<name>`, so that every package keeps its version;
- `dest/PROVENANCE.md`: the date, user and host, the Julia version, and for each copied
  package its source folder and, for a git checkout, its commit and whether it had
  uncommitted changes, which the copy includes.

Returns `dest`. Throws if `dest` exists.
"""
function snapshot_software(dest::AbstractString; manifest = running_manifest(), source = pkgdir(Juleana),
        log = line -> @info(line))
    ispath(dest) && throw(ArgumentError("snapshot_software: $dest exists"))
    data = TOML.parsefile(manifest)
    deps = data["deps"]
    copies = Pair{String,String}["Juleana" => source]
    for (name, entries) in deps, entry in entries
        name != "Juleana" && haskey(entry, "path") || continue
        path = entry["path"]
        push!(copies, name => (isabspath(path) ? path : normpath(joinpath(dirname(manifest), path))))
    end
    lines = ["# Software of this production", "",
        "Copied $(Dates.format(now(UTC), HISTORY_TIME_FORMAT)) UTC by $(get(ENV, "USER", "unknown"))@$(gethostname()) " *
            "with Julia $VERSION. Install it with `Pkg.Apps.develop(path = \"<this folder>/Juleana.jl\")`.", "",
        "| Package | Source | Commit | Uncommitted changes |", "|---|---|---|---|"]
    for (name, path) in copies
        target = joinpath(dest, name == "Juleana" ? "Juleana.jl" : name)
        copy_package_tree(path, target)
        state = git_state(path)
        push!(lines, "| $name | $path | $(isnothing(state) ? "–" : state.commit) | $(isnothing(state) ? "–" : state.modified ? "yes" : "no") |")
        log("Copied $name from $path to $target")
    end
    for (name, entries) in deps, entry in entries
        if name == "Juleana"
            foreach(k -> delete!(entry, k), ("git-tree-sha1", "repo-url", "repo-rev", "repo-subdir"))
            entry["path"] = "."
        elseif haskey(entry, "path")
            entry["path"] = "../$name"
        end
    end
    open(io -> TOML.print(io, data; sorted = true), joinpath(dest, "Juleana.jl", "Manifest.toml"), "w")
    write(joinpath(dest, "PROVENANCE.md"), join(lines, "\n") * "\n")
    log("Wrote $(joinpath(dest, "PROVENANCE.md"))")
    return dest
end

"""
    Juleana.software_version()

Return a one-line description of the software of this process for the processing
history: the Juleana version, and for a git checkout its short commit and `modified` if it
has uncommitted changes, and the Julia version.
"""
function software_version()
    state = git_state(pkgdir(Juleana))
    checkout = isnothing(state) ? "" : " (" * first(state.commit, 7) * (state.modified ? ", modified" : "") * ")"
    return "Juleana $(pkgversion(Juleana))$checkout, Julia $VERSION"
end
