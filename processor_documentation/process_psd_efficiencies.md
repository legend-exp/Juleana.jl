# process_psd_efficiencies.jl

**Purpose:** Compute comprehensive PSD (Pulse Shape Discrimination) efficiencies by combining calibrated A/E and LQ classifiers. The processor (1) reads calibrated hits, (2) evaluates corrected A/E and normalized LQ using run parameters, (3) applies configured classifier combinations (low-AoE, double-sided AoE with various high-side sigmas, with/without LQ), (4) fits validation peaks to obtain survival fractions before/after cuts, and (5) measures continuum survival around Qββ. It writes run-level `rpars/psd` and produces QA plots per detector and classifier.

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
  - Energy (calibrated): e.g., `e_cusp_cal` or `e_cusp_ctc_cal` (per config)
  - Current amplitudes and A/E components if needed (for recomputation as cross-check)
  - LQ parameter and drift proxy if needed (for diagnostics)

**A/E Parameters:**
- **Path:** `$GENERATED_DATA_PATH/jlpar/rpars/aoe/<period>/<run>.yaml`
- **Content:** A/E correction functions, optional CTC, and classifier cuts (low/high) per A/E type.

**LQ Parameters:**
- **Path:** `$GENERATED_DATA_PATH/jlpar/rpars/lq/<period>/<run>.yaml`
- **Content:** LQ drift correction and normalization function (σ units) and recommended high-side cut.

**PSD Config:**
- **Path:** `$METADATA_PATH/jldataprod/config/psd/...yaml`
- **Parameters:**
  - `psd_classifiers`: list of classifier names mapping to concrete choices of A/E type and high-side sigma, and whether LQ is combined (e.g., `low_aoe_sg_high_aoe_3_lq_classifier`)
  - Validation peaks: `psd_peaks`, `psd_peaks_windows_left/right`, `psd_peaks_fit_funcs`
  - Qββ window: `qbb`, `qbb_window`

---

## Functions

### 1) get_peaks_survival_fractions()
**Location:** `LegendSpecFits.jl/src/aoe_cut.jl`

**Parameters (used for PSD evaluation):**
```julia
get_peaks_survival_fractions(
    psd_parameter::AbstractVector{<:Real},
    e::AbstractVector{<:Unitful.Energy},
    peaks::Vector{<:Unitful.Energy},
    names::Vector{Symbol},
    wl::Vector{<:Unitful.Energy},
    wr::Vector{<:Unitful.Energy},
    psd_cut::Real;
    bin_width_window::Unitful.Energy=5u"keV",
    sigma_high_sided::Bool=true,
    fit_funcs::Vector{Symbol}=fill(:trunc_gauss_bck, length(peaks)),
    uncertainty::Bool=true,
)
```

**Returns:**
- `result::Dict{Symbol,NamedTuple}` per peak with `{sf::{val,err}, n_before, n_after, fit, gof}`
- `report` with plot inputs (before/after histograms, fits, residuals)

**Detailed workflow:**
- For each peak i with centroid `E_i` and windows `[wl_i, wr_i]`, select events with `e ∈ [E_i − wl_i, E_i + wr_i]`.
- Form the PSD mask `M`: typically `(AoE ≥ lowcut)` for low-only, `(lowcut ≤ AoE ≤ highcut)` for double-sided, optionally combined with `LQ ≤ highcut_LQ`.
- Build energy histograms before and after applying `M` using `bin_width_window`.
- Fit the chosen model `fit_funcs[i]` to before/after spectra to derive peak integrals robustly against background.
- Compute survival fraction `sf = I_after / I_before` with uncertainty from fit covariance and counting stats.
- Repeat per validation peak; aggregate into a dictionary keyed by peak name.

**Purpose:** Quantify peak-level survival after configured PSD cuts to validate signal efficiency and background rejection trade-offs.

### 2) get_continuum_survival_fraction()
**Location:** `LegendSpecFits.jl/src/aoe_cut.jl`

**Parameters:**
```julia
get_continuum_survival_fraction(
    psd_parameter::AbstractVector{<:Real},
    e::AbstractVector{<:Unitful.Energy},
    qbb::Unitful.Energy,
    qbb_window::Unitful.Energy,
    psd_cut::Real;
    sigma_high_sided::Bool=true,
)
```

**Returns:**
- `sf::{val,err}` for the `qbb ± qbb_window` interval
- `report` with before/after counts and optional spectrum overlays

