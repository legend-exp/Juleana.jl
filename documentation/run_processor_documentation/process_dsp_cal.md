# process_dsp_cal.jl

**Purpose:** Applies Digital Signal Processing to raw waveforms for calibration data, computing all physical parameters (energy, A/E, timing, etc.) using previously optimized filter parameters. This is the main production DSP step that processes all raw calibration data to create the jldsp tier used by subsequent analysis steps.

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

**Raw Data:**
- **Path:** `$RAW_DATA_PATH/<period>/<run>/`
- **Data Keys:** `waveform` (presummed), `daqenergy`, `timestamp` (per channel/detector in each file)

**Config:**
- **Path:** `$METADATA_PATH/jldataprod/config/dsp/`
- **Parameters:** DSP configuration including filter definitions, baseline windows, energy grids

**Parameters:**
- **Decay Times:** `$GENERATED_DATA_PATH/jlpar/rpars/pz/<period>/<run>.yaml` OR `$GENERATED_DATA_PATH/jlpar/ppars/pz/<period>/<run>.yaml` (from process_decay_time)
- **Filter Optimization:** `$GENERATED_DATA_PATH/jlpar/rpars/fltopt/<period>/<run>.yaml` OR `$GENERATED_DATA_PATH/jlpar/ppars/fltopt/<period>/<run>.yaml` (from process_filter_optimization) 
- **A/E Optimization:** `$GENERATED_DATA_PATH/jlpar/rpars/aoeopt/<period>/<run>.yaml` OR `$GENERATED_DATA_PATH/jlpar/ppars/aoeopt/<period>/<run>.yaml` (from process_aoe_optimization)
- **ML Model:** `$JLML_PATH/cal/<period>/<run>/l200-<period>-<run>-cal-<timestamp>-tier_jlml.lh5` (optional for QC)

---

## Functions

### 1. dsp_icpc_compressed()
**Location:** `LegendDSP.jl/src/dsp_icpc.jl:296`

**Parameters:**
```julia
dsp_icpc_compressed(
    data::Table,
    config::DSPConfig,
    τ::Quantity,
    pars_filter::PropDict;
    f_evaluate_qc::Function=missing
)
```

**Returns:**
- `dsp_results::Table`: complete per-event DSP table with baseline, timing, energies (trap/cusp/zac and robust estimators), A/E amplitudes, qdrift/lq, QC labels, saturation metrics, DC‑tagging, and metadata. See Outputs for field list.

**Purpose:** This is the main production DSP function that transforms raw **presummed and windowed waveforms** into all physical parameters needed for analysis. **Structured workflow per event:**

**Step 1: Waveform preparation and PZ**
- Decode both presummed (coarsely sampled) and windowed (fine window around the pulse) waveforms for the event.
- Estimate baseline on a configurable pre-trigger window. Compute baseline mean, spread, slope, and offset; subtract the baseline from both domains. When transferring baseline between domains, account for `presum_rate` so amplitudes remain consistent.
- Apply pole-zero (inverse CR) deconvolution using the detector-specific decay time `τ` (from pz). This removes the exponential tail imposed by the charge-sensitive preamplifier and restores a shape suitable for timing and energy filters.
- On the PZ-corrected waveform, compute tail statistics on a configured tail window (mean, sigma, slope, offset). These metrics are stored for quality monitoring and later cuts.

**Step 2: QC and saturation**
- Optional ML QC: if a classifier `f_evaluate_qc` is provided, classify each waveform and write `qc_label ∈ {0,…,13}` (AP‑SVM categories). If no model is provided, ML‑based labeling is skipped; waveforms are not rejected by ML.
- Compute saturation counts and consecutive saturation metrics using FADC bit depth and `presum_rate`.

QC labels (AP‑SVM)
- 0: Normal
- 1: Negative Going
- 2: Upwards Sloping
- 3: Downwards Sloping
- 4: Spike
- 5: Crosstalk
- 6: Slow Rise
- 7: Early Trigger
- 8: Late Trigger
- 9: Saturation
- 10: Soft Pileup
- 11: Hard Pileup
- 12: Bump
- 13: Noise Trigger

