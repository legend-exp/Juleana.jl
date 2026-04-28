# LEGEND L200 Tier File Structure

Reference for the on-disk HDF5 layout of the LEGEND L200 tier files: the FlashCam `raw`
output and the Julia-side `jldsp`, `jlhit`, `jlevt`, `jlpmt`, and `jlpls` tiers. Every
tier is stored in [LH5](https://github.com/legend-exp/legend-pydataobj) format (HDF5
with `@datatype` attributes describing nested structs, tables and variable-length
arrays).

This document describes the **general** structure that applies to every period and run.
The exact set of detectors, channel counts, and per-event sizes change run-by-run, but
the schema and grouping conventions do not.

---

## 1. Filekey conventions and tier availability

A *filekey* identifies one acquisition window and has the form
`l200-p<P>-r<R>-<cat>-<TS>` where `<TS>` is a UTC timestamp like `20251107T191821Z` and
`<cat>` is the data category (`cal` for calibration, `phy` for physics).

| Tier   | `cal` | `phy` | One file represents …                  | Filename pattern |
|--------|:-----:|:-----:|----------------------------------------|------------------|
| raw    |   ✓   |   ✓   | one filekey (timestamp window)         | `l200-p<P>-r<R>-<cat>-<TS>-tier_raw.lh5` |
| jldsp  |   ✓   |   ✓   | one filekey                            | `l200-p<P>-r<R>-<cat>-<TS>-tier_jldsp.lh5` |
| jlhit  |   ✓   |   —   | one detector for the entire run        | `l200-p<P>-r<R>-cal-<DETID>-tier_jlhit.lh5` |
| jlevt  |   —   |   ✓   | one filekey                            | `l200-p<P>-r<R>-phy-<TS>-tier_jlevt.lh5` |
| jlpmt  |   —   |   ✓   | one filekey                            | `l200-p<P>-r<R>-phy-<TS>-tier_jlpmt.lh5` |
| jlpls  |   ✓   |   ✓   | one pulser channel for the entire run  | `l200-p<P>-r<R>-<cat>-<PULSID>-tier_jlpls.lh5` |

Notes:

- `jlhit` exists only for `cal`. `jlevt` and `jlpmt` exist only for `phy`. `jldsp`
  and `jlpls` exist for both categories.
- For `jlpls` the pulser ID is `PULS01` in `cal` and `PULS01ANA` in `phy`.

### Detector naming conventions

| Prefix   | System                        | Examples                         |
|----------|-------------------------------|----------------------------------|
| `V…`     | HPGe inverted-coax            | `V00048A`, `V14654A`             |
| `B…`     | HPGe BEGe                     | `B00000C`, `B00000D`             |
| `PMT…`   | muon-veto PMTs                | `PMT101`–`PMT710`                |
| `S…`     | LAr-veto SiPMs                | `S002`–`S100`                    |
| `BSLN01` | dedicated baseline trigger    | (single channel)                 |
| `PULS01` | pulser, raw                   | (single channel)                 |
| `PULS01ANA` | pulser, analyzed (phy only)| (single channel)                 |
| `MUON01` | muon-veto sum (phy only)      | (single channel)                 |
| `BF862-…`| FET test channels (phy only)  | only listed in the `/raw` view of the raw file |
| `chXXXXXXX` | FlashCam stream IDs        | independent auxiliary streams (see §2) |

> The `chXXXXXXX` top-level keys are **not** aliases of `V*`/`B*`/`PMT*`/`S*`
> detectors. They are independent FlashCam streams that run in parallel and carry
> different timestamps and `board_id` values.

---

## 2. `raw` tier (FlashCam DAQ output)

### 2.1 Top-level layout