**Detailed workflow:**
- Select events with `|e − qbb| ≤ qbb_window`.
- Apply the same PSD mask definition `M` used for peak SF.
- Compute survival `sf = N_after / N_before` and propagate uncertainty using binomial or Poisson approximations depending on counts.

**Purpose:** Provide the continuum survival near Qββ, the key metric driving 0νββ sensitivity.

---

## Internal Functions

1) resolve_classifier(classifier::Symbol, aoe_rpars, lq_rpars, cfg) — processors/process_psd_efficiencies.jl:≈L30–L92
- **Input:** classifier name from config, AoE and LQ rpars, PSD config
- **Returns:** `NamedTuple` with `aoe_type`, `lowcut`, `highcut`, `use_lq`, `lq_highcut`, and expressions `aoe_func`, `lq_func`
- **Purpose:** Binds a high-level classifier name to the concrete numeric cuts and expressions to be evaluated on hits.

2) evaluate_psd_parameters(hits, aoe_func, lq_func, e_type) — processors/process_psd_efficiencies.jl:≈L94–L150
- **Input:** `jlhit` table, expressions from rpars, selected energy field name
- **Returns:** `Vector` for `aoe_corr`, `lq_norm`, and `e_cal`
- **Purpose:** Evaluate corrected AoE and normalized LQ per hit using the stored string expressions and the chosen energy estimator.

3) build_masks(aoe_corr, lq_norm, cuts, mode) — processors/process_psd_efficiencies.jl:≈L152–L196
- **Input:** corrected AoE, normalized LQ, `cuts` from classifier, `mode ∈ {low, ds, low_lq, lq_ds}`
- **Returns:** boolean mask `M`
- **Purpose:** Construct consistent selection masks for the different PSD combinations.

4) compute_peak_sfs(e_cal, M_variants, peak_defs, cfg) — processors/process_psd_efficiencies.jl:≈L198–L278
- **Input:** energy, multiple masks (low, ds, low_lq, lq_ds), peak definitions and windows
- **Returns:** dictionaries of SF results and reports per mode
- **Purpose:** Call `get_peaks_survival_fractions` for each mode; collate results per peak.

5) compute_qbb_sfs(e_cal, M_variants, qbb_def, cfg) — processors/process_psd_efficiencies.jl:≈L280–L330
- **Input:** energy, masks, `qbb` and `qbb_window`
- **Returns:** SF results and reports per mode
- **Purpose:** Call `get_continuum_survival_fraction` for each mode.

6) ch_psd_sf(chinfo_ch::NamedTuple) — processors/process_psd_efficiencies.jl:≈L332–L460
- **Input:** `chinfo_ch` with `channel`, `detector`; uses PSD config and rpars for AoE/LQ
- **Returns:** `(result=Dict{Symbol,NamedTuple}, log=Dict{Symbol,NamedTuple}, processed=Dict{Symbol,Bool})`
- **Purpose:** Orchestrate per-detector evaluation over all configured classifiers; produce plots and assemble `rpars/psd` results.

---

## Outputs

**Parameters (run-level rpars):**
- **Path:** `$GENERATED_DATA_PATH/jlpar/rpars/psd/<period>/<run>.yaml`
- **Structure (per detector, per classifier):**
  - `<classifier>`:
    - `cuts`: resolved numeric cuts used for this classifier
      - `aoe_type`, `lowcut:{val,err}`, `highcut:{val,err}`, optional `lq_highcut:{val,err}`
    - `peaks`:
      - `low`/`ds`/`low_lq`/`lq_ds`:
        - `<PeakName>`: `{ val: <Float64>, err: <Float64>, unit: "%" }`
    - `qbb`:
      - `low`/`ds`/`low_lq`/`lq_ds`: `{ val: <Float64>, err: <Float64>, unit: "%" }`

**Plots:**
- **Path:** `$GENERATED_DATA_PATH/jlplt/cal/<period>/<run>/`
- **Files:**
  - `l200-p<period>-r<run>-<detector>-psd_peaks_<classifier>_<peak>.png` (before/after with fits)
  - `l200-p<period>-r<run>-<detector>-psd_qbb_<classifier>.png` (Qββ before/after)
  - `l200-p<period>-r<run>-<detector>-psd_masks_<classifier>.png` (AoE vs E and LQ vs E with cut overlays)

**Notes:**
- This processor does not optimize cuts; it evaluates efficiencies using the AoE/LQ cuts produced by prior processors.
- Ensure AoE/LQ rpars exist for the selected `aoe_type` and LQ configuration referenced by each classifier. 