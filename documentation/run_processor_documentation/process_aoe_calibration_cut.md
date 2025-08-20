# process_aoe_calibration_cut.jl

**Purpose:** Calibrate A/E (Amplitude-over-Energy) per detector and A/E type, then optimize A/E cuts (low/high) for PSD between SSE and MSE. The processor (1) reads calibrated hit data, (2) constructs Compton-band histograms across energy, (3) fits μ(E), σ(E) correction functions (optionally a combined fit), (4) applies optional charge-trapping correction using qdrift, (5) finds optimal A/E cuts at the DEP target survival fraction, and (6) validates performance at reference peaks and around Qββ. It writes run-level `rpars/aoe` and produces QA plots.

---

## Path Variables

```
$RAW_DATA_PATH      = .../legend_data_production/raw_compressed
$METADATA_PATH      = .../legend_data_production/jl-v0.5.0/legend-metadata_new_yaml_p14
$GENERATED_DATA_PATH= .../legend_data_production/jl-v0.5.0/generated
$JLPEAKS_PATH       = .../legend_data_production/jlpeaks
$JLML_PATH          = .../legend_data_production/jlml
```

---

## Inputs

**Hit Data (cal):**
- **Path:** `$GENERATED_DATA_PATH/tier/jlhit/cal/<period>/<run>/`
- **Data Keys:** physics hits after QC from `process_hit_cal`
  - Energies (calibrated): e.g., `e_cusp_cal`, `e_cusp_ctc_cal`, `e_trap_cal`, ... (as configured via `e_type`)
  - Current amplitudes: `a_sg`, `a_100`, `a_raw`
  - Drift/charge: `qdrift`
  - Timing, QC flags

**Energy Calibration Parameters:**
- **Path:** `$GENERATED_DATA_PATH/jlpar/rpars/ecal/<period>/<run>.yaml`
- **Content:** ADC→keV energy mapping for the configured estimator used to compute `e_*_cal`.

**AoE PSD Config:**
- **Path:** `$METADATA_PATH/jldataprod/config/psd/...yaml` (resolved via `dataprod_config(l200).psd(filekey).aoe`)
- **Parameters:**
  - `e_type` (e.g., `e_cusp_ctc_cal`), `aoe_funcs` (e.g., `a_sg / e_cusp`, `a_100 / e_cusp`, `a_raw / e_cusp`)
  - `compton_bands`, `compton_window`, `p_value`
  - `use_combined_fit`, `apply_ctc`, `qdrift_expression`
  - Cut search: `dep`, `dep_window`, `dep_cut_search_target_sf`, `dep_cut_search_interval`, `dep_cut_search_rtol`, `dep_cut_search_maxiters`, `dep_cut_search_fixed_position`, `sigma_high_sided`, `dep_cut_search_fit_func`
  - Validation: `aoe_peaks`, `aoe_peaks_names`, `aoe_peaks_fit_funcs`, `aoe_peaks_windows_left/right`, `aoe_peaks_bin_width_window`, `qbb`, `qbb_window`

---

## Functions

### 1) generate_aoe_compton_bands()
**Location:** `LegendSpecFits.jl/src/aoefit.jl`

**Parameters:**
```julia
generate_aoe_compton_bands(
    aoe::AbstractVector{<:Real},
    e::AbstractVector{<:Unitful.Energy},
    compton_bands::AbstractVector{<:Unitful.Energy},
    compton_window::Unitful.Energy,
)
```

**Returns:**
- `peakhists::Vector{<:Histogram}` — A/E histograms within each Compton band
- `peakstats::StructArray` — per-band peak stats (amplitude, centroid, width)

**Purpose:** Build energy-binned A/E histograms across the configured Compton energy bands to probe the energy dependence of A/E.

### 2) fit_aoe_compton()
**Location:** `LegendSpecFits.jl/src/aoefit.jl`

**Parameters:**
```julia
fit_aoe_compton(
    peakhists::Vector{<:Histogram},
    peakstats::StructArray,
    compton_bands::AbstractVector{<:Unitful.Energy};
    uncertainty::Bool=true,
    fit_func::Symbol=:aoe_one_bck,
)
```

**Returns:**
- `result::Dict{EnergyBand, NamedTuple}` with fields (per band):
  - `μ::Float64`, `σ::Float64`, `n`, `background`, `step_amplitude`, `gof` (incl. `pvalue`, `residuals_norm`)
- `report` — plot-ready details for QA

**Purpose:** Fit each band’s A/E histogram to extract μ(E), σ(E) and quality metrics.

### 3) fit_aoe_corrections()
**Location:** `LegendSpecFits.jl/src/aoe_fit_calibration.jl`

**Parameters:**
```julia
fit_aoe_corrections(
    compton_bands::AbstractVector{<:Unitful.Energy},
    μ::AbstractVector{<:Real},
    σ::AbstractVector{<:Real};
    aoe_expression::AbstractString,
    e_expression::AbstractString,
)
```

**Returns:**
- `result::NamedTuple` with fields
  - `func::String` (correction expression), `par_μ::Vector{Float64}`, `par_σ::Vector{Float64}`
  - `gof` summary, `report_μ`, `report_σ` (plot inputs)