```
/                                File root (no @datatype on the root itself)
├── <DETID>/                     e.g. /V00048A
│   └── raw/                     (table) — see §2.2
│       ├── <scalar columns>
│       ├── waveform_presummed/  GED only
│       ├── waveform_windowed/   GED only
│       ├── waveform/            PMT only
│       └── waveform_bit_drop/   SPM only
├── chXXXXXXX/                   independent FlashCam streams
│   └── raw/...                  (same shape)
├── extra/                       DAQ metadata
│   ├── OrcaHeader               :: Cstring
│   ├── RunControl/              run_number, time, runstartorstop, …
│   ├── fcid_1/                  config, status
│   └── fcid_2/                  config, status
└── raw/                         struct view: every detector as a sub-key
    ├── <DETID>                  hard/soft link to /<DETID>/raw
    └── …
```

`/<DETID>/raw/...` and `/raw/<DETID>/...` resolve to the **same** dataset (a soft-link
view); the per-detector path is the canonical one.

The phy raw file additionally exposes `MUON01`, `PULS01ANA`, and `BF862-XX` only in the
`/raw/` struct view (i.e. they are listed under `/raw/<name>` but not as a separate
top-level group).

### 2.2 `<DETID>/raw/` columns

Every detector's `raw/` group is a `table{...}` with about 33 scalar columns plus one
or more waveform sub-groups.

#### Scalar columns common to all systems

| Column              | Type     | Description |
|---------------------|----------|-------------|
| `abs_delta_mu_usec` | Int32    | \|`delta_mu_usec`\| |
| `baseline`          | UInt16   | FPGA baseline estimate |
| `board_id`          | UInt16   | FlashCam board MAC |
| `channel`           | UInt16   | per-stream channel index |
| `daqenergy`         | UInt16   | trigger energy estimator (62.5 MHz: pulse height; 250 MHz: integral over `sumlength`) |
| `deadinterval_nsec` | Int64    | dead interval before this event (4 ns precision) |
| `deadtime`          | Float64  | accumulated dead time per channel |
| `delta_mu_usec`     | Int32    | FPGA↔server clock offset |
| `dr_ch_idx`         | UInt16   | start channel of the dead range |
| `dr_ch_len`         | UInt16   | length of the dead range |
| `dr_maxticks`       | Int32    | tick value at PPS when buffers became free |
| `dr_start_pps`      | Int32    | PPS counter at buffer-full |
| `dr_start_ticks`    | Int32    | tick counter at buffer-full |
| `dr_stop_pps`       | Int32    | PPS counter at buffer-free |
| `dr_stop_ticks`     | Int32    | tick counter at buffer-free |
| `event_type`        | Int32    | 1 = shared trigger, 11 = sparse mode |
| `eventnumber`       | Int32    | trigger counter |
| `fc_input`          | UInt16   | per-board ADC channel |
| `fcid`              | UInt16   | stream ID |
| `lifetime`          | Float64  | accumulated live time |
| `mu_offset_sec`     | Int32    | server↔FPGA seconds |
| `mu_offset_usec`    | Int32    | server↔FPGA microseconds |
| `numtraces`         | Int32    | |
| `packet_id`         | UInt32   | decoded packet index |
| `runtime`           | Float64  | time since run start (per channel) |
| `timestamp`         | Float64  | unix time |
| `to_master_sec`     | Int32    | offset server↔FPGA (gps mode) |
| `to_start_sec`      | Int32    | run-start seconds |
| `to_start_usec`     | Int32    | run-start microseconds |
| `ts_maxticks`       | Int32    | tick counter at last PPS |
| `ts_pps`            | Int32    | PPS counter |
| `ts_ticks`          | Int32    | 250 MHz tick counter |

#### Additional columns on GED systems (`V*`, `B*`, `BSLN01`, `PULS01`, `MUON01`)

| Column         | Type   |
|----------------|--------|
| `presum_rate`  | UInt16 (`Float32` on `BSLN01`) |
| `t_sat_hi`     | UInt16 (`Float32` on `BSLN01`) |
| `t_sat_lo`     | UInt16 (`Float32` on `BSLN01`) |

GED detectors therefore have 37 scalar columns; PMTs and SPMs have 33.

#### Waveform sub-groups

