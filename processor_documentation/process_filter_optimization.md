# process_filter_optimization.jl

**Purpose:** Optimize per-detector digital filter parameters (rise time RT and flat-top FT) for `trap`, `cusp`, and `zac` filters to minimize noise (ENC) and achieve best energy resolution (FWHM). Workflow: load jlpeaks waveforms, optionally apply ML-based QC, compute qdrift, sweep RT with FT fixed to find minimal ENC, then sweep FT with RT fixed to the RT optimum to minimize FWHM at FEP. Save diagnostic plots and run parameters.

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
- **Data Keys:** under the configured peak (e.g., `Tl208FEP`): `waveform_presummed`, `waveform_windowed`, `presum_rate`

**Config:**
- **Path:** `$METADATA_PATH/jldataprod/config/dsp/`
- **Parameters:** 
  - `qc`: Quality cut string for waveform selection
  - `peakname`: Peak name to use (e.g., `Tl208FEP`)
  - `e_filter`: Filter types to optimize (e.g., `trap`, `cusp`, `zac`)
  - `max_wvfs`: Maximum number of waveforms to process
  - `apply_ctc`: Whether to apply charge trapping correction
  - `peak`: Peak energy for calibration
  - `left_window_size`, `right_window_size`: Peak fitting windows
  - `ft_fwhm_tol`: FWHM tolerance for flat-top optimization
  - **Per Filter Type:**
    - `ft_fixed`: Fixed flat-top time for RT optimization
    - `min_enc`, `max_enc`: ENC fitting range
    - `nbins_enc_sigmas`: Bins for ENC histogram
    - `rel_cut_fit_enc_sigmas`: Relative cut for ENC fitting
    - `min_e_fep`, `max_e_fep`: FEP energy range
    - `nbins_e_fep`: Bins for energy histogram  
    - `rel_cut_fit_e_fep`: Relative cut for energy fitting

**Parameters:**
- **Decay Times:** `$GENERATED_DATA_PATH/jlpar/rpars/pz/<period>/<run>.yaml` (from process_decay_time)
- **ML Model:** `$JLML_PATH/cal/<period>/<run>/l200-<period>-<run>-cal-<timestamp>-tier_jlml.lh5` (optional for QC)
- **Existing Parameters:** `$GENERATED_DATA_PATH/jlpar/rpars/fltopt/<period>/<run>.yaml` (for reprocess check)

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
- `dsp_qc`: per-event QC/DSP features used to evaluate the `qc` mask. Typical fields include:
  - `blmean::Vector{Float64}`: baseline mean (ADC units) per event measured in a baseline window on presummed waveforms
  - additional pulse-shape features (rise/fall indicators, integrals, etc.) consumed by the ML model; exact set is implementation-dependent

**Purpose:**
- Extract QC features from presummed waveforms using `dsp_config` windows and settings.
- Apply the ML scoring function `f_evaluate_qc` to obtain a boolean mask via `ljl_propfunc(qc_string).(dsp_qc)`.
- Use this mask to filter events for all subsequent steps; if ML is unavailable, keep all events and proceed (downstream sets `blmean_wdw = zeros(...)`).

### 2. dsp_qdrift_flt_optimization()
**Location:** `LegendDSP.jl/src/dsp_filter_optimization.jl:63`

**Parameters:**
```julia
dsp_qdrift_flt_optimization(
    wvfs::ArrayOfRDWaveforms,
    blmean::Vector,
    dsp_config::DSPConfig,
    τ::Unitful.Time
)
```

**Returns:**
- `qdrift::Vector{Float64}`: one correction factor per surviving event (unitless), aligned with the filtered waveform arrays

**Purpose:**
- Estimate per-event charge-drift effects using windowed waveforms and baseline statistics. Normalize `dsp_qc.blmean` by `presum_rate` to compensate presumming, then combine with DSP settings and `τ` to derive `qdrift`.
- `qdrift` is applied later in the FT–FWHM step (optionally together with CTC) to correct reconstructed energies for slow drifts.

### 3. dsp_{filter_type}_rt_optimization()
**Location:** `LegendDSP.jl/src/dsp_filter_optimization.jl:93` (trap), `136` (cusp), `184` (zac)

**Parameters:**
```julia
dsp_{filter_type}_rt_optimization(
    wvfs::ArrayOfRDWaveforms,
    config::DSPConfig,
    τ::Quantity;
    ft::Quantity
)
```

**Returns:**
- `enc_grid::Matrix{Float64}`: ENC samples per RT setting; `size(enc_grid, 1) == length(e_grid_rt)`. Each row aggregates the ENC proxy over events for a specific RT and is later histogrammed in the fit.

**Purpose:**
- For each candidate RT in `e_grid_rt`, apply the chosen filter to presummed waveforms with FT fixed to `ft_fixed` from config and compute an ENC proxy per event.
- Aggregate per-RT ENC samples into `enc_grid` to map noise vs RT.
- Typical grids per analysis note: RT ∈ [1, 16] µs in 0.5 µs steps; FT fixed ≈ 2 µs during the RT sweep.

### 4. fit_enc_sigmas()
**Location:** `LegendSpecFits.jl/src/filter_optimization.jl:17`

**Parameters:**
```julia
fit_enc_sigmas(
    enc_grid::Matrix,
    e_grid_rt::Vector,
    min_enc::Real,
    max_enc::Real,
    nbins::Int,
    rel_cut::Real
)
```

