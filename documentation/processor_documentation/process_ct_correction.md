# process_ct_correction.jl

**Purpose:** Applies Charge Trapping Correction (CTC) to multiple energy estimators to compensate for charge losses during drift in germanium detectors - essential for achieving optimal energy resolution and linearity across the detector volume

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

**Hit Data:**
- **Path:** `$GENERATED_DATA_PATH/tier/jlhit/cal/<period>/<run>/`
- **Data Keys:** Physics events after QC cuts from `process_hit_cal.jl`
  - **Energy Estimators to be corrected:**
    - `e_trap`: Trapezoidal filter energy (main production estimator, individually optimized RT/FT per detector)
    - `e_cusp`: CUSP filter energy (complementary estimator, different noise characteristics, better for low-energy events)
  - **Supporting Parameters:**
    - `qdrift`: Charge drift parameter from DSP (proportional to drift time and interaction depth in detector)

**Energy Config:**
- **Path:** `$METADATA_PATH/jldataprod/config/energy/`
- **Parameters:**
  - **Calibration Lines:**
    - `th228_lines`: Known Th-228 photopeak energies ([583.187, 727.33, 860.557, 1592.513, 1620.5, 2103.512, 2614.511] keV)
    - `th228_names`: Peak identifiers (Tl208a, Bi212a, Tl208b, Tl208DEP, Bi212FEP, Tl208SEP, Tl208FEP)
    - `left_window_sizes`, `right_window_sizes`: Peak fitting windows per line
  - **Calibration Parameters:**
    - `quantile_perc`: Data quantile for robust fitting
    - `binning_peak_window`: Binning window around peaks (4 keV)
    - `cal_pol_order`: Polynomial order for calibration (1 = linear)
    - `cal_fit_excluded_peaks`: Peaks excluded from calibration fit
  - **Energy Types:** List of energy estimators to correct (`["e_trap", "e_cusp"]`)
    - `e_trap`: Trapezoidal filter energy (main energy estimator, optimized RT/FT)
    - `e_cusp`: CUSP filter energy (alternative estimator, better for low energy/noise)
    - `e_zac`: Zero-Area-Cusp filter energy (pile-up rejection capabilities)
    - `e_535`: Robust trapezoidal filter (5µs RT, 3µs FT, fixed parameters)
    - `e_trap_max`, `e_cusp_max`: Maximum filter outputs (timing-independent)

**CTC Config:**
- **Path:** `$METADATA_PATH/jldataprod/config/energy/`
- **Parameters:**
  - `peak`: Reference peak for CTC optimization (2614.51 keV = Tl208FEP)
  - `left_window_size`, `right_window_size`: Energy window around reference peak (35, 30 keV)
  - `ctc_order`: Polynomial order for CTC correction (2 = quadratic in qdrift)
  - `energy_types`: Energy estimators to apply CTC to

---

## Functions

### 1. simple_calibration()
**Location:** `LegendSpecFits.jl/src/simple_calibration.jl:17-50`

**Parameters:**
```julia
simple_calibration(
    e_uncal::Vector{<:Real},
    gamma_lines::Vector{<:Unitful.Energy{<:Real}},
    left_window_sizes::Vector{<:Unitful.Energy{<:Real}},
    right_window_sizes::Vector{<:Unitful.Energy{<:Real}};
    calib_type::Symbol=:th228,
    quantile_perc::Real,
    binning_peak_window::Unitful.Energy{<:Real}
)
```

**Returns:**
- `result`: NamedTuple with calibration constant `c` (keV/ADC conversion factor)
- `report`: NamedTuple with fitting details for quality assessment and plotting

**Purpose:** Energy calibration using Th-228 lines to transform raw ADC to keV for a given estimator. Step 1 in CTC: establishes the per-detector keV scale before charge-trapping optimization. Fits multiple peaks with configurable windows, uses a robust quantile to suppress outliers, and returns the ADC→keV scale `c` and a plotting report.

### 2. ctc_energy()
**Location:** `LegendSpecFits.jl/src/ctc.jl:17-120`

