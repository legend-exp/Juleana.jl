# process_energy_calibration.jl

**Purpose:** Performs comprehensive energy calibration using Th-228 photopeaks to convert raw ADC counts to calibrated energy (keV) and establishes energy-dependent resolution functions - the final step to create physics-ready energy estimators for analysis

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
  - **Raw Energy Estimators:**
    - `e_trap`: Trapezoidal filter energy (main production estimator)
    - `e_cusp`: CUSP filter energy (complementary estimator for noise optimization)
  - **Supporting Parameters:**
    - `qdrift`: Charge drift parameter (needed for CTC-corrected estimators)

**CTC Parameters:**
- **Path:** `$GENERATED_DATA_PATH/jlpar/rpars/ctc/<period>/<run>.yaml`
- **Content:** Charge trapping correction coefficients from `process_ct_correction.jl`
  - `func`: Mathematical expressions for CTC corrections (e.g., `"e_trap + α₁*qdrift + α₂*qdrift²"`)
  - Used to create `_ctc` versions of energy estimators

**Energy Config:**
- **Path:** `$METADATA_PATH/jldataprod/config/energy/`
- **Parameters:**
  - **Calibration Lines:**
    - `th228_lines`: Known Th-228 photopeak energies ([583.187, 727.33, 860.557, 1592.513, 1620.5, 2103.512, 2614.511] keV)
    - `th228_names`: Peak identifiers (Tl208a, Bi212a, Tl208b, Tl208DEP, Bi212FEP, Tl208SEP, Tl208FEP)
    - `th228_fit_func`: Fitting functions per peak (gamma_def, gamma_tails_bckFlat)
    - `left_window_sizes`, `right_window_sizes`: Peak fitting windows per line
  - **Quality Control:**
    - `qc.fit`: Peak fitting quality cuts (convergence, residuals, significance)
    - `qc.min_fwhm`, `qc.max_fwhm_per_window`: FWHM validity ranges
  - **Calibration Fitting:**
    - `cal_pol_order`: Polynomial order for energy calibration (1 = linear)
    - `cal_fit_excluded_peaks`: Peaks excluded from calibration curve
    - `cal_fit_max_tolerance`: Maximum tolerance for calibration fit
  - **FWHM Fitting:**
    - `fwhm_pol_order`: Polynomial order for resolution curve (1 = √E dependence)
    - `fwhm_fit_excluded_peaks`: Peaks excluded from FWHM curve
    - `fwhm_fit_min_fwhm`: Minimum FWHM for valid fits
  - **Energy Types:** List of estimators to calibrate (`["e_trap", "e_cusp", "e_trap_ctc", "e_cusp_ctc"]`)

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
- `result`: NamedTuple with calibration constant `c`, peak histograms `peakhists`, and peak statistics `peakstats`
- `report`: NamedTuple with detailed calibration results for plotting

**Purpose:** Initial peak detection and rough calibration. Step 1: detect candidate lines and compute a first ADC→keV scale using robust statistics. Build peak‑window histograms (`peakhists`) and stats (`peakstats`) for subsequent detailed modeling.

### 2. fit_peaks()
**Location:** `LegendSpecFits.jl/src/specfit.jl:9-40`

**Parameters:**
```julia
fit_peaks(
    peakhists::Array,
    peakstats::StructArray,
    th228_lines::Vector;
    calib_type::Symbol=:th228,
    fit_func::Vector{Symbol},
    m_cal_simple::Real,
    uncertainty::Bool=true
)
```

**Returns:**
- `result`: Dictionary of fitted peak parameters per peak name (μ, σ, centroid, fwhm, etc.)
- `report`: Dictionary of detailed fitting results and plots per peak

**Purpose:** Detailed peak fitting. Step 2: fit per‑line models (e.g., gamma_def, gamma_tails_bckFlat) to each histogram. Return precise µ, σ, centroid, FWHM with uncertainties and GoF diagnostics; produce per‑peak plots for QA.

### 3. fit_calibration()
**Location:** `LegendSpecFits.jl/src/fit_calibration.jl:11-40`

