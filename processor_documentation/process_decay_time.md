# process_decay_time.jl

**Purpose:** Extract per-detector decay-time constants from jlpeaks waveforms for pole-zero correction calibration. Steps: load presummed peak waveforms, optionally apply ML-based QC, compute decay times via DSP, derive histogram-based cuts, fit a truncated Gaussian to estimate the decay time and its uncertainty, and persist results to rpars.

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

**Peak Data:**
- **Path:** `$JLPEAKS_PATH/<period>/<run>/l200-<period>-<run>-cal-<detector>.lh5`
- **Data Keys:** `waveform_presummed` (from specific peak, e.g., `Tl208FEP`)

**Config:**
- **Path:** `$METADATA_PATH/jldataprod/config/dsp/`
- **Parameters:** 
  - `min_tau`: Minimum decay time for fitting range
  - `max_tau`: Maximum decay time for fitting range  
  - `nbins`: Number of bins for histogram analysis
  - `rel_cut_fit`: Relative cut level for peak fitting
  - `peakname`: Peak name to use (e.g., `Tl208FEP`)
  - `qc`: Quality cut string for waveform selection
  - `max_wvfs`: Maximum number of waveforms to process
  - `bl_window`: Baseline window for DSP
  - `tail_window`: Tail window for decay time extraction

**Parameters:**
- **ML Model:** `$JLML_PATH/cal/<period>/<run>/l200-<period>-<run>-cal-<timestamp>-tier_jlml.lh5` (optional for QC)
- **Existing Parameters:** `$GENERATED_DATA_PATH/jlpar/rpars/pz/<period>/<run>.yaml` (for reprocess check)

---

## Functions

### 1. dsp_qc_flt_optimization_compressed()
**Location:** `LegendDSP.jl/src/dsp_filter_optimization.jl:17`

**Parameters:**
```julia
dsp_qc_flt_optimization_compressed(
    wvfs::ArrayOfRDWaveforms,
    dsp_config::DSPConfig,
    τ::Unitful.Time,
    f_evaluate_qc::Function
)
```

**Returns:**
- `dsp_qc`: per-event DSP/QC feature structure used to evaluate the QC expression
  - Typically includes baseline metrics, pulse-shape features, and normalization values (implementation-dependent)

**Purpose:** Compute QC features for presummed waveforms and, with an ML-evaluated scoring function, enable selection (masking) of acceptable events prior to decay-time extraction.

### 2. dsp_decay_times()
**Location:** `LegendDSP.jl/src/dsp_decaytime.jl:10-25`

**Parameters:**
```julia
dsp_decay_times(
    wvfs::ArrayOfRDWaveforms, 
    bl_window::ClosedInterval{<:Unitful.Time}, 
    tail_window::ClosedInterval{<:Unitful.Time}
)
```

**Returns:**
- `decay_times::Vector{<:Unitful.Time}`: one decay-time constant per waveform (typically µs)

**Purpose:** Using baseline/tail windows and DSP settings (either passed directly or via `dsp_config`), compute the exponential tail time constant τ for each presummed waveform.

### 3. cut_single_peak()
**Location:** `LegendSpecFits.jl/src/simple_cuts.jl:12`

**Parameters:**
```julia
cut_single_peak(
    x::Vector{<:Unitful.RealOrRealQuantity}, 
    min_x::T, 
    max_x::T; 
    n_bins::Int=-1, 
    relative_cut::Float64=0.5, 
    n_tries::Int=5
)
```

**Returns:**
- `cuts::NamedTuple{(:low,:high,:max)}` with:
  - `low`, `high`: boundaries (same units as `x`) for the fit window around the dominant peak
  - `max`: histogram mode position used as a reference

**Purpose:** Build a robust fitting window around the main peak of the decay-time distribution via histogramming and relative-height criteria.

### 4. fit_single_trunc_gauss()
**Location:** `LegendSpecFits.jl/src/singlefit.jl:12`

**Parameters:**
```julia
fit_single_trunc_gauss(
    x::Vector{<:Unitful.RealOrRealQuantity}, 
    cuts::NamedTuple{(:low, :high, :max)}
)
```

**Returns:**
- `result`: fit object containing at least `μ` (mean, unitful) and `σ` (std, unitful). It may also include goodness-of-fit (χ², dof, p-value), covariance, and convergence flags depending on backend.
- `report`: structured fit report for plotting (histogram within cuts, fitted curve, cut boundaries, optional residuals)
 
**Purpose:** Fit a truncated Gaussian within the selected `cuts` to obtain a stable estimate of decay time and its spread, and produce a report used to render the QA plot.

---

## Internal Functions 

1) ch_decay_time(chinfo_ch::NamedTuple) — processors/process_decay_time.jl:L50-L146
- **Input:** `channel`, `detector`; effective configs `dsp_config_ch`, `pz_config_ch`; `filekey`
- **Purpose:**
  - Load presummed waveforms from jlpeaks at `peakname`
  - Optionally apply ML-based QC if model available
  - Compute decay times via `dsp_decay_times`, find cuts via `cut_single_peak`, fit via `fit_single_trunc_gauss`
  - Save decay-time plot and return per-detector parameters
- **Returns:** `(result=(τ, fit), processed=Bool, log)` with `τ::Unitful.Time`, `fit` including `μ`, `σ`, diagnostics

---

## Outputs

**Data Tier:**
- **Path:** None (parameters only)

**Plots:**
- **Path:** `$GENERATED_DATA_PATH/jlplt/cal/<period>/<run>/`
- **Files:** `l200-p<period>-r<run>-<detector>-decay_time.png` (decay-time distribution with cuts and fitted curve)
- **Description:** Histogram of per-event decay times (after QC), overlaid with the truncated-Gaussian fit and the selected cut window; used to validate peak shape, fit stability, and outlier handling.

**Parameters:**
- **Path:** `$GENERATED_DATA_PATH/jlpar/rpars/pz/<period>/<run>.yaml`
- **Structure:** `<detector>/τ` and `<detector>/fit` per detector
- **Content:** 
  - `τ`: Final decay time constant with unit, value, and uncertainty
  - `fit`: Complete fit results (μ, σ, goodness-of-fit statistics)
  - Saved in `rpars` (run-based parameters) for pole-zero correction 