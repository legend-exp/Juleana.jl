# process_hit_cal.jl

**Purpose:** Applies quality control (QC) cuts and pulser event tagging to DSP data to create the `jlhit` data tier - the first step in separating physics events from backgrounds and instrumental artifacts

---

## Path Variables

```
$RAW_DATA_PATH = .../legend_data_production/raw_compressed
$METADATA_PATH = .../legend_data_production/jl-v0.5.0/legend-metadata_new_yaml_p14
$GENERATED_DATA_PATH = .../legend_data_production/jl-v0.5.0/generated
$JLPEAKS_PATH = .../legend_data_production/jlpeaks
$JLML_PATH = .../legend_data_production/jlml
```

---

## Inputs

**DSP Data:**
- **Path:** `$GENERATED_DATA_PATH/tier/jldsp/cal/<period>/<run>/`
- **Data Keys:** All DSP parameters from `process_dsp_cal.jl` (energy filters, timing, A/E, QC parameters, etc.)

**QC Config:**
- **Path:** `$METADATA_PATH/jldataprod/config/qc/`
- **Parameters:**
  - **Physical Event Cuts (examples):**
    - `ml`: ML label requirement (commonly `qc_label == 0` to keep “Normal” only; optional)
    - `is_valid_t0`, `is_valid_t50`: timing windows (configured ranges around expected trigger locations)
    - `is_pileup`: reject in-trace pile-up (uses `inTrace_*` and timing relations like distance to `t0`/`drift_time`)
    - `is_valid_e`: energy defined and finite (e.g., `e_trap > 0 && isfinite(e_trap)`)
    - `is_saturated`, `is_discharge`: reject saturation/discharge (`n_sat_high > 0`, `n_sat_low > 0`)
  - **Baseline Cuts:** limits on `blmean`, `blsigma`, `blslope` (units and ranges configured per setup)
  - **Combined Cuts:**
    - `is_physical`: final physics selection expression combining the above cuts (string evaluated via `ljl_propfunc`)
    - `is_trig`, `is_baseline`: auxiliary selections for monitoring/triggers

**Pulser Config:**
- **Path:** `$METADATA_PATH/jldataprod/config/qc/`
- **Parameters:**
  - `puls_channel`: Pulser channel ID (`"PULS01"` or `"PULS01ANA"`)
  - `puls_ts_window`: Coincidence time window (99-131µs)
  - `frequency`: Expected pulser frequency (0.5 Hz)
  - `n_pulser_identified`: Minimum pulser events required
  - `max_period_err`: Maximum period error tolerance

---

## Functions

### 1. ljl_propfunc()
**Location:** `LegendDataManagement.jl/src/ljl_expressions.jl:208-220`

**Parameters:**
```julia
ljl_propfunc(expr_string::AbstractString)
```

**Returns:**
- `function`: Julia function that can be applied to data tables

**Purpose:** **String-to-Function Converter** - Converts QC cut expressions from YAML config strings (e.g., `"qc_label == 0"`) into executable Julia functions. Essential for applying complex logical cuts defined in configuration files to DSP data tables. **Operates per cut definition, creates reusable functions for batch processing**

### 2. flag_coincidences()
**Location:** `LegendEventAnalysis.jl/src/build_global_events.jl:174-200`

**Parameters:**
```julia
flag_coincidences(
    timestamps::AbstractVector{<:RealQuantity},
    ref_timestamps::AbstractVector{<:RealQuantity};
    ts_window::Number = 125u"μs"
)
```

**Returns:**
- `flags::Vector{Bool}` aligned to `timestamps`: true if event time lies within ±ts_window of any `ref_timestamps` entry

**Purpose:** Temporal coincidence detection between physics-channel timestamps and a reference stream (pulser). Used to tag pulser events for later exclusion from physics spectra.

**Configuration mapping:**
- The time window is not hard-coded; we pass `ts_window = pulser_config_ch.puls_ts_window` from QC YAML. Typical value: 131.072 µs (see QC config). The function’s default 125 µs is overridden in production by the YAML.

**Algorithm (per channel):**
1. Ensure `timestamps` (physics) and `ref_timestamps` (pulser) are in monotonically increasing order.
2. Use a sliding two-pointer scan: for each physics timestamp, advance a pointer in the pulser stream to the first candidate not earlier than `t - ts_window`; then check the local neighborhood (advance while `ref_t <= t + ts_window`). If any candidate lies within the inclusive window, mark coincidence true.
3. Complexity is linear in the sum of lengths (no quadratic search).

**Edge cases:**
- Empty `ref_timestamps` yields all-false flags.
- Non-finite or missing timestamps are ignored; the corresponding flag is false.
- Units are preserved via `Unitful`; both inputs must be commensurate (e.g., µs).

**Downstream use in this processor:**
- We compute `is_pulser = flag_coincidences(data_ch.timestamp, data_pulser.timestamp; ts_window=pulser_config_ch.puls_ts_window)`.
- Physics table: `dataQC = data_ch[is_physical .&& .!is_pulser]`.
- Pulser table: `dataPulser = data_ch[is_physical .&& is_pulser]`.

---

### QC labels and cuts (what exactly is cut)

QC columns are created by evaluating string expressions from YAML via `ljl_propfunc` on the DSP table. The default calibration QC config defines the following labels and the final selection:

```
ml:           "qc_label == 0"
is_valid_t0:  "42µs < t0 && t0 < 52µs"
is_valid_t50: "42µs < t50 && t50 < 52µs"
is_pileup:    "inTrace_intersect > t0 + 2 * drift_time && inTrace_n > 1"
is_valid_e:   "e_trap > 0 && isfinite(e_trap) && e_zac > 0 && isfinite(e_zac) && e_cusp > 0 && isfinite(e_cusp)"
is_saturated: "n_sat_high > 0"
is_discharge: "n_sat_low > 0"

is_physical:  "ml && is_valid_t0 && is_valid_t50 && !is_pileup && is_valid_e && !is_discharge && !is_saturated"

is_trig:      "e_cusp_ctc_cal > 25keV"
is_baseline:  "!ml && !is_discharge && !is_saturated"
```