| System    | Sub-group(s)                                    | Encoding |
|-----------|-------------------------------------------------|----------|
| GED       | `waveform_presummed/`, `waveform_windowed/`     | `uleb128_zigzag_diff` (encoded) |
| PMT       | `waveform/`                                     | unencoded `UInt16` (samples × events) |
| SPM       | `waveform_bit_drop/`                            | `uleb128_zigzag_diff` (encoded) |

Each waveform sub-group has the layout `table{dt, t0, values}`:

```
waveform_<variant>/
├── dt :: Float32 (n_events,)        sample spacing
├── t0 :: Float32 (n_events,)        start time
└── values
    ├── (encoded)         Group { codec = "uleb128_zigzag_diff",
    │                              decoded_size :: Int64,
    │                              encoded_data :: VoV }
    └── (unencoded, PMT)  Dataset UInt16 (samples_per_wf, n_events)
```

### 2.3 `extra/` — DAQ metadata

| Path                       | Type    | Content |
|----------------------------|---------|---------|
| `extra/OrcaHeader`         | Cstring | full ORCA header XML/JSON |
| `extra/RunControl/`        | Group   | sub-keys `run_number`, `time`, `runstartorstop`, `endsubrunrecord`, `heartbeatrecord`, `quickstartrun`, `remotecontrolrun`, `startsubrunrecord`, `subrun_number` |
| `extra/fcid_1/`, `fcid_2/` | Group   | per-stream `config` and `status` sub-groups |

---

## 3. `jldsp` tier (DSP output, all detectors per filekey)

### 3.1 Layout

```
/
└── jldsp/                       Group
    ├── <DETID>/                 (table)
    │   └── <DSP scalar columns>
    └── …
```

One file holds one filekey; every detector that produced data in that filekey appears
as a sub-group of `/jldsp/`.

- `cal` files contain only GED detectors at this level.
- `phy` files additionally contain SiPMs (`S*`), `MUON01`, and `PULS01`.

### 3.2 GED schema (`V*`, `B*`) — 72 scalar columns

Every column is a vector of length `n_triggers_for_this_det_in_this_filekey`.

| Group           | Columns |
|-----------------|---------|
| time            | `timestamp :: Float64`, `deadtime :: Float64` |
| id              | `eventID_fadc :: Int32` |
| DAQ pass-through| `e_fc :: UInt16`, `blfc :: UInt16` |
| saturation      | `n_sat_low`, `n_sat_high`, `n_sat_low_cons`, `n_sat_high_cons` (Int64); `t_sat_lo`, `t_sat_hi` (UInt16) |
| baseline        | `blmean`, `blsigma`, `blslope`, `bloffset`, `bl_slope_sigma` (Float64) |
| aux baseline    | `auxbl1_mean/sigma/slope_sigma`, `auxbl2_mean/sigma/slope_sigma` (Float64) |
| QC              | `qc_label :: Int64` |
| min/max         | `e_max`, `e_min`, `e_max_pre`, `e_min_pre` (Float64) |
| tail fit        | `tailmean`, `tailsigma`, `tailslope`, `tailoffset`, `tail_τ`, `tail_mean`, `tail_sigma` (Float64) |
| aux pole-zero   | `auxpz1_mean/sigma/slope_sigma`, `auxpz2_…` (Float64) |
| timing          | `t0`, `t10`, `t50`, `t80`, `t90`, `t99`, `t50_pre`, `t50_current`, `drift_time` (Float32) |
| energy          | `e_10410`, `e_535`, `e_313`, `e_trap`, `e_cusp`, `e_zac`, `e_trap_max`, `e_cusp_max`, `e_zac_max` (Float64) |
| timing of max   | `t_trap_max`, `t_cusp_max`, `t_zac_max` (Float32) |
| charge drift / late charge | `qdrift`, `lq` (Float64) |
| A/E             | `a_sg`, `a_60`, `a_100`, `a_raw` (Float64) |
| pile-up         | `inTrace_intersect :: Float32`, `inTrace_n :: Int64` |
| inverted-baseline check | `e_10410_inv`, `e_313_inv` (Float64); `t0_inv` (Float32) |