Implementation note: The SVM model is constructed upstream via `get_qc_ml_func(...)` and passed into `dsp_icpc_compressed` as `f_evaluate_qc`. The classifier itself is not defined inside `dsp_icpc_compressed`; the function only applies the provided evaluator to generate `qc_label`.

**Step 3: Timing and drift**
- Find `t0` as the first rising-edge threshold crossing above baseline plus a configurable multiple of the baseline sigma (parameters come from `t0_flt_pars` in the DSP config). Sub-sample interpolation is used to reduce binning effects.
- Compute fractional rise times `t10`, `t50`, `t80`, `t90`, `t99` as the first times the signal exceeds the corresponding percentage between baseline and the signal maximum. These are also obtained with interpolation for accuracy.
- Define the charge collection time `drift_time = t90 - t0`.
- Compute `qdrift` by integrating the PZ-corrected waveform in a window around `t0`; compute `lq` in a window around `t80`. Window extents and integration methods are controlled by the DSP config; local polynomial interpolation is used to stabilize boundaries.

**Step 4: Energy reconstruction (optimized and robust)**
- Apply multiple digital filters to the PZ-corrected waveform to estimate deposited energy:
  - Robust energies with fixed shaping: `e_10410`, `e_535`, `e_313`. These use canonical (rise-time, flat-top) settings chosen for stability across detectors and runs.
  - Optimized energies using per‑detector shaping from `fltopt`: `e_trap` (trapezoidal), `e_cusp` (cusp), `e_zac` (zero‑area cusp). The optimal `RT/FT` (or equivalent shaping constants) are read from the optimization parameters for each detector.
- For each filter, a `SignalEstimator` defines the pick‑off strategy (e.g., centered around `t50_pre` with an offset accounting for the filter length). The estimator selects a stable portion of the shaped signal (flat top or plateau) and takes an average or peak within that region to produce the energy estimate.
- For monitoring, the maximum of each shaped output and its sample time are stored (`e_*_max`, `t_*_max`).

**Step 5: A/E (pulse shape discrimination)**
- Differentiate the windowed waveform to obtain the current signal.
- Compute multiple current‑amplitude estimators:
  - `a_raw`: peak of the simple numerical derivative (no smoothing).
  - `a_sg`: peak after applying a Savitzky–Golay (SG) filter with optimized window length and polynomial degree from `aoeopt` (per detector and filter type).
  - `a_60`, `a_100`: peaks using fixed SG windows (e.g., 60 ns, 100 ns) for cross‑checks and stability studies.
- The A/E ratio is then formed by dividing the chosen current amplitude by the chosen energy estimator (typically `e_trap`). A/E is used downstream to separate single‑site from multi‑site interactions.

**Step 6: In-trace pile‑up and current timing**
- On the presummed domain (with SG window scaled by `presum_rate/2`), look for multiple significant peaks in the derivative before the main rise. This flags overlapping pulses inside the readout window.
- Record `inTrace_n` (number of pile‑up candidates) and `inTrace_intersect` (approximate intersection positions from curvature/second-derivative tests). These help reject pile‑up in later analysis.
- Compute `t50_current` on the derivative to characterize the rise of the current pulse and to cross‑check the timing obtained from the charge domain.

**Step 7: Inverted analysis (DC tagging)**
- Invert waveforms (multiply by −1) and compute inverted robust energies and `t0_inv` to tag DC behavior.

All steps operate per event with per‑detector parameters from pz/fltopt/aoeopt.

**operates per event, processes all events from one detector using that detector's individually optimized parameters**

### 2. get_qc_ml_func()
**Location:** `Github/LegendDSP.jl/src/ml.jl:5`

**Parameters:**
```julia
get_qc_ml_func(
    dwts_norm::Matrix{<:Real},
    dc_labels::Vector{<:Real}, 
    hyperparams::PropDict
)
```

**Returns:**
- `f_evaluate_qc`: Function for ML-based waveform quality control

**Purpose:** Loads a trained Support Vector Machine (SVM) model that automatically identifies waveform quality classes based on discrete wavelet transform features. The model was trained on labeled categories (0–13). When applied during DSP, it assigns `qc_label` per event; downstream processors decide how to use the label (e.g., cuts). It does not by itself remove events here.

