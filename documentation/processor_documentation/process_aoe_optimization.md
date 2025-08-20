# process_aoe_optimization.jl

**Purpose:** Optimizes A/E (amplitude-over-energy) filter parameters for pulse shape discrimination between single-site events (SEP) and multi-site events (DEP). This is crucial for 0νββ decay searches: the 0νββ signal creates single-site energy depositions (like SEP) while most backgrounds create multi-site depositions (like DEP). A/E measures the ratio of current amplitude to energy - single-site events have sharper current pulses (higher A/E) than multi-site events. By optimizing A/E cuts, we maximize signal efficiency while rejecting background events.

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
- **Path:** `$JLPEAKS_PATH/cal/<period>/<run>/l200-<period>-<run>-cal-<detector>.lh5`
- **Data Keys:** 
  - `waveform_windowed`, `waveform_presummed` from `Tl208SEP` (single escape peak)
  - `waveform_windowed`, `waveform_presummed` from `Tl208DEP_Bi212FEP` (double escape peak)
  - `presum_rate`, `daqenergy`

**Config:**
- **Path:** `$METADATA_PATH/jldataprod/config/dsp/`
- **Parameters:** 
  - `qc`: Quality cut string for waveform selection
  - `aoe_filter`: A/E filter types to optimize (e.g., `sg` for Savitzky-Golay)
  - `dep_sep_quantile`: Quantile for DEP/SEP energy selection
  - **Per Filter Type:**
    - `dep`: DEP energy range for fitting
    - `dep_window`: DEP fitting window
    - `sep`: SEP energy range for fitting
    - `sep_window`: SEP fitting window
    - `sep_rel_cut`: Relative cut level for SEP
    - `min_aoe_quantile`, `max_aoe_quantile`: A/E quantile range
    - `min_aoe_offset`, `max_aoe_offset`: A/E offset range
    - `dep_cut_search_fit_func`: Function for DEP cut search
    - `sep_cut_search_fit_func`: Function for SEP cut search

**Parameters:**
- **Decay Times:** `$GENERATED_DATA_PATH/jlpar/rpars/pz/<period>/<run>.yaml` (from process_decay_time)
- **Filter Optimization:** `$GENERATED_DATA_PATH/jlpar/rpars/fltopt/<period>/<run>.yaml` (from process_filter_optimization)
- **ML Model:** `$JLML_PATH/cal/<period>/<run>/l200-<period>-<run>-cal-<timestamp>-tier_jlml.lh5` (optional for QC)
- **Existing Parameters:** `$GENERATED_DATA_PATH/jlpar/rpars/aoeopt/<period>/<run>.yaml` (for reprocess check)

---

## Functions

### 1. dsp_{filter_type}_optimization_compressed()
**Location:** `LegendDSP.jl/src/dsp_filter_optimization.jl:440` (sg)

**Parameters:**
```julia
dsp_{filter_type}_optimization_compressed(
    wvfs_windowed::ArrayOfRDWaveforms,
    wvfs_presummed::ArrayOfRDWaveforms,
    dsp_config::DSPConfig,
    τ::Quantity,
    flt_pars::NamedTuple;
    f_evaluate_qc::Function=nothing,
    presum_rate::Real
)
```

**Returns:**
- `dsp_results`: table-like per-event structure with at least
  - `energy`: reconstructed energies across the A/E parameter grid (typically a Vector-of-Vectors or Matrix indexed by window length)
  - `aoe`: A/E values across the same grid (same shape as `energy`)
  - supports boolean indexing via QC mask (e.g., `dsp_results[mask]`), and field access (`dsp_results.energy`, `dsp_results.aoe`)

**Purpose:**
- Compute A/E (amplitude-over-energy) for SEP and DEP event sets per detector. Current amplitude is derived from windowed waveforms; energy from presummed waveforms using the detector’s fixed RT/FT (from filter optimization) and decay time τ (PZ correction).
- Sweep only the A/E‑specific parameter(s) (e.g., Savitzky–Golay window length) to build, for each candidate value, per‑event pairs `(energy, aoe)` for SEP and DEP.
- Output is then filtered by a QC mask and forwarded to the A/E cut optimization.

### 2. fit_sf_wl()
**Location:** `LegendSpecFits.jl/src/aoe_filter_optimization.jl:42`

**Parameters:**
```julia
fit_sf_wl(
    dep_energy::Vector,
    dep_aoe::Vector,
    sep_energy::Vector,
    sep_aoe::Vector,
    wl_grid::Vector;
    dep::Real,
    dep_window::Tuple,
    sep::Real,
    sep_window::Tuple,
    sep_rel_cut::Real,
    min_aoe_quantile::Real,
    max_aoe_quantile::Real,
    min_aoe_offset::Real,
    max_aoe_offset::Real,
    dep_cut_search_fit_func::Symbol,
    sep_cut_search_fit_func::Symbol
)
```

**Returns:**
- `result_wl` (struct/NamedTuple):
  - `wl`: optimal A/E window length (samples or µs, per filter convention)
  - `sf`: survival fraction for SEP at the chosen DEP‑rejection operating point
  - `n_dep`, `n_sep`: event counts used after QC
  - may hold additional fit/cut diagnostics
- `report_wl`: report bundle containing, per window length, the DEP/SEP A/E vs energy distributions, the fitted cut(s), and the SEP survival fraction trend with the selected optimum highlighted.

**Purpose:**
- For each candidate window length in `wl_grid`, build A/E vs energy distributions for DEP and SEP.
- Within `dep_window` and `sep_window`, fit A/E distributions; solve for a DEP cut (using `dep_cut_search_fit_func`) meeting the target rejection, then apply that cut to SEP (with `sep_cut_search_fit_func`) and record SEP survival fraction.
- Pick the window length that maximizes SEP survival fraction (signal efficiency) at fixed background rejection. Returns the optimum and a report used for the `sg_sweep` plot.

---

## Internal Functions

**ch_sg_optimization(chinfo_ch::NamedTuple)**
- **Returns:** `(result=Dict{filter_type=>params}, log=Dict, processed=Dict)` - A/E optimization results per channel
- **Purpose:** Main processing logic **per detector** - loads SEP and DEP waveforms for this detector, applies QC cuts, uses this detector's optimized RT/FT parameters from process_filter_optimization, then optimizes only the A/E-specific filter parameters (like SG window length) for best pulse shape discrimination

---

## Outputs

**Data Tier:**
- **Path:** None (parameters only)

**Plots:**
- **Path:** `$GENERATED_DATA_PATH/jlplt/cal/<period>/<run>/`
- **Files:** `l200-p<period>-r<run>-<detector>-sg_sweep.png` (A/E window length optimization)

**Parameters:**
- **Path:** `$GENERATED_DATA_PATH/jlpar/rpars/aoeopt/<period>/<run>.yaml`
- **Structure:** `<detector>/<filter_type>/` per detector and filter type
- **Content:** 
  - `wl`: Optimal window length with uncertainty
  - `sf`: Survival fraction achieved
  - `n_dep`: Number of DEP events used
  - `n_sep`: Number of SEP events used
  - Saved in `rpars` (run-based parameters) for A/E pulse shape discrimination 