### 3.3 SPM schema (`S*`, phy only) — 36 columns

```
/jldsp/<SPMID>/  (table)
├── timestamp :: Float64
├── eventID_fadc :: Int32
├── blfc, e_fc :: UInt16
├── blmean, blsigma, blslope, bloffset :: Float64
├── wfmean, wfsigma, wfslope, wfoffset :: Float64
├── e_max, e_min, e_max_lar, e_min_lar :: Float64
├── t_max, t_min, t_max_lar, t_min_lar :: Float32
├── threshold, threshold_DC, threshold_trap, threshold_DC_trap :: Float64
├── trig_max :: VoV{Float32}                   one entry per trigger
├── trig_max_DC :: VoV{Float32}
├── trig_max_trap :: VoV{Float32}
├── trig_max_DC_trap :: VoV{Float32}
├── trig_pos :: VoV{Float32}
├── trig_pos_DC :: VoV{Float32}
├── trig_pos_trap :: VoV{Float32}
├── trig_pos_DC_trap :: VoV{Float32}
├── trig_pos_high_trap :: VoV{Float32}
├── trig_pos_high_DC_trap :: VoV{Float32}
├── trig_pos_tot_trap :: VoV{Float32}
└── trig_pos_tot_DC_trap :: VoV{Float32}
```

VoV columns use the standard LH5 layout:
`cumulative_length :: Int64 (n_evts,)` plus `flattened_data :: T (sum_lens,)`.

### 3.4 `MUON01` schema (phy only) — 11 columns

```
/jldsp/MUON01/  (table)
├── timestamp, deadtime :: Float64
├── eventID_fadc :: Int32
├── e_fc, blfc :: UInt16
├── blmean, blsigma, blslope, bloffset :: Float64
├── e_max, e_10410 :: Float64
└── t50 :: Float32
```

### 3.5 `PULS01` (phy only)

Stored at `/jldsp/PULS01/` with the GED schema (typically consumed via `jlpls`).

---

## 4. `jlhit` tier (hit-level per detector, `cal` only)

### 4.1 Layout

```
/
└── jlhit/
    └── <DETID>/                exactly one detector per file
        ├── dataPulser/         (table) DSP rows for pulser-tagged events
        │   └── <72 GED-DSP columns>
        ├── dataQC/             (table) DSP rows that pass quality cuts
        │   └── <72 GED-DSP columns>
        ├── pulserTag :: Bool (n_all_evts,)   per-event pulser flag
        └── qc/                 (table, n_all_evts QC flags)
            ├── is_0_trigs, is_discharge, is_no_NaN, is_physical, is_pileup,
            │   is_saturated, is_valid_e, is_valid_rms, is_valid_slope,
            │   is_valid_t0, is_valid_t50, is_valid_t50_classical,
            │   is_valid_τ, ml :: Bool
```

`dataPulser` and `dataQC` are **disjoint, pre-filtered** subsets of the run's DSP rows
and have different lengths from each other and from the unfiltered length.
`pulserTag` and `qc/*` cover every triggered event in the run (same length each).

The `dataPulser` and `dataQC` columns are exactly the 72 GED DSP columns described
in §3.2.

---

## 5. `jlevt` tier (event level, all detectors per filekey, `phy` only)

### 5.1 Top-level layout

```
/
└── jlevt/                              table { tstart, geds, spms, aux, ged_spm, ft_spm, ged_pmt }
    ├── tstart :: Float64 (n_evts,)     event start time (UTC)
    ├── geds/                           table — GED data (event-scalar + VoV columns)
    ├── spms/                           table — SiPM data (VoV, partly nested)
    ├── aux/                            sub-group with three tables
    │   ├── forcedtrigger/              table (8 cols, n_evts)
    │   ├── muonveto/                   table (8 cols, n_evts)
    │   └── pulser/                     table (8 cols, n_evts)
    ├── ged_spm/                        table (7 cols, n_evts)  GED ↔ SiPM coincidence
    ├── ft_spm/                         table (7 cols, n_evts)  forced-trigger ↔ SiPM
    └── ged_pmt/                        table (5 cols, n_evts)  GED ↔ PMT coincidence
```

### 5.2 Index classes inside `jlevt`

The `jlevt/geds` table mixes three column classes that index differently:

1. **Event-scalar** — length `n_evts`, one value per event.
2. **Per-detector-list VoV** — variable inner length, typically equal to the number of
   detectors in the array. The inner index runs over all detectors; the column
   `detector` provides the mapping inner-index ↦ `DetectorId`.
3. **Per-trigger VoV** — variable inner length, equal to the number of triggers in
   that event (not all detectors). The column `trig_e_det` provides the mapping
   inner-index ↦ triggering `DetectorId`, and `trig_e_det_idxs` maps an inner index
   in the per-trigger view to the corresponding inner index in the per-detector-list
   view.

The `jlevt/spms` table is uniformly per-detector-list VoV (no per-trigger split), but
some columns are nested `VoV{VoV{T}}` (one inner vector per SPM, an even-deeper inner
vector per per-SPM trigger).

### 5.3 `/jlevt/geds/` columns

#### Event-scalar (length `n_evts`)

| Column | Type |
|--------|------|
| `is_discharge`, `is_discharge_recovery`, `is_saturated`, `is_valid_hit`, `is_valid_psd`, `is_valid_qc`, `is_valid_trig` | Bool |
| `max_e_cusp_cal`, `max_e_cusp_ctc_cal`, `max_e_short_cal`, `max_e_trap_cal`, `max_e_trap_ctc_cal` | Float64 |
| `max_e_det` | UInt32 (`DetectorId`) |
| `max_e_det_idxs` | Int64 (index into the per-detector-list view) |
| `multiplicity` | Int64 |
| `t0_start` | Float32 |
| `tstart` | Float64 |

#### Per-detector-list VoV (inner length ≈ number of detectors in the array)

| Column | Inner type | Notes |
|--------|------------|-------|
| `detector` | UInt32 (`DetectorId`) | inner-index ↦ detector |
| `dataidx`, `detevtno` | Int64 | indices into `jldsp` |
| `blmean`, `blsigma`, `qdrift` | Float64 | DSP output |
| `drift_time`, `t0`, `t50` | Float32 | timing |
| `timestamp` | Float64 | per-detector timestamp |
| `qc_label` | Int64 | |
| `e_535_cal`, `e_cusp_cal`, `e_cusp_ctc_cal`, `e_cusp_max_cal`, `e_trap_cal`, `e_trap_ctc_cal`, `e_trap_max_cal` | Float64 | calibrated energies |
| `aoe_100_classifier`, `aoe_raw_classifier`, `aoe_sg_classifier` (each with `_ds_cut`, `_low_cut`) | Float64 / Bool | A/E |
| `lq_classifier` (with `_ds_cut`, `_high_cut`) | Float64 / Bool | LQ |
| `psd_classifier` | Bool | PSD |
| `is_0_trigs`, `is_baseline`, `is_baseline_ml`, `is_discharge_recovery_ml`, `is_negative_crosstalk`, `is_nopileup`, `is_nopileup_ml`, `is_physical`, `is_physical_ml`, `is_physical_trig`, `is_valid_bl_mean`, `is_valid_bl_slope`, `is_valid_bl_std`, `is_valid_dteff`, `is_valid_e10410_inv`, `is_valid_max_e10410`, `is_valid_rms`, `is_valid_rt`, `is_valid_slope`, `is_valid_t0`, `is_valid_t0_ml`, `is_valid_t50`, `is_valid_tail`, `is_valid_tail_slope`, `is_valid_τ` | Bool | per-detector QC flags |

#### Per-trigger VoV (inner length ≈ number of triggers per event)

| Column | Inner type | Notes |
|--------|------------|-------|
| `trig_e_det` | UInt32 (`DetectorId`) | which detector triggered |
| `trig_e_det_idxs` | Int64 | inner index of that detector in the per-detector-list view |
| `trig_e_535_cal`, `trig_e_cusp_ctc_cal`, `trig_e_cusp_max_cal`, `trig_e_trap_ctc_cal`, `trig_e_trap_max_cal` | Float64 | trigger-level energies |
| `trig_t0` | Float32 | |

### 5.4 `/jlevt/spms/` columns

```
/jlevt/spms/
├── tstart :: Float64 (n_evts,)                       event-scalar
├── dataidx :: VoV{Int64}                             one entry per SPM
├── detector :: VoV{UInt32, DetectorId}               one entry per SPM
├── detevtno :: VoV{Int64}                            one entry per SPM
├── timestamp :: VoV{Float64}                         one entry per SPM
├── trig_max_cal :: VoV{ VoV{Float64} }               per SPM × per trigger
├── trig_max_is_dc :: VoV{ VoV{Bool} }                per SPM × per trigger
├── trig_max_trap_cal :: VoV{ VoV{Float64} }          per SPM × per trigger
├── trig_max_trap_is_dc :: VoV{ VoV{Bool} }           per SPM × per trigger
├── trig_pos :: VoV{ VoV{Float32} }                   per SPM × per trigger
└── trig_pos_trap :: VoV{ VoV{Float32} }              per SPM × per trigger
```

The SPM table has no per-trigger flat view and no `trig_e_det_idxs` analogue. The
nested `trig_max_*` and `trig_pos_*` columns carry one inner vector per SPM whose
elements are per-trigger arrays.

### 5.5 `/jlevt/aux/` — three flat tables (identical schema)

`forcedtrigger/`, `muonveto/`, and `pulser/` each have:

| Column         | Type    |
|----------------|---------|
| `tstart`       | Float64 |
| `dataidx`      | Int64   |
| `detevtno`     | Int64   |
| `detector`     | UInt32  |
| `timestamp`    | Float64 |
| `e_10410`      | Float64 |
| `t50`          | Float32 |
| `aux_trig`     | Bool    |

All three tables have length `n_evts`.

### 5.6 `/jlevt/ged_spm/`, `/jlevt/ft_spm/`, `/jlevt/ged_pmt/` — coincidence tables

All three are flat event-scalar tables of length `n_evts`.

`ged_spm/` and `ft_spm/` (identical schema, 7 columns):

```
is_valid_lar :: Bool
trig_max_cal_lar_cut :: Bool
trig_max_cal_spms_win_multiplicity :: Int64
trig_max_cal_spms_win_pe_sum :: Float64
trig_max_trap_cal_lar_cut :: Bool
trig_max_trap_cal_spms_win_multiplicity :: Int64
trig_max_trap_cal_spms_win_pe_sum :: Float64
```

`ged_pmt/` (5 columns):

```
is_valid_muon :: Bool
multiplicity :: Int64
n_hit_window :: Int64
pe_cal :: Float64
timestamp :: Float64
```

---

## 6. `jlpmt` tier (PMT event level, all PMTs per filekey, `phy` only)

One file per filekey, with a single flat table at the root holding every event
that involves the muon-veto PMT system. Unlike `jlevt`, `jlpmt` has no
`geds`/`spms`/`aux` substructure — all columns live directly under `/jlpmt`,
mixing event-scalar columns with per-PMT-list VoVs.

### 6.1 Top-level layout

```
/
└── jlpmt/                         table { is_valid_muon, pulse_height_cal_muon_cut,
                                            pulse_height_cal_pmts_pe_sum,
                                            pulse_height_cal_pmts_multiplicity,
                                            tstart, dataidx, detevtno, detector,
                                            timestamp, pulse_height_cal, t0, t0_low,
                                            trig_max, trig_pos,
                                            pulse_height_is_physical_trig }
```

### 6.2 Index classes

Two column classes are mixed at top level:

1. **Event-scalar** (length `n_evts`): one value per muon-veto event.
2. **Per-PMT-list VoV** (inner length ≈ number of PMTs read out): one value per
   PMT in the array. The `detector` column gives the inner-index ↦ `DetectorId`
   mapping.

There is no per-trigger split (no `trig_e_det` / `trig_e_det_idxs` analogue).
Multi-trigger information is carried as nested `VoV{VoV{T}}` (inner per-trigger
of that PMT) for `trig_max` and `trig_pos`.

### 6.3 Column reference

#### Event-scalar (length `n_evts`)

| Column                               | Type    |
|--------------------------------------|---------|
| `is_valid_muon`                      | Bool    |
| `pulse_height_cal_muon_cut`          | Bool    |
| `pulse_height_cal_pmts_multiplicity` | Int64   |
| `pulse_height_cal_pmts_pe_sum`       | Float64 |
| `tstart`                             | Float64 |

#### Per-PMT-list VoV (inner length ≈ number of PMTs)

| Column                          | Inner type            | Notes                          |
|---------------------------------|-----------------------|--------------------------------|
| `detector`                      | UInt32 (`DetectorId`) | inner-index ↦ PMT              |
| `dataidx`, `detevtno`           | Int64                 | indices into `jldsp`           |
| `timestamp`                     | Float64               | per-PMT timestamp              |
| `t0`, `t0_low`                  | Float64               | timing                         |
| `pulse_height_cal`              | Float64               | calibrated pulse height        |
| `pulse_height_is_physical_trig` | Bool                  | per-PMT physical-trigger flag  |

#### Nested VoV (per-PMT × per-trigger of that PMT)

| Column      | Inner-inner type | Notes                                 |
|-------------|------------------|---------------------------------------|
| `trig_max`  | Float64          | one inner Vector per PMT, per trigger |
| `trig_pos`  | Float64          | same shape                            |

---

## 7. `jlpls` tier (pulser tags, one file per run)

One file per run, with a single sub-group named after the pulser channel. The schema
differs between `cal` and `phy`.

### 7.1 `cal`: `/jlpls/PULS01/tags`

```
daqenergy :: UInt16  (n_pulser_evts,)
timestamp :: Float64 (n_pulser_evts,)
```

### 7.2 `phy`: `/jlpls/PULS01ANA/tags`

```
aux_trig  :: Bool    (n_pulser_evts,)
e_10410   :: Float64 (n_pulser_evts,)
t50       :: Float32 (n_pulser_evts,)
timestamp :: Float64 (n_pulser_evts,)
```

The `jlpls` tier has no per-filekey split; each file holds every pulser event of the
run.

---

## 8. LH5 datatype reference

LH5 stores the `@datatype` attribute on every group/dataset to describe the logical
shape on top of the HDF5 native types.

| `datatype` string                                  | Julia representation |
|----------------------------------------------------|----------------------|
| `array<1>{real}`                                   | `AbstractVector{<:Real}` |
| `array<1>{bool}`                                   | `AbstractVector{Bool}` |
| `array<1>{detectorid}`                             | `AbstractVector{DetectorId}` (UInt32-encoded) |
| `array<1>{array<1>{real}}`                         | VoV of reals: `cumulative_length` + `flattened_data` |
| `array<1>{array<1>{bool}}`                         | VoV of `Bool` |
| `array<1>{array<1>{detectorid}}`                   | VoV of `DetectorId` |
| `array<1>{array<1>{array<1>{real}}}`               | nested VoV (two levels of `cumulative_length`) |
| `array_of_equalsized_arrays<1,1>{real}`            | 2-D dataset, e.g. (samples × events) for raw waveforms |
| `array_of_encoded_equalsized_arrays<1,1>{real}`    | encoded waveform group with a `codec` attribute |
| `table{col1, col2, …}`                             | group whose children are the table's columns (read as `Table`) |
| `struct{key1, key2, …}`                            | group read as `NamedTuple` |
| `real`                                             | scalar real dataset |
