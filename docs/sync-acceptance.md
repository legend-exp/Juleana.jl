# Data sync tool: acceptance checklist

Run against `cslg4` and the `test` production. The automated suite never touches
the cluster, so this is where the ssh, rsync and mount paths are confirmed.

Record the date and the outcome of each step in a comment on the pull request.
Do not paste per-detector numbers or plots: sizes, file counts and timings only.

## Prerequisites

- [ ] `rsync --version | head -1` names GNU rsync 3.1 or newer, not openrsync.
- [ ] `ssh cslg4 true` succeeds without a password prompt.
- [ ] The local mirror directory exists and is writable.

## Interface

- [ ] `julia --project=. sync.jl --production test` opens the two-pane layout,
      and the status bar reads `selected: 0 B copy (0 files), 0 links`.
- [ ] The tree shows `config.json` and one row per configured path key of the
      production, at minimum `metadata`, `par`, `tier`, `tier/jldsp`,
      `tier/jlpks`, `tier/raw`.
- [ ] `enter` on `tier` lists it within a few seconds; the row shows `…listing`
      while the request is out.
- [ ] Every row that appears shows a size, or `…` for a section.
- [ ] Expanding a second directory is visibly faster than the first: the ssh
      connection is being reused.
- [ ] Expanding a period node of `tier/jldsp` sizes its run directories (about
      27 GB each) with one `du -sb` call; record how long the expansion takes
      and whether it is acceptable for interactive use.
- [ ] Outside a dialog, `ctrl+c` quits like `q` (offering to save first when
      the selection changed). While a transfer dialog is open no key is
      accepted; press `ctrl+c` at the terminal during a transfer and record
      whether the process still exits and what state the mirror is left in
      (partial files under `--partial` are expected).
- [ ] Walking down `tier/jldsp` → `cal` → `p18` → `r000` shows one row per
      detector, labeled with the detector name.
- [ ] Walking down `tier/jlevt` → `phy` → `p18` → `r000` shows one row per
      filekey, labeled with the timestamp, in ascending timestamp order.

## Copy one filekey

- [ ] On the `jlevt phy p18 r000` node, `n` opens the prompt; typing `1` and
      pressing `enter` marks the first timestamp `[x]` and updates the total.
- [ ] `e` shows an estimate whose byte count is within a few percent of the file
      size shown on the row.
- [ ] `t` transfers it; the gauge advances and the summary names the bytes, the
      file count and the `LEGEND_DATA_CONFIG` line.
- [ ] The file is at the mirrored path and its size matches the remote one.
- [ ] `<local-root>/test/config_local.json` exists; `<local-root>/test/config.json`
      is byte-identical to the remote one.
- [ ] Running `t` again transfers 0 bytes.

## Link `tier/raw` for the same run

- [ ] Mount the remote root, for example
      `sshfs cslg4:/mnt/scratch/projects/legend/data/l200 /Volumes/cslg4`.
- [ ] Restart with `--mount-root /Volumes/cslg4`.
- [ ] `l` on the `tier/raw` node for `p18 r000` marks it `[~]`.
- [ ] `t` creates a symlink at the mirrored path pointing into the mount, and
      the summary reads `created 1 links, replaced 0 stale ones`, with no line
      about skipped targets.
- [ ] Without the mount root, `l` refuses and says so in the status bar.
- [ ] With the mount unmounted, a transfer that has links refuses before moving
      anything, naming the mount root.

## Hybrid read

- [ ] `export LEGEND_DATA_CONFIG=<local-root>/test/config_local.json`
- [ ] In Julia: `using LegendDataManagement; l200 = LegendData(:l200)` and read
      the copied `jlevt` file through it.
- [ ] Read a waveform from the linked `raw` file for the same filekey; it goes
      through the mount and succeeds.
- [ ] Unmount and read it again: it fails with `ENOENT`, which is the intended
      behavior: the tool never pretends data is there.

## Headless re-apply

- [ ] `s` in the interface writes `config/sync/test.json`.
- [ ] `julia --project=. sync.jl --from config/sync/test.json --dry-run` prints
      an estimate of 0 bytes, because everything is already there.
- [ ] Delete one copied file and re-run without `--dry-run` and with `--yes`:
      only that file comes back.
- [ ] Editing the saved file to name another production makes `--from` fail on
      load, naming both productions.