QC pipeline clarification
- ML labeling is applied within the DSP step when `f_evaluate_qc` is provided, independent of energy reconstruction. Each event is assigned a category 0–13.
- Additional non‑ML QC quantities produced by DSP (for downstream use) include: baseline statistics (`blsigma`, `blslope`), saturation metrics (`n_sat_*`, `t_sat_*`), and in‑trace pile‑up indicators (`inTrace_*`).

---

## Internal Functions

**get_data_key_for_channel(ds, ch::ChannelIdLike, det::DetectorIdLike)**
- **Returns:** `string` or `nothing` - data key for channel access
- **Purpose:** Resolves channel vs detector name conflicts in HDF5 files (tries channel ID first, then detector name)

**filekey_dsp(fk::FileKey)**
- **Returns:** `(timer, log, processed=Bool)` - processing results per file
- **Purpose:** Main processing logic **per file** - opens one raw HDF5 file, processes all channels within that file using their respective optimized parameters from previous processors, saves all DSP results to corresponding jldsp file. This file-based approach is efficient for large datasets as it minimizes file I/O operations.

---

## Outputs

**Data Tier:**
- **Path:** `$GENERATED_DATA_PATH/tier/jldsp/cal/<period>/<run>/`
- **Files:** `l200-<period>-r<run>-cal-<filekey>.lh5` (one per raw file)
- **Structure:** `<channel>/jldsp/` with complete DSP parameter tables per channel
- **Content:** **Complete DSP parameter set per event:**
  
  **Baseline Parameters:**
  - `blmean`, `blsigma`, `blslope`, `bloffset`: Baseline statistics
  - `blfc`: Baseline from FlashCam firmware
  
  **Energy Reconstruction:**
  - `e_trap`: Optimized trapezoidal filter energy (main energy estimator)
  - `e_cusp`: Optimized CUSP filter energy (alternative for noise)
  - `e_zac`: Optimized ZAC filter energy (zero-area for pile-up rejection)
  - `e_10410`, `e_535`, `e_313`: Robust energy estimators (RT/FT in µs)
  - `e_trap_max`, `e_cusp_max`, `e_zac_max`: Maximum filter outputs
  - `t_trap_max`, `t_cusp_max`, `t_zac_max`: Timing of maximum outputs
  - `e_max`, `e_min`: Waveform extrema (windowed)
  - `e_max_pre`, `e_min_pre`: Waveform extrema (presummed)
  
  **Timing Parameters:**
  - `t0`: Pulse start time
  - `t10`, `t50`, `t80`, `t90`, `t99`: Threshold crossing times (% of max)
  - `t50_pre`: 50% threshold on presummed waveform
  - `t50_current`: Current rise timing
  - `drift_time`: Charge collection time (t90-t0)
  
  **A/E Parameters (Pulse Shape Discrimination):**
  - `a_sg`: Current amplitude with optimized Savitzky-Golay filter
  - `a_60`, `a_100`: Current amplitude with 60ns, 100ns SG filters
  - `a_raw`: Raw current amplitude (no smoothing)
  
  **Advanced Parameters:**
  - `qdrift`: Charge drift parameter
  - `lq`: Liquid scintillator veto parameter
  - `tail_τ`, `tail_mean`, `tail_sigma`: Tail characteristics after PZ correction
  - `tailmean`, `tailsigma`, `tailslope`, `tailoffset`: Tail statistics
  
  **Quality Control:**
  - `qc_label`: ML-based waveform quality assessment
  - `inTrace_intersect`, `inTrace_n`: In-trace pile-up detection
  - `n_sat_low`, `n_sat_high`: Saturation sample counts
  - `n_sat_low_cons`, `n_sat_high_cons`: Consecutive saturation samples
  - `t_sat_lo`, `t_sat_hi`: Saturation timing
  
  **Inverted Analysis (DC Tagging):**
  - `e_10410_inv`, `e_313_inv`: Energy from inverted waveforms
  - `t0_inv`: Start time on inverted waveform
  
  **Metadata:**
  - `timestamp`: Event timestamp
  - `eventID_fadc`: FADC event ID
  - `e_fc`: FlashCam DAQ energy
  - `deadtime`: System deadtime

**Plots:**
- **Path:** None (this processor produces no plots)

**Parameters:**
- **Path:** None (this processor produces no parameters, only uses existing ones) 