# process_lq_calibration_cut.jl

**Purpose:** Calibrate and classify the LQ (liquid scintillator veto) parameter per detector to reject external gamma and muon-induced backgrounds. The processor (1) reads calibrated hit data, (2) applies charge-trapping correction in the DEP region, (3) normalizes LQ in σ units using a truncated Gaussian fit around DEP, (4) selects a high-side cut in σ units, and (5) validates performance at reference peaks and around Qββ. It writes run-level `rpars/lq` and produces QA plots.

---

## Path Variables

```
$RAW_DATA_PATH       = .../legend_data_production/raw_compressed
$METADATA_PATH       = .../legend_data_production/jl-v0.5.0/legend-metadata_new_yaml_p14
$GENERATED_DATA_PATH = .../legend_data_production/jl-v0.5.0/generated
$JLPEAKS_PATH        = .../legend_data_production/jlpeaks
$JLML_PATH           = .../legend_data_production/jlml
```

---

## Inputs

**Hit Data (cal):**
- **Path:** `$GENERATED_DATA_PATH/tier/jlhit/cal/<period>/<run>/`
- **Data Keys:** physics hits after QC from `process_hit_cal`
  - Energy (calibrated): choose the configured estimator (e.g., `e_cusp_cal` or `e_cusp_ctc_cal`)
  - LQ parameter: `lq` (per-hit LSV response)
  - Drift/charge proxy: `qdrift` or effective drift time `dt_eff` (as configured)
  - Timing, QC flags

**Energy Calibration Parameters:**
- **Path:** `$GENERATED_DATA_PATH/jlpar/rpars/ecal/<period>/<run>.yaml`
- **Content:** Energy mapping for the estimator used in LQ calibration. Provides DEP centroid `μ_DEP` and width `σ_DEP` for LQ normalization windows.

**LQ Config:**
- **Path:** `$METADATA_PATH/jldataprod/config/psd/...yaml` (resolved via `dataprod_config(l200).psd(filekey).lq`)
- **Parameters:**
  - `e_type` (e.g., `e_cusp_ctc_cal`)
  - `lq_types`, `lq_funcs` (e.g., `"lq / e_cusp"`)
  - `qdrift_expression` or `dt_eff` definition
  - CTC (DEP-region) settings: `dep_mu`, `ctc_dep_edgesigma`, `ctc_lq_precut_relative_cut`, `ctc_driftime_cutoff_method`, `lq_outlier_sigma`, `dt_eff_outlier_sigma`, `ctc_dt_eff_low_quantile`, `ctc_dt_eff_high_quantile`, `pol_fit_order`
  - Normalization: `dep_sideband_sigma`, `cut_truncation_sigma`, `high_cut_sigma`
  - Validation: `lq_peaks` (names and windows), `qbb`, `qbb_window`

---

## Functions

### 1) lq_ctc_correction()
**Location:** `LegendSpecFits.jl/src/lqcut.jl`

**Parameters:**
```julia
lq_ctc_correction(
    lq::Vector{<:AbstractFloat},
    dt_eff::Vector{<:Unitful.RealOrRealQuantity},
    e_cal::Vector{<:Unitful.Energy{<:Real}},
    dep_µ::Unitful.AbstractQuantity,
    dep_σ::Unitful.AbstractQuantity;
    ctc_dep_edgesigma::Float64=3.0,
    ctc_lq_precut_relative_cut::Float64=0.25,
    lq_outlier_sigma::Float64=2.0,
    ctc_driftime_cutoff_method::Symbol=:percentile,
    dt_eff_outlier_sigma::Float64=2.0,
    pol_fit_order::Int=1,
)
```

**Returns:**
- `result::NamedTuple` with fields
  - `func::String`: LQ CTC correction expression (polynomial in drift time), to be subtracted from raw LQ
  - `fit_result`: polynomial fit details (coefficients, uncertainties)
  - `box_constraints`: numeric bounds used for LQ and drift time selection
- `report`: diagnostic structure for QA plots (scatter with masks, fit lines, residuals)

**Detailed workflow:**
- Build DEP mask on energy: select events with `|E − μ_DEP| ≤ ctc_dep_edgesigma × σ_DEP`.
- Precut on relative LQ: keep events below `ctc_lq_precut_relative_cut` of the LQ spread around the mode to suppress non-DEP outliers (robust MAD-based estimate).
- Drift-time windowing: keep `dt_eff` within `[low_quantile, high_quantile]` if `:percentile`, or the configured method.
- Outlier rejection: iteratively remove points beyond `lq_outlier_sigma` in LQ and `dt_eff_outlier_sigma` in drift-time relative to robust location/scale.
- Polynomial fit: fit `LQ_raw = p0 + p1·dt_eff + p2·dt_eff^2 + …` up to `pol_fit_order`.
- Correction: define `LQ_ctc = LQ_raw − (p1·dt_eff + p2·dt_eff^2 + …)` (subtract drift-dependent component; constant term absorbed by later normalization).
- Save `func` (as a string expression in `dt_eff`), `fit_result` (coefficients, covariance), and `box_constraints` used for masking.

