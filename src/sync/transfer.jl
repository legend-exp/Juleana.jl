"""
    Progress(bytes, fraction, rate, eta)

One reading from `rsync --info=progress2`.
"""
struct Progress
    bytes::Int
    fraction::Float64
    rate::String
    eta::String
end

"""
    TransferResult

What an [`apply!`](@ref) did. `skipped` lists the link targets that were left
alone because real data already stood there. `warnings` holds rsync's standard
error text from the transfer, which is never discarded: GNU rsync can print a
warning (for example about a file that vanished mid-transfer) while still
exiting 0. It is `""` when rsync printed nothing.
"""
struct TransferResult
    bytes::Int
    files::Int
    links::Int
    replaced_links::Int
    skipped::Vector{String}
    config::String
    warnings::String
end

"""
    check_rsync()::VersionNumber

The version of the `rsync` on `PATH`, or an error explaining how to get a usable
one. Apple's openrsync has neither `--info=progress2` nor a `--stats` this tool
can read, so it is rejected by name rather than being discovered mid-transfer.
"""
function check_rsync()
    out = read(ignorestatus(`rsync --version`), String)
    line = String(first(eachsplit(out, '\n')))
    occursin("openrsync", line) && throw(ErrorException(
        "found Apple openrsync ($line), which has no --info=progress2 and no usable --stats. " *
        "Install GNU rsync with `brew install rsync` and put it ahead of /usr/bin in PATH."))
    m = match(r"rsync\s+version\s+([0-9]+(?:\.[0-9]+)+)", line)
    m === nothing && throw(ErrorException("cannot read an rsync version from: $line"))
    version = VersionNumber(m[1])
    version >= v"3.1" || throw(ErrorException(
        "rsync $version is too old; this tool needs 3.1 or newer. Install one with `brew install rsync`."))
    version
end

"""
    check_mount(p::Production)::String

The mount root, once it is known to be mounted: a readable directory whose
device differs from its parent's, or the filesystem root `/` itself. Link mode
points symlinks into a filesystem the user mounted; without it every link
would dangle from the moment it was created. A substring match against `mount`'s
output would accept an unmounted directory such as `/Volumes` whenever some
unrelated mounted path happens to contain it as a prefix, so the check instead
compares device numbers.
"""
function check_mount(p::Production)
    p.mount_root === nothing && throw(ArgumentError(
        "no mount root configured; pass --mount-root to use link mode"))
    isdir(p.mount_root) || throw(ArgumentError(
        "mount root $(p.mount_root) does not exist"))
    readdir(p.mount_root)  # throws on its own if the directory is not readable
    mounted = p.mount_root == "/" ||
              stat(p.mount_root).device != stat(dirname(p.mount_root)).device
    mounted || throw(ArgumentError(
        "mount root $(p.mount_root) is not a mount point; mount the remote filesystem there first"))
    p.mount_root
end

"""
    rsync_command(h::RemoteHost, p::Production, files_from; dry_run::Bool)::Cmd

The one rsync invocation the tool makes. `-r` is explicit because `--files-from`
switches off the recursion `-a` would imply, and without it a selected directory
arrives empty. `-l` copies a remote symlink (such as a `current` pointer) as a
symlink; without it rsync silently omits symlinks from the transfer. `--stats`
is on in both modes: it is the only place rsync reports how many files it sent.
"""
function rsync_command(h::RemoteHost, p::Production, files_from::AbstractString;
                       dry_run::Bool)
    args = String["-r", "-l", "-t", "-p", "--partial", "--stats",
                  "--files-from=$files_from"]
    push!(args, dry_run ? "--dry-run" : "--info=progress2")
    push!(args, rsync_source(h, p.remote_root), rstrip(p.local_root, '/') * "/")
    # LC_ALL fixes the digit grouping in --stats, which parse_rsync_stats strips.
    addenv(`rsync $args`, "LC_ALL" => "C")
end

const _progress_expr = r"([0-9,]+)\s+([0-9]+)%\s+(\S+)\s+([0-9]+:[0-9]{2}:[0-9]{2})"

"""
    parse_progress(chunk::AbstractString)::Union{Nothing,Progress}

One `--info=progress2` reading, or `nothing` for a line that is not one.
"""
function parse_progress(chunk::AbstractString)
    m = match(_progress_expr, chunk)
    m === nothing && return nothing
    Progress(parse(Int, replace(m[1], "," => "")), parse(Int, m[2]) / 100,
             String(m[3]), String(m[4]))
end

# Run rsync, feed every progress reading to `progress`, and return
# (stdout, stderr) so the --stats block can be parsed and any warning rsync
# printed can be reported. GNU rsync can exit 0 while still writing a warning
# to stderr (for example about a file that vanished mid-transfer), so stderr is
# read and returned rather than discarded on the success path. Progress
# readings are separated by carriage returns, not newlines.
function run_rsync(cmd::Cmd, progress)
    errfile = tempname()
    transcript = IOBuffer()
    chunk = IOBuffer()
    proc = open(pipeline(ignorestatus(cmd); stderr = errfile), "r")
    while !eof(proc)
        c = read(proc, Char)
        if c == '\r' || c == '\n'
            text = String(take!(chunk))
            println(transcript, text)
            if progress !== nothing
                reading = parse_progress(text)
                reading === nothing || progress(reading)
            end
        else
            write(chunk, c)
        end
    end
    println(transcript, String(take!(chunk)))
    wait(proc)
    stderr_text = read(errfile, String)
    rm(errfile; force = true)
    success(proc) || throw(ErrorException(
        "rsync failed with exit code $(proc.exitcode): $cmd\n$stderr_text"))
    String(take!(transcript)), stderr_text