**Parameters:**
```julia
fit_calibration(
    pol_order::Int,
    µ::AbstractVector{<:Measurement},
    peaks::AbstractVector{<:Quantity};
    e_expression::String,
    uncertainty::Bool=true
)
```

**Returns:**
- `result`: NamedTuple with calibration polynomial coefficients `par` and function expression `func`
- `report`: NamedTuple with fit quality parameters and plotting data

**Purpose:** Calibration curve fitting. Step 3: fit polynomial ADC→keV using peak centroids and known energies; exclude flagged peaks per config. Return coefficients and a callable expression; include residual and GoF info.

### 4. fit_fwhm()
**Location:** `LegendSpecFits.jl/src/fit_fwhm.jl:9-69`

**Parameters:**
```julia
fit_fwhm(
    pol_order::Int,
    peaks::Vector{<:Unitful.Energy{<:Real}},
    fwhm::Vector{<:Unitful.Energy{<:Real}};
    e_type_cal::Symbol,
    e_expression::String,
    uncertainty::Bool=true
)
```

**Returns:**
- `result`: NamedTuple with:
  - `par`: FWHM polynomial coefficients
  - `qbb`: Energy resolution at Qᵦᵦ = 2039.061 keV (⁰νββ Q-value of ⁷⁶Ge)
  - `func`: Mathematical expression for resolution vs energy
- `report`: NamedTuple with fit details and quality metrics

**Purpose:** Resolution curve fitting. Step 4: fit σ(E)/FWHM(E) vs E using configured form and exclusions. Return coefficients, evaluated resolution at Qββ=2039.061 keV, and plotting report.

---

## Internal Functions

**ch_energy_calibration(chinfo_ch::NamedTuple)**
- **Returns:** `(result=Dict{Symbol,NamedTuple}, log=Dict{Symbol,NamedTuple}, processed=Dict{Symbol,Bool})` - processing results per energy type
- **Purpose:** Per‑detector workflow coordinating: (1) simple calibration on each estimator; (2) per‑peak fits and QA plots; (3) ADC→keV calibration fit; (4) resolution fit; (5) apply CTC expressions from `rpars/ctc` to build `_ctc` energies and repeat steps as configured. Saves all diagnostic plots and aggregates results for parameter writing.

---

## Outputs

**Plots (per energy type):**
- **Path:** `$GENERATED_DATA_PATH/jlplt/cal/<period>/<run>/`
- **Files:**
  - `l200-<period>-r<run>-<detector>-simple_calibration_<energy_type>.png` (initial calibration with all peaks)
  - `l200-<period>-r<run>-<detector>-peak_fits_<energy_type>.png` (detailed fits for each peak)
  - `l200-<period>-r<run>-<detector>-calibration_curve_<energy_type>.png` (ADC vs keV calibration function)
  - `l200-<period>-r<run>-<detector>-fwhm_<energy_type>.png` (energy resolution vs energy curve)
- **Content:** Complete calibration validation plots showing fit quality and energy-dependent behavior

**Parameters:**
- **Path:** `$GENERATED_DATA_PATH/jlpar/rpars/ecal/<period>/<run>.yaml`
- **Content:** Complete calibration results per detector per energy type:
  ```yaml
  <detector>:
    e_trap:
      cal:
        par: [a₀, a₁]  # Calibration coefficients: E_keV = a₀ + a₁×ADC
        func: "a₀ + a₁ * e_trap"
      fwhm:
        par: [b₀, b₁]  # Resolution coefficients: σ(E) = √(b₀ + b₁×E)
        qbb: X.X keV  # Resolution at 2039.061 keV (⁰νββ Q-value)
        func: "sqrt(b₀ + b₁ * e_trap_cal)"
      fit:
        Tl208FEP:     # Individual peak results
          centroid: X.X ± Y.Y ADC
          fwhm: Z.Z ± W.W keV
        # ... other peaks
    e_trap_ctc:  # CTC-corrected version
      # ... same structure with improved resolution
    e_cusp:
      # ... same structure, different filter
    e_cusp_ctc:
      # ... CTC-corrected CUSP version
  ```

**Usage:** These calibration parameters enable conversion of all raw energy measurements to calibrated energies in subsequent processors, creating the final physics-ready energy estimators used for spectroscopy and ⁰νββ searches 