**Purpose:** Correct position/drift-time dependence of LQ in the DEP region to make LQ uniform across the detector volume before normalization and classification.

### 2) lq_norm()
**Location:** `LegendSpecFits.jl/src/lqcut.jl`

**Parameters:**
```julia
lq_norm(
    dep_µ::Unitful.Energy,
    dep_σ::Unitful.Energy,
    e_cal::Vector{<:Unitful.Energy},
    lq_classifier::Vector{<:AbstractFloat};
    dep_sideband_sigma::Float64=4.5,
    cut_truncation_sigma::Float64=2.0,
    uncertainty::Bool=true,
)
```

**Returns:**
- `result::NamedTuple` with fields
  - `func::String`: normalized LQ expression (σ units), `LQ_norm = (LQ_ctc − μ_LQ)/σ_LQ`
  - `fit_result`: truncated-Gaussian fit details after sideband subtraction (μ_LQ, σ_LQ, errors)
- `report`: histogram(s) and fit details for QA (raw/sideband-subtracted/fit overlays)

**Detailed workflow:**
- Define DEP ROI: `|E − μ_DEP| ≤ cut_truncation_sigma × σ_DEP` (fit domain); keep only `LQ_ctc` inside this ROI.
- Sidebands for background: left `[μ_DEP − dep_sideband_sigma·σ_DEP, μ_DEP − cut_truncation_sigma·σ_DEP]`, right `[μ_DEP + cut_truncation_sigma·σ_DEP, μ_DEP + dep_sideband_sigma·σ_DEP]`.
- Build histograms: compute DEP and sideband histograms with a common binning; scale the sum of sidebands to match the DEP ROI width; subtract to estimate the signal-only LQ distribution.
- Fit model: fit a truncated Gaussian to the background-subtracted distribution within the fit ROI; extract `μ_LQ`, `σ_LQ` with uncertainties and GoF metrics.
- Normalize: define `LQ_norm = (LQ_ctc − μ_LQ)/σ_LQ` and emit `func` as a string expression for downstream evaluation.

**Purpose:** Normalize LQ around DEP so that one unit corresponds to one σ; enables a simple global high-side LQ cut in σ units.

### 3) get_peaks_survival_fractions()
**Location:** `LegendSpecFits.jl/src/aoe_cut.jl`

**Parameters (LQ usage):**
```julia
get_peaks_survival_fractions(
    lq_norm::AbstractVector{<:Real},
    e_cal::AbstractVector{<:Unitful.Energy},
    peaks::Vector{<:Unitful.Energy},
    names::Vector{Symbol},
    wl::Vector{<:Unitful.Energy},
    wr::Vector{<:Unitful.Energy},
    highcut::Real;
    bin_width_window::Unitful.Energy=5u"keV",
    sigma_high_sided::Bool=true,
    fit_funcs::Vector{Symbol}=fill(:trunc_gauss_bck, length(peaks)),
    uncertainty::Bool=true,
)
```

**Returns:**
- `result::Dict{Symbol,NamedTuple}` with per-peak survival fractions `{val, err}` after applying the high-side LQ cut; includes per-peak fit quality.
- `report`: plot-ready details (before/after spectra, fits, residuals).

**Purpose:** Validate LQ high-side cut performance at key calibration lines (DEP/SEP/FEP) using consistent windows and fit models.

### 4) get_continuum_survival_fraction()
**Location:** `LegendSpecFits.jl/src/aoe_cut.jl`

**Parameters (LQ usage):**
```julia
get_continuum_survival_fraction(
    lq_norm::AbstractVector{<:Real},
    e_cal::AbstractVector{<:Unitful.Energy},
    qbb::Unitful.Energy,
    qbb_window::Unitful.Energy,
    highcut::Real;
    sigma_high_sided::Bool=true,
)
```

**Returns:** `sf::{val, err}` — continuum survival around Qββ after the LQ cut, with uncertainty propagated from counts and fit/statistical treatment.

**Purpose:** Assess LQ cut impact near Qββ, the main physics ROI.

---

## Internal Functions

1) build_dep_window(ecal::NamedTuple, cfg::NamedTuple) — processors/process_lq_calibration_cut.jl:≈L35–L70
- **Input:** `μ_DEP`, `σ_DEP` from `ecal`; `ctc_dep_edgesigma`, `cut_truncation_sigma`
- **Returns:** `(roi_dep, sideband_left, sideband_right)` energy windows for CTC and normalization
- **Purpose:** Centralizes consistent DEP/sideband window definitions.

2) compute_dt_eff(ch_data::TableLike, cfg::NamedTuple) — processors/process_lq_calibration_cut.jl:≈L72–L110
- **Input:** `jlhit` fields; `qdrift_expression` or explicit `dt_eff` selection from config
- **Returns:** `Vector{<:RealOrRealQuantity}` of effective drift-time values
- **Purpose:** Provides the drift-time proxy used by the CTC step; supports multiple expressions.

3) lq_ctc_mask_and_fit(lq, dt_eff, e_cal, windows, cfg) — processors/process_lq_calibration_cut.jl:≈L112–L196
- **Input:** `lq`, `dt_eff`, `e_cal`, DEP window, outlier and percentile settings
- **Returns:** `(func, fit_result, box_constraints, report)`
- **Purpose:** Implements energy masking, outlier rejection, polynomial fit, and builds CTC correction.

4) lq_dep_normalization(lq_ctc, e_cal, windows, cfg) — processors/process_lq_calibration_cut.jl:≈L198–L252
- **Input:** CTC-corrected `lq_ctc`, energy, DEP/sideband windows, `dep_sideband_sigma`, `cut_truncation_sigma`
- **Returns:** `(func, fit_result, report)`
- **Purpose:** Sideband subtraction and truncated Gaussian fit; emits normalized LQ expression and QA.

5) evaluate_sf_and_qbb(lq_norm, e_cal, cfg) — processors/process_lq_calibration_cut.jl:≈L254–L320
- **Input:** normalized LQ, energy, peak definitions, `qbb`, `qbb_window`, `high_cut_sigma`
- **Returns:** `peaks::Dict{Symbol,NamedTuple}`, `qbb::NamedTuple`, `reports`
- **Purpose:** Compute per-peak and Qββ survival fractions for the chosen high-side cut.

6) ch_lq_cut(chinfo_ch::NamedTuple) — processors/process_lq_calibration_cut.jl:≈L322–L420
- **Input:** `chinfo_ch` with fields `channel`, `detector`; uses LQ config, `ecal` rpars, and `jlhit` data
- **Returns:** `(result=Dict{Symbol,NamedTuple}, log=Dict{Symbol,NamedTuple}, processed=Dict{Symbol,Bool})`
- **Purpose:** Orchestrates the full per-detector workflow: compute `dt_eff`, run LQ CTC, perform DEP normalization, derive high-side cut, evaluate SFs, write plots, and assemble `rpars/lq` entries.

---

## Outputs

**Parameters (run-level rpars):**
- **Path:** `$GENERATED_DATA_PATH/jlpar/rpars/lq/<period>/<run>.yaml`
- **Structure (per detector):**
  - `lq`: `func` (normalized LQ expression), `drift_result` (`func`, `fit_result`, `box_constraints`), `norm_fit` (`dep_mu/σ`, `gof`), optional `stats`
  - `lq_classifier`: `highcut` (in σ units), `peaks[<name>].sf` (survival fractions), `qbb.sf`

**Plots:**
- **Path:** `$GENERATED_DATA_PATH/jlplt/cal/<period>/<run>/`
- **Files:**
  - `l200-p<period>-r<run>-<detector>-lq_ctc_DEP_<lq_type>.png` (CTC at DEP)
  - `l200-p<period>-r<run>-<detector>-lq_ctc_<lq_type>.png` (CTC full spectrum)
  - `l200-p<period>-r<run>-<detector>-lq_dep_normalization_<lq_type>.png` (DEP normalization fit)
  - `l200-p<period>-r<run>-<detector>-lq_sidebands_<lq_type>.png` (sideband subtraction)
  - `l200-p<period>-r<run>-<detector>-lq_sideband_position_<lq_type>.png` (DEP/sideband positions)
  - `l200-p<period>-r<run>-<detector>-lq_classified_<lq_classifier>.png` (normalized LQ vs energy with cut)
  - `l200-p<period>-r<run>-<detector>-lq_energy_after_<lq_classifier>.png` (before/after cut spectra)
  - `l200-p<period>-r<run>-<detector>-lq_cut_fraction_<lq_classifier>.png` (survival fraction vs energy)

**Notes:**
- Energy calibration (ecal) for the chosen `e_type` must exist.
- High-side LQ cut is configured in σ units; pick per detector to balance background rejection and signal acceptance. 