Notes
- `ml` enforces the DSP ML category to be 0 (“Normal”). Other AP‑SVM categories (1–13) are rejected when `ml` is required.
- `is_pileup` relies on derivative-based in-trace indicators from DSP.
- `is_valid_e` requires three independent energy estimators to be finite and positive for robustness.
- Baseline limit parameters (`blmean`, `blsigma`, `blslope`) exist in the YAML for histogram-based QC, but in this processor we use the expression-based booleans above. They can be incorporated into expressions if desired.

Two QC types in context
- Categorical ML QC (in DSP): `qc_label ∈ {0…13}` assigned upstream; used here via `ml` expression to keep only class 0 if configured.
- Numeric QC metrics (in DSP): baseline stats, saturation, in-trace pile‑up; used here inside boolean expressions (`is_saturated`, `is_discharge`, `is_pileup`, and timing/energy validity checks).

All evaluated QC booleans plus `is_physical` are written to the hit file under `<channel>/jlhit/qc`.

---

## Internal Functions

**get_data_key_for_channel(ds, ch::ChannelIdLike, det::DetectorIdLike)**
- **Returns:** `string` or `nothing`
- **Purpose:** Resolves channel vs detector name conflicts in HDF5 files (tries channel ID first, then detector name)

**read_raw_data_with_fallback(columns, l200, period, run, ch, det)**
- **Returns:** `Table` or `Array`
- **Purpose:** Robust data reading with fallback strategies for different HDF5 key formats and raw-data nesting. Tries standard `read_ldata` first; if it fails, iterates raw filekeys, opens each LH5, resolves data key (channel or detector), and extracts requested columns. Concatenates per-file results.

**ch_puls_cal(chinfo_puls::NamedTuple)**
- **Returns:** `(processed=Bool, log)`
- **Purpose:** Extracts pulser timestamps and DAQ energies from raw files for the designated pulser channel and writes tags to the `jlpls` tier. If already present and reprocess=false, it skips. These tags are later used to flag pulser coincidences with physics channels.

**ch_hit_cal(chinfo_ch::NamedTuple)**
- **Returns:** `(result=(sf, n_pulser), log, processed=Bool)`
- **Purpose:** Per-detector hit production. Steps:
  1) Load the detector’s combined DSP data from all `jldsp` files (using channel key; fallback to detector key if needed). Enforce a minimum statistics threshold.
  2) Build QC boolean columns by evaluating configured expressions via `ljl_propfunc` on the DSP table (e.g., ML label check, baseline windows, saturation flags, energy validity, timing validity, pile‑up). Then evaluate `is_physical` as the configured combination of these columns.
  3) Load pulser tags from the `jlpls` file and compute coincidence flags per event using `flag_coincidences` with the configured time window.
  4) Split the DSP table into physics (`dataQC`: `is_physical && !is_pulser`) and pulser (`dataPulser`: `is_physical && is_pulser`).
  5) Produce a raw energy spectrum plot (`e_trap`) before/after QC and pulser. Implementation details:
     - Binning with StatsBase.Histogram using a fixed ADC bin width; y-axis on log scale to reveal tails.
     - Three overlays: “Trap - before QC” (all events), “Trap - after QC” (physics), “Pulser” (coincident events).
     - Axis labels include energy in ADC and counts per bin; title via `get_plottitle(...)` with `<period>-<run>-<detector>`.
     - Saved using `LegendMakie.savelfig` to `$GENERATED_DATA_PATH/jlplt/cal/<period>/<run>/l200-p<period>-r<run>-<detector>-raw_energy_e_trap.png`.
  6) Write out `jlhit` with `qc/` (all QC columns plus `is_physical`), `pulserTag/` (boolean vector), `dataQC/`, and `dataPulser/`.
  7) Record the survival fraction `sf` and the number of pulser events `n_pulser`; return for per-period parameter aggregation.

---

## Outputs

**Data Tier:**
- **Path:** `$GENERATED_DATA_PATH/tier/jlhit/cal/<period>/<run>/`
- **Files:** `l200-<period>-r<run>-cal-<filekey>-<detector>.lh5` (per channel)
- **Structure:** `<channel>/jlhit/` with separate data groups:
  - `qc/`: QC cut results and `is_physical` flags
  - `pulserTag/`: Boolean array flagging pulser events
  - `dataQC/`: Physics events after QC cuts (excluding pulser)
  - `dataPulser/`: Pulser events after QC cuts

**Additional Files:**
- **Path:** `$GENERATED_DATA_PATH/tier/jlpls/cal/<period>/<run>/`
- **Files:** `l200-<period>-r<run>-cal-<filekey>-<pulser_channel>.lh5`
- **Structure:** `<pulser_channel>/jlpls/tags/` with pulser timestamps from raw data

**Plots:**
- **Path:** `$GENERATED_DATA_PATH/jlplt/cal/<period>/<run>/`
- **Files:** `l200-<period>-r<run>-<detector>-raw_energy_e_trap.png`
- **Content:** Energy spectra showing before/after QC cuts and pulser events

**Parameters:**
- **Path:** `$GENERATED_DATA_PATH/jlpar/rpars/qc/<period>/<run>.yaml`
- **Content:** QC results per detector:
  - `sf`: Survival fraction after all QC cuts (percentage)
  - `n_pulser`: Number of identified pulser events
  - Individual cut survival fractions for each QC criterion 