end

"""
    rsync_dry_run(h::RemoteHost, p::Production, sel::Selection)::Estimate

What the transfer would actually move, given what is already in the mirror.
"""
function rsync_dry_run(h::RemoteHost, p::Production, sel::Selection)
    out, _ = mktempdir() do dir
        path = joinpath(dir, "files.txt")
        write(path, join(sel.copy, "\n") * "\n")
        run_rsync(rsync_command(h, p, path; dry_run = true), nothing)
    end
    parse_rsync_stats(out, length(sel.link))
end

"""
    remove_stale_links!(p::Production, sel::Selection)::Int

Remove symlinks standing where copies are about to land, and return how many.
Only symlinks are removed: a regular file or a directory at the same path is
data, and the tool never deletes data.
"""
function remove_stale_links!(p::Production, sel::Selection)
    removed = 0
    for rel in sel.copy
        path = p.local_root
        for part in splitpath(rel)
            path = joinpath(path, part)
            if islink(path)
                rm(path)
                removed += 1
                break
            end
        end
    end
    removed
end

function link_path!(h::RemoteHost, p::Production, rel::AbstractString,
                    copies::Set{String}, skipped::Vector{String})
    # A path that is itself copied belongs to rsync: it gets no link, and
    # descending into it would treat a regular file as a directory.
    rel in copies && return 0
    remote = joinpath(p.remote_root, rel)
    target = to_local(p, remote)
    if !any(c -> c == rel || startswith(c, rel * "/"), copies)
        # A link the tool put here before may be replaced; anything else stays.
        if islink(target)
            rm(target)
        elseif ispath(target)
            push!(skipped, rel)
            return 0
        end
        mkpath(dirname(target))
        symlink(to_mount(p, remote), target)
        return 1
    end
    # Something below is copied, so this level has to be a real directory and the
    # link decision moves down to the children.
    mkpath(target)
    created = 0
    for entry in list_dir(h, remote)
        created += link_path!(h, p, joinpath(rel, entry.name), copies, skipped)
    end
    created
end

"""
    create_links!(h::RemoteHost, p::Production, sel::Selection)

Create the symlinks `sel` asks for, returning how many were made and which
targets were left alone because real data already stood there.
"""
function create_links!(h::RemoteHost, p::Production, sel::Selection)
    copies = Set(sel.copy)
    skipped = String[]
    created = 0
    for rel in sel.link
        created += link_path!(h, p, rel, copies, skipped)
    end
    created, skipped
end

"""
    apply!(h::RemoteHost, p::Production, sel::Selection; dry_run = false, progress = nothing)

Bring the mirror in line with `sel`. With `dry_run` it only asks rsync what would
move and returns an [`Estimate`](@ref); otherwise it transfers, creates the links
and writes `config_local.json`, and returns a [`TransferResult`](@ref).

`progress` is called with a [`Progress`](@ref) for each reading rsync prints.
"""
function apply!(h::RemoteHost, p::Production, sel::Selection;
                dry_run::Bool = false, progress = nothing)
    check_rsync()
    isdir(p.local_root) || error("local root $(p.local_root) does not exist")
    # Find out now, not halfway through a transfer, whether the mirror is writable.
    probe, io = mktemp(p.local_root)
    close(io)
    rm(probe)
    isempty(sel.link) || check_mount(p)
    dry_run && return rsync_dry_run(h, p, sel)

    replaced = remove_stale_links!(p, sel)
    out, warnings = mktempdir() do dir
        path = joinpath(dir, "files.txt")
        write(path, join(sel.copy, "\n") * "\n")
        run_rsync(rsync_command(h, p, path; dry_run = false), progress)
    end
    moved = parse_rsync_stats(out, length(sel.link))
    created, skipped = create_links!(h, p, sel)
    TransferResult(moved.bytes, moved.files, created, replaced, skipped,
                   write_local_config(p), warnings)
end

"""
    summary_text(r::TransferResult)::String

The lines the tool prints after an apply.
"""
function summary_text(r::TransferResult)
    lines = ["transferred $(format_bytes(r.bytes)) in $(r.files) files",
             "created $(r.links) links, replaced $(r.replaced_links) stale ones"]
    isempty(r.skipped) ||
        push!(lines, "kept existing data at $(length(r.skipped)) link targets: " *
                     join(r.skipped, ", "))
    isempty(r.warnings) || push!(lines, "rsync warnings:\n$(r.warnings)")
    push!(lines, "export LEGEND_DATA_CONFIG=$(r.config)")
    join(lines, "\n")
end