**Parameters:**
```julia
ctc_energy(
    e::Vector{<:Unitful.Energy{<:Real}},
    qdrift::Vector{<:Real},
    peak::Unitful.Energy{<:Real},
    window::Tuple{<:Unitful.Energy{<:Real}, <:Unitful.Energy{<:Real}},
    m_cal_simple::Unitful.Energy{<:Real};
    e_expression::Union{Symbol, String}="e",
    pol_order::Int=1
)
```

**Returns:**
- `result`: NamedTuple with:
  - `fct`: CTC polynomial coefficients (correction factors)
  - `fwhm_before`, `fwhm_after`: Energy resolution before/after correction
  - `func`: Mathematical expression for CTC correction
  - `converged`: Optimization convergence status
- `report`: NamedTuple with detailed fitting results, histograms, and plots

**Purpose:** Charge‑trapping correction optimization. Step 2 in CTC: for each energy estimator, scan/fit a low‑order polynomial in `qdrift` that, when applied to the calibrated energy, minimizes the FWHM at the reference line (default Tl208 FEP). Returns coefficients, pre/post FWHM, convergence, and a report for plotting.

Detailed workflow per detector and energy estimator
- Input selection: take physics events from `jlhit/<channel>/dataQC` and the chosen energy series (`e_trap`, `e_cusp`, ...) along with `qdrift`.
- Simple calibration: fit Th‑228 peaks to obtain keV scale `m_cal_simple`; save a diagnostic spectrum plot with fit overlays for the estimator.
- CTC fit: apply keV scale to the energy series; within the configured window around the reference peak, evaluate candidate polynomial corrections in `qdrift` (up to `ctc_order`) and select the one minimizing FWHM; record `fwhm_before`/`fwhm_after` and polynomial coefficients.
- Reporting: produce a “before vs after” plot at the reference peak showing line narrowing, with legend and fitted parameters. Save one plot per estimator.

---

## Internal Functions

**ch_ct_correction(chinfo_ch::NamedTuple)**
- **Returns:** `(result=Dict{Symbol,NamedTuple}, log=Dict{Symbol,NamedTuple}, processed=Dict{Symbol,Bool})` - processing results per energy type
- **Purpose:** Main processing function per detector - coordinates simple calibration and CTC optimization for all configured energy estimators (e_trap, e_cusp, etc.), saves diagnostic plots, and tracks processing status

---

## Outputs

**Plots:**
- **Path:** `$GENERATED_DATA_PATH/jlplt/cal/<period>/<run>/`
- **Files per energy type:** 
  - `l200-<period>-r<run>-<detector>-simple_calibration_e_trap.png` (Th-228 calibration spectrum for trapezoidal filter)
  - `l200-<period>-r<run>-<detector>-simple_calibration_e_cusp.png` (Th-228 calibration spectrum for CUSP filter)
  - `l200-<period>-r<run>-<detector>-ctc_e_trap.png` (Tl208FEP before/after CTC for trapezoidal filter)
  - `l200-<period>-r<run>-<detector>-ctc_e_cusp.png` (Tl208FEP before/after CTC for CUSP filter)
- **Content:** Shows energy resolution improvement (FWHM reduction) and linearity correction achieved by CTC

**Parameters:**
- **Path:** `$GENERATED_DATA_PATH/jlpar/rpars/ctc/<period>/<run>.yaml`
- **Content:** CTC results per detector per energy type. Fields per estimator:
  - `fct::Vector{Float64}`: correction coefficients (order matches `ctc_order`)
  - `fwhm_before::Quantity(keV)`, `fwhm_after::Quantity(keV)`
  - `converged::Bool`
  - `func::String`: human-readable formula, e.g. `e_trap + a1*qdrift + a2*qdrift^2`
- **Usage:** Downstream creation of corrected energies (e.g., `e_trap_ctc`, `e_cusp_ctc`).

**Note:** This processor does not create a new data tier but generates the correction parameters that will be applied during energy calibration in subsequent processors to create CTC-corrected energy estimators (e.g., `e_trap_ctc`, `e_cusp_ctc`) 