**Purpose:** Construct energy-dependent corrections for A/E mean and width.

### 4) fit_aoe_compton_combined()
**Location:** `LegendSpecFits.jl/src/aoefit.jl`

**Parameters (core):**
```julia
fit_aoe_compton_combined(
    peakhists, peakstats, compton_bands, single_fit;
    e_expression::AbstractString, aoe_expression::AbstractString,
    uncertainty::Bool=true,
)
```

**Returns:** `result` (combined correction with `func`, parameters, GoF), `report_µ`, `report_σ`.

**Purpose:** Joint μ/σ(E) correction for improved stability; optional path when `use_combined_fit=true`.

### 5) LegendSpecFits.ctc_aoe()
**Location:** `LegendSpecFits.jl` (CTC utilities)

**Parameters (core):** `ctc_aoe(aoe_corr, e_cal, qdrift_e, bands; aoe_expression, qdrift_expression)`

**Returns:** `NamedTuple` with `fct::Vector`, `func::String`, and `report`.

**Purpose:** Apply charge-trapping correction to A/E using qdrift vs energy.

### 6) get_low_aoe_cut()
**Location:** `LegendSpecFits.jl/src/aoe_cut.jl`

**Parameters (core):**
```julia
get_low_aoe_cut(
    aoe::AbstractVector{<:Real}, e::AbstractVector{<:Unitful.Energy};
    dep, window, cut_search_interval, bin_width_window,
    rtol, maxiters, dep_sf, fixed_position, sigma_high_sided,
    fit_func::Symbol, uncertainty::Bool=true,
)
```

**Returns:** `result` (`lowcut`, `highcut`, `sf`) and `report` (plots/specs).

**Purpose:** Optimize AoE cuts at the DEP target survival fraction and derive a high-side cut.

### 7) get_peaks_survival_fractions()
**Location:** `LegendSpecFits.jl/src/aoe_cut.jl`

**Parameters (core):** `(aoe, e, peaks, names, wl, wr, cut; bin_width_window, sigma_high_sided, fit_funcs, uncertainty)`

**Returns:** per-peak SFs (`:Tl208SEP`, `:Tl208FEP`, ...), `report`.

**Purpose:** Validate AoE performance at specific lines with/without high-side cut.

### 8) get_continuum_survival_fraction()
**Location:** `LegendSpecFits.jl/src/aoe_cut.jl`

**Parameters (core):** `(aoe, e, qbb, qbb_window, cut; sigma_high_sided)`

**Returns:** `sf` around Qββ and `report`.

**Purpose:** Assess continuum rejection near Qββ.

---

## Internal Functions

1) ch_aoe_cut(chinfo_ch::NamedTuple) — processors/process_aoe_calibration_cut.jl:≈L31–L396
- **Input:** `chinfo_ch` with fields `channel`, `detector`; uses AoE config and `jlhit` for data
- **Returns:** `(result=Dict{Symbol,NamedTuple}, log=Dict{Symbol,NamedTuple}, processed=Dict{Symbol,Bool})`
- **Purpose:** Per-detector workflow: compute calibrated energy and AoE, normalize; build Compton bands; fit μ/σ(E) corrections (optionally combined); optional AoE CTC; compute AoE cuts and survival fractions; save plots; aggregate results for `rpars/aoe`.

---

## Outputs

**Parameters (run-level rpars):**
- **Path:** `$GENERATED_DATA_PATH/jlpar/rpars/aoe/<period>/<run>.yaml`
- **Structure (per detector):**
  - `<aoe_type>`: `func` (corrected AoE expression), `correction` (μ/σ coefficients, `gof`), optional `ctc` (`fct`, `func`)
  - `<aoe_type>_classifier`: `lowcut`, `highcut`, `peaks.low/ds[:Tl208SEP/:Tl208FEP].sf`, `qbb.low/ds.sf`

**Plots:**
- **Path:** `$GENERATED_DATA_PATH/jlplt/cal/<period>/<run>/`
- **Files:**
  - `l200-<period>-r<run>-<detector>-aoe_uncalibrated_<aoe_type>.png` (raw A/E vs energy)
  - `l200-<period>-r<run>-<detector>-compton_bands_mu_<aoe_type>.png` (μ(E) correction QA)
  - `l200-<period>-r<run>-<detector>-compton_bands_sigma_<aoe_type>.png` (σ(E) correction QA)
  - `l200-<period>-r<run>-<detector>-aoe_ctc_<aoe_type>.png` (AoE CTC QA, if applied)
  - `l200-<period>-r<run>-<detector>-aoe_normalized_<aoe_type>.png` (corrected A/E vs energy)
  - `l200-<period>-r<run>-<detector>-aoe_energy_afterAoE_zoom_<aoe_classifier>.png` (cut QA)
  - `l200-<period>-r<run>-<detector>-aoe_peaks_ds_sf_<aoe_classifier>.png` (SF at lines)

**Notes:**
- Energy mapping (ecal) must exist for the configured `e_type`.
- Choose AoE type(s) and classifiers per config to maximize downstream PSD performance. 