**Returns:**
- `result_rt` (struct/NamedTuple):
  - `rt::Quantity` (µs): RT at the minimum of the fitted ENC–RT curve
  - `min_enc::Float64`: ENC value at that minimum
  - optionally uncertainties and fit-quality indicators
- `report_rt`: report bundle with RT grid, per-RT ENC histograms (binned to `nbins` within [`min_enc`,`max_enc`]), Gaussian fits per RT, global curve, and the selected optimum marker.

**Purpose:**
- For each row of `enc_grid` (one RT), build an ENC histogram, fit a Gaussian to estimate ENC, then analyze the ENC trend over RT and pick the minimum under the configured bounds `min_enc/max_enc` and `rel_cut`.

### 5. dsp_{filter_type}_ft_optimization()
**Location:** `LegendDSP.jl/src/dsp_filter_optimization.jl:232` (trap), `277` (cusp), `327` (zac)

**Parameters:**
```julia
dsp_{filter_type}_ft_optimization(
    wvfs::ArrayOfRDWaveforms,
    config::DSPConfig,
    τ::Quantity,
    rt_optimal::Real
)
```

**Returns:**
- `e_grid::Matrix{Float64}`: reconstructed per‑event energies for each FT on the grid; `size(e_grid, 1) == length(e_grid_ft)`; each row corresponds to one FT value.

**Purpose:**
- For each FT candidate and with `rt_optimal` fixed:
  - Apply the selected digital filter (`trap`/`cusp`/`zac`) to each presummed waveform using `config`.
  - Perform baseline removal using `dsp_config` baseline window; apply pole‑zero correction with the detector decay time `τ`.
  - Compute a scalar energy per waveform as the filter pick‑off value:
    - trap: difference of moving averages (separated by the gap), measured on the flat‑top; energy is the average (or center sample) over the flat‑top window after baseline subtraction and PZ correction.
    - cusp/zac: convolution with the corresponding kernel (finite cusp or zero‑area cusp); energy is the amplitude at the kernel’s pick‑off sample (near the filter center) after baseline/PZ correction.
  - Collect these event‑wise energies into the matrix row for that FT.
- The resulting `e_grid` provides, for each FT, the distribution of reconstructed energies used by the subsequent FWHM‑vs‑FT fit around the FEP.

### 6. fit_fwhm_ft()
**Location:** `LegendSpecFits.jl/src/filter_optimization.jl:95`

**Parameters:**
```julia
fit_fwhm_ft(
    e_grid::Matrix,
    e_grid_ft::Vector,
    qdrift::Vector,
    rt::Quantity,
    min_e::Real,
    max_e::Real,
    rel_cut::Real,
    apply_ctc::Bool;
    n_bins::Int,
    peak::Real,
    window::Tuple,
    ft_fwhm_tol::Real
)
```

**Returns:**
- `result_ft`: struct with `ft::Quantity` (optimal FT) and `min_fwhm::Unitful.Energy`
- `report_ft`: plot report (FEP window histograms, FWHM vs FT curve, chosen FT)

**Purpose:** Fit FWHM vs FT (optionally with CTC) to pick the FT minimizing the FEP resolution. L-Note guidance: prefer the smallest FT where FWHM reaches a plateau (e.g., changes < 0.1 keV over the next three FT steps), otherwise choose the absolute minimum.

---

## Internal Functions (chronological, with source lines)

1) ch_filter_optimization(chinfo_ch::NamedTuple) — processors/process_filter_optimization.jl:L52-L239
- **Input:** `channel`, `detector`; effective `dsp_config_ch`, `optimization_config_ch`; `filekey`; decay time `pars_tau[det].τ`
- **Purpose:**
  - Load jlpeaks datasets for `peakname`: `waveform_presummed`, `waveform_windowed`, `presum_rate`
  - QC (optional ML): compute `dsp_qc`, evaluate `qc` mask, filter events; derive `blmean_wdw = dsp_qc.blmean ./ presum_rate`
  - Compute `qdrift`
  - For each filter type in `e_filter`:
    - RT sweep (FT fixed): build `enc_grid` → `result_rt, report_rt = fit_enc_sigmas(...)` → save noise-sweep plot
    - FT sweep (RT fixed to result_rt): build `e_grid` → `result_ft, report_ft = fit_fwhm_ft(...)` → save FWHM-scan plot
  - Merge results and return
- **Returns:** `(result=Dict{Symbol,NamedTuple}, log=Dict, processed=Dict)` where `result[filter_type]` contains at least `rt`, `min_enc`, `ft`, `min_fwhm`

---

## Outputs

**Data Tier:**
- **Path:** None (parameters only)

**Plots:**
- **Path:** `$GENERATED_DATA_PATH/jlplt/cal/<period>/<run>/`
- **Files:** 
  - `l200-p<period>-r<run>-<detector>-noise_sweep_{filter_type}.png` (ENC vs rise time)
  - `l200-p<period>-r<run>-<detector>-fwhm_ft_scan_{filter_type}.png` (FWHM vs flat‑top time)

**Parameters:**
- **Path:** `$GENERATED_DATA_PATH/jlpar/rpars/fltopt/<period>/<run>.yaml`
- **Structure:** `<detector>/<filter_type>/` per detector and filter type
- **Content:** 
  - `rt`: Optimal rise time with uncertainty
  - `ft`: Optimal flat-top time with uncertainty  
  - `min_enc`: Minimum ENC achieved
  - `min_fwhm`: Minimum FWHM achieved
  - Saved in `rpars` (run-based parameters) for DSP filter configuration 