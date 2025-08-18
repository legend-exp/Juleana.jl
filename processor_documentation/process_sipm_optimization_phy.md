# process_sipm_optimization_phy.jl

**Purpose:** Optimize SiPM energy filters on physics data. The processor (1) reads raw `phy` waveforms, (2) identifies and removes pulser-coincident events, (3) generates DSP filter sweeps over window length (WL) and thresholds, (4) fits optimal WL per filter type maximizing gain and resolution at 1 pe, (5) extracts trigger thresholds at a configurable σ, and (6) writes run-level `rpars/sipmopt` along with QA plots. It also writes pulser tags to the `jlpls` tier for reuse.

---

## Path Variables

```
$RAW_DATA_PATH       = .../legend_data_production/raw_compressed
$METADATA_PATH       = .../legend_data_production/jl-v0.5.0/legend-metadata_new_yaml_p14
$GENERATED_DATA_PATH = .../legend_data_production/jl-v0.5.0/generated
$JLPLS_PATH          = .../legend_data_production/jl-v0.5.0/generated/jlpls
$JLPLT_PATH          = .../legend_data_production/jl-v0.5.0/generated/jlplt
$JLPAR_PATH          = .../legend_data_production/jl-v0.5.0/generated/jlpar
```

---

## Inputs

- **Raw Physics Data (SiPM):** `$RAW_DATA_PATH/phy/p<period>/r<run>/` — columns: `waveform_bit_drop`, `timestamp` (per-channel across shards).
- **Pulser Tags (output of this processor):** `$JLPLS_PATH/phy/<period>/<run>/` — `:<ch>/jlpls/tags` used to flag pulser coincidences.
- **Configs:**
  - DSP: `dataprod_config(l200).sipm(filekey).dsp`
  - Optimization: `dataprod_config(l200).sipm(filekey).optimization`
  - QC/Pulser: `dataprod_config(l200).qc(filekey).pulser`

---

## Functions

### 1) LegendDSP.dsp_<filter>_sipm_optimization_compressed()
**Location:** `LegendDSP.jl` (SiPM optimization utilities)

**Parameters:**
```julia
dsp_<filter>_sipm_optimization_compressed(
  n_samples::Int,
  waveforms::AbstractVector{<:AbstractVector{<:Real}},
  dsp_config::DSPConfig,
  optimization::NamedTuple
)
```

**Returns:** `NamedTuple` with `trig_max_grid::Matrix`, `thresholds_grid::TableLike` (per WL).

**Detailed workflow:**
- Decode waveforms (if needed), build WL grid from `optimization.e_grid_wl`.
- Per WL: apply `<filter>`, compute trigger maxima, collect per-WL threshold features.
- Return grids for downstream fitting.

**Purpose:** Produce WL sweeps of trigger maxima and threshold features for later WL/threshold determination.

### 2) fit_sipm_wl()
**Location:** `LegendSpecFits.jl` (SiPM analysis)

**Parameters:**
```julia
fit_sipm_wl(
  trig_max_grid::AbstractMatrix{<:Real},
  wl_grid::AbstractVector{<:Real},
  thresholds_grid::TableLike;
  kwargs...
)
```

**Returns:** `result` (`wl`, `gain`, `res_1pe`, metrics), `report` (plots).

**Detailed workflow:**
- Build per-WL histograms, fit single-pe peaks to get gain and width.
- Optimize WL based on configured merit (e.g., maximize gain, minimize width, or combined).
- Emit a report with WL trends and best-WL overlays.

**Purpose:** Select the WL that maximizes SiPM performance and provide QA artifacts.

### 3) LegendDSP.dsp_<filter>_sipm_thresholds_compressed()
**Location:** `LegendDSP.jl`

**Parameters:**
```julia
dsp_<filter>_sipm_thresholds_compressed(
  waveforms::AbstractVector{<:AbstractVector{<:Real}},
  wl_opt::Real,
  dsp_config::DSPConfig
)
```

**Returns:** `thresholds::TableLike` with discriminator observables (e.g., `bsl_deriv`).

**Detailed workflow:**
- Apply `<filter>` at `wl_opt`; compute observables used as triggers.
- Output compact columns for threshold fitting.

**Purpose:** Provide discriminator distributions at the optimized WL.

### 4) fit_simp_threshold()
**Location:** `LegendSpecFits.jl`

**Parameters:**
```julia
fit_simp_threshold(
  observable::AbstractVector{<:Real},
  min_cut::Real,
  max_cut::Real;
  n_bins::Int,
  relative_cut::Real,
  fit_thresholds::Bool,
  uncertainty::Bool=true
)
```

**Returns:** `result` (e.g., `σ`), `report` (histogram and fit overlays).

**Detailed workflow:**
- Histogram in `[min_cut, max_cut]` with `n_bins`, optional relative pre-cut.
- Fit a threshold model, extract `σ` with uncertainties from fit covariance.

**Purpose:** Determine robust trigger thresholds for the chosen observable at `wl_opt`.

### 5) flag_coincidences()
**Location:** `LegendSpecFits.jl`

**Parameters:** `(ts_signal::Vector{<:Real}, ts_reference::Vector{<:Real}; ts_window::Real)`

**Returns:** `Vector{Bool}` coincidence mask.

**Detailed workflow:**
- Mark events within `±ts_window` around reference timestamps as pulser coincidences.

**Purpose:** Remove pulser-coincident events prior to optimization.

---

## Internal Functions

1) get_data_key_for_channel(ds, ch::ChannelIdLike, det::DetectorIdLike)
- **Input:** HDF5 dataset handle, channel and detector IDs
- **Returns:** `String | nothing`
- **Purpose:** Resolve channel vs detector keys in LH5.

2) read_raw_data_with_fallback(columns, l200, period, run, ch, det)
- **Input:** requested columns, `LegendData`, period/run, channel/detector
- **Returns:** concatenated rows across shards (full table or selected columns)
- **Purpose:** Robust raw loader across shard files and key conventions.

3) ch_puls_phy(chinfo_puls)
- **Input:** pulser channel info
- **Returns:** `(processed::Bool, log::NamedTuple)`
- **Purpose:** Create pulser tags in `jlpls` by running DSP on the pulser channel and calibrating the auxiliary channel.

4) ch_sipm_optimization(chinfo_ch)
- **Input:** detector channel info
- **Returns:** `(result, log, processed)`
- **Purpose:** Per-detector workflow: load waveforms, remove pulser coincidences, build DSP grids, fit WL, compute thresholds, save plots, collect `rpars/sipmopt`.

---

## Outputs

- **Parameters (rpars):** `$JLPAR_PATH/rpars/sipmopt/<period>/<run>.yaml` — per detector: `<filter_type>.wl`, `.gain`, `.res_1pe`, `.trig_threshold.<observable>.σ`; validity written for `(period, run)`.
- **Pulser tags:** `$JLPLS_PATH/phy/<period>/<run>/` — `l200-p<period>-r<run>-phy-<ch>-tags.lh5` with `:<ch>/jlpls/tags`.
- **Plots:** `$JLPLT_PATH/phy/<period>/<run>/` — `wl_sweep_<filter_type>.png`, `wl_sweep_calibration_<filter_type>.png`, `trigger_threshold_<observable>.png`.

**Notes:** Ensure hardware configuration validity for `phy` covers the run timestamp (`channelinfo(..., system=:spms)`). Pulser channel must be declared in QC config.
