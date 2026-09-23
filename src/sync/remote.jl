"""
    abstract type RemoteHost

A machine the tool reads from. `SSHHost` is the real case; `LocalHost` runs the
same operations on this machine and is what the tests drive.
"""
abstract type RemoteHost end

"""
    SSHHost(alias::AbstractString)

A host reached through an `ssh` alias from `~/.ssh/config`. All commands share one
multiplexed connection: `control_path` is the socket `ControlMaster` opens, so
expanding a tree node costs a round trip and not a handshake.
"""
struct SSHHost <: RemoteHost
    alias::String
    control_path::String
end

SSHHost(alias::AbstractString) =
    SSHHost(String(alias), joinpath(tempdir(), "juleana-sync-%r@%h:%p"))

"""
    LocalHost()

Runs every operation on this machine. `list_dir` and `dir_sizes` are implemented
with Julia filesystem calls rather than `find`/`du`, because the BSD versions
shipped with macOS support neither `-printf` nor `-sb`.
"""
struct LocalHost <: RemoteHost end

"""
    DirEntry(name, kind, size)

One entry of a directory listing. `kind` is `:file`, `:dir`, `:link` or `:other`.
`size` is the file size in bytes, and `nothing` for anything that is not a regular
file: a directory's size comes from `dir_sizes`.
"""
struct DirEntry
    name::String
    kind::Symbol
    size::Union{Nothing,Int}
end

"""
    ssh_command(h::SSHHost, remote::AbstractString)::Cmd

The `ssh` invocation that runs the single shell command `remote` on `h`.
"""
ssh_command(h::SSHHost, remote::AbstractString) =
    `ssh -o ControlMaster=auto -o ControlPath=$(h.control_path) -o ControlPersist=60s $(h.alias) $remote`

"""
    run_remote(h::RemoteHost, cmd::Cmd)::String

Run `cmd` on `h` and return its standard output. A nonzero exit is an error
carrying the command and the captured standard error.
"""
function run_remote(h::RemoteHost, cmd::Cmd)
    full = h isa SSHHost ? ssh_command(h, Base.shell_escape(cmd)) : cmd
    out = IOBuffer()
    err = IOBuffer()
    proc = run(pipeline(ignorestatus(full); stdout = out, stderr = err))
    success(proc) || throw(ErrorException(
        "remote command failed with exit code $(proc.exitcode): $full\n$(String(take!(err)))"))
    String(take!(out))
end

"""
    parse_dir_listing(text::AbstractString)::Vector{DirEntry}

Parse the output of `find DIR -mindepth 1 -maxdepth 1 -printf '%y\\t%s\\t%f\\n'`.
"""
function parse_dir_listing(text::AbstractString)
    entries = DirEntry[]
    for line in eachsplit(chomp(text), '\n')
        isempty(line) && continue
        fields = split(line, '\t')
        length(fields) == 3 || throw(ArgumentError(
            "cannot parse directory listing line (expected type, size and name separated by tabs): $(repr(line))"))
        type_char, size_str, name = fields
        kind = type_char == "f" ? :file :
               type_char == "d" ? :dir :
               type_char == "l" ? :link : :other
        push!(entries, DirEntry(String(name), kind,
                                kind == :file ? parse(Int, size_str) : nothing))
    end
    entries
end

"""
    list_dir(h::RemoteHost, dir::AbstractString)::Vector{DirEntry}

List the immediate children of `dir`. The listing never descends: the tool must
not walk a shared filesystem recursively.
"""
list_dir(h::SSHHost, dir::AbstractString) = parse_dir_listing(
    run_remote(h, `find $dir -mindepth 1 -maxdepth 1 -printf '%y\t%s\t%f\n'`))

function list_dir(::LocalHost, dir::AbstractString)
    isdir(dir) || throw(ArgumentError("not a directory: $dir"))
    map(readdir(dir)) do name
        path = joinpath(dir, name)
        st = lstat(path)
        kind = islink(st) ? :link : isfile(st) ? :file : isdir(st) ? :dir : :other
        DirEntry(name, kind, kind == :file ? Int(filesize(st)) : nothing)
    end
end

"""
    dir_sizes(h::RemoteHost, dirs::AbstractVector{<:AbstractString})::Vector{Int}

Apparent size in bytes of each directory in `dirs`, in the order given. One call
covers all of them so that expanding a node costs a single round trip.
"""
function dir_sizes(h::SSHHost, dirs::AbstractVector{<:AbstractString})
    isempty(dirs) && return Int[]
    text = run_remote(h, `du -sb $dirs`)
    sizes = Int[]
    for line in eachsplit(chomp(text), '\n')
        isempty(line) && continue
        push!(sizes, parse(Int, first(split(line, '\t'))))
    end
    length(sizes) == length(dirs) || throw(ErrorException(
        "du reported $(length(sizes)) sizes for $(length(dirs)) directories"))
    sizes
end

# Sums the apparent size of every non-directory entry below `dir`: regular
# files by their content length, symlinks by the length of their target
# string (lstat's size for a symlink), matching what `du -sb` reports for a
# symlink on the remote. `du -sb` additionally counts directory inodes, so a
# remote total exceeds this one by a few kilobytes per directory, which is
# immaterial for a transfer size estimate.
function dir_sizes(::LocalHost, dirs::AbstractVector{<:AbstractString})
    map(dirs) do dir
        isdir(dir) || throw(ArgumentError("not a directory: $dir"))
        total = 0
        for (root, _, files) in walkdir(dir; follow_symlinks = false), f in files
            total += Int(lstat(joinpath(root, f)).size)
        end
        total
    end
end

"""
    read_file(h::RemoteHost, path::AbstractString)::String

Read a small text file: the tool uses this for a production's `config.json`.
"""
function read_file(h::SSHHost, path::AbstractString)
    run_remote(h, `test -f $path`)
    run_remote(h, `cat $path`)
end

function read_file(::LocalHost, path::AbstractString)
    isfile(path) || throw(ArgumentError("not a file: $path"))
    read(path, String)
end

"""
    rsync_source(h::RemoteHost, root::AbstractString)::String

The source argument rsync needs for `root` on `h`. The trailing slash is part of
the contract: with `--files-from`, rsync resolves the file list against it.
"""
rsync_source(h::SSHHost, root::AbstractString) = "$(h.alias):$(rstrip(root, '/'))/"
rsync_source(::LocalHost, root::AbstractString) = "$(rstrip(root, '/'))/"
