# process_sipm_calibration_phy.jl

**Purpose:** Performs SiPM energy calibration using physics data to convert raw ADC counts to calibrated photo-electron units. The processor (1) reads DSP-processed SiPM waveforms, (2) identifies and removes pulser-coincident events, (3) performs simple calibration to detect photo-electron peaks, (4) fits multiple photo-electron peaks to determine gain and resolution, (5) establishes calibration curve, and (6) writes run-level `rpars/sipmcal` parameters with QA plots.

---

## Path Variables

```
$RAW_DATA_PATH       = .../legend_data_production/raw_compressed
$METADATA_PATH       = .../legend_data_production/jl-v0.5.0/legend-metadata_new_yaml_p14
$GENERATED_DATA_PATH = .../legend_data_production/jl-v0.5.0/generated
$JLPLS_PATH          = .../legend_data_production/jlpls
$JLPLT_PATH          = .../legend_data_production/jlplt
$JLPAR_PATH          = .../legend_data_production/jlpar
```

---

## Inputs

**DSP Data (SiPM):**
- **Path:** `$GENERATED_DATA_PATH/tier/jldsp/phy/<period>/<run>/`
- **Data Keys:** DSP-processed SiPM data from SiPM filter optimization
  - **Energy Estimators:** Various SiPM filter outputs (e.g., `sg`, `cusp`, `trap`)
  - **Timestamp:** Event timing for pulser coincidence rejection
  - **QC flags:** Quality control information for event selection

**Pulser Tags:**
- **Path:** `$JLPLS_PATH/phy/<period>/<run>/`
- **Data Keys:** `tags` with pulser event timestamps for coincidence rejection
- **Purpose:** Remove calibration pulser events from physics data

**Calibration Config:**
- **Path:** `$METADATA_PATH/jldataprod/config/sipm/calibration/`
- **Parameters:**
  - **Energy Types:** `energy_types` - SiPM filter types to calibrate
  - **Simple Calibration:** `simple.kwargs` - initial calibration parameters
    - `initial_min_amp`, `initial_max_amp`: Amplitude range for initial peak search
  - **Peak Fitting:** `fit` - multi-photo-electron peak fitting parameters
    - `min_pe`, `max_pe`: Photo-electron range for peak fitting
    - `kwargs`: Detailed fitting parameters for photo-electron spectrum
  - **Calibration Curve:** `pol_order` - polynomial order for calibration function
  - **Quality Control:** `qc` - event selection criteria

**QC Config:**
- **Path:** `$METADATA_PATH/jldataprod/config/qc/`
- **Parameters:**
  - **Pulser:** `pulser.puls_channel` - pulser channel identification
  - **Timing Window:** `puls_ts_window` - coincidence time window for pulser rejection

---

## Functions

### 1) sipm_simple_calibration()
**Location:** `LegendSpecFits.jl` (SiPM calibration utilities)

**Parameters:**
```julia
simp_simple_calibration(
    e_uncal::Vector{<:Real};
    initial_min_amp::Real,
    initial_max_amp::Real,
    kwargs...
)
```

**Returns:**
- `result`: NamedTuple with `c` (calibration constant), `offset`, `f_simple_uncal` (calibration function), `pe_simple_cal` (calibrated data)
- `report`: NamedTuple with calibration plots and diagnostics

**Detailed workflow:**
- Histogram uncalibrated amplitudes in specified range
- Detect first photo-electron peak using robust peak finding
- Establish simple linear calibration: `PE_cal = c * ADC + offset`
- Return calibrated data and calibration function for further processing

**Purpose:** Initial calibration to convert ADC counts to approximate photo-electron units for multi-peak fitting.

### 2) fit_sipm_spectrum()
**Location:** `LegendSpecFits.jl` (SiPM spectral analysis)

**Parameters:**
```julia
fit_sipm_spectrum(
    pe_cal::Vector{<:Real},
    min_pe::Real,
    max_pe::Real;
    f_uncal::Function,
    uncertainty::Bool=true,
    kwargs...
)
```

**Returns:**
- `result`: NamedTuple with `positions` (peak positions), `resolutions_cal` (peak widths), `peaks` (photo-electron numbers)
- `report`: NamedTuple with spectrum fit plots and residuals

**Detailed workflow:**
- Build histogram of calibrated photo-electron spectrum
- Identify multiple photo-electron peaks (1 PE, 2 PE, 3 PE, etc.)
- Fit each peak with appropriate model (Gaussian + background)
- Extract peak positions, widths, and uncertainties
- Calculate photo-electron resolution as function of PE number

**Purpose:** Determine precise photo-electron peak characteristics for final calibration curve.

### 3) fit_calibration()
**Location:** `LegendSpecFits.jl` (calibration curve fitting)

**Parameters:**
```julia
fit_calibration(
    pol_order::Int,
    positions::Vector{<:Real},
    pe_values::Vector{<:Unitful.AbstractQuantity};
    e_expression::Symbol,
    uncertainty::Bool=true
)
```

**Returns:**
- `result`: NamedTuple with `par` (polynomial coefficients), `func` (calibration expression), `gof` (goodness-of-fit)
- `report`: NamedTuple with calibration curve plots

**Detailed workflow:**
- Fit polynomial of specified order to (position, PE_value) pairs
- Default: linear calibration `PE = a₀ + a₁ * ADC`
- Include uncertainties from peak fitting in calibration fit
- Generate human-readable calibration expression
- Assess goodness-of-fit with residuals and χ² statistics

**Purpose:** Establish final ADC → photo-electron calibration function with uncertainties.

### 4) flag_coincidences()
**Location:** `LegendSpecFits.jl` (timing utilities)

**Parameters:**
```julia
flag_coincidences(
    ts_signal::Vector{<:Real},
    ts_reference::Vector{<:Real};
    ts_window::Real
)
```

**Returns:** `Vector{Bool}` - Boolean mask for coincident events

**Detailed workflow:**
- Compare signal timestamps with reference (pulser) timestamps
- Mark events within `±ts_window` as coincident
- Return boolean mask for non-coincident (physics) events

**Purpose:** Remove pulser calibration events from physics data analysis.

---

## Internal Functions

1) **ch_sipm_calibration(chinfo_ch::NamedTuple)**
   - **Input:** Channel information tuple with detector and channel IDs
   - **Returns:** `(result, log, processed)` - calibration results, processing log, success flags
   - **Purpose:** Main per-detector calibration workflow orchestration

2) **get_plottitle(filekey, detector, plot_type; additional_type)**
   - **Input:** File key, detector ID, plot description, optional filter type
   - **Returns:** Formatted plot title string
   - **Purpose:** Standardized plot title generation for QA plots

3) **savelfig(save_func, plot, l200, filekey, detector, plot_name)**
   - **Input:** Save function, plot object, data structure, identifiers
   - **Returns:** Saved plot file path
   - **Purpose:** Standardized plot saving with consistent naming convention

---

## Outputs

**Parameters (rpars):**
- **Path:** `$JLPAR_PATH/rpars/sipmcal/<period>/<run>.yaml`
- **Structure (per detector and energy type):**
  - `m_cal_simple`: Simple calibration constant (first-pass gain)
  - `n_cal_simple`: Simple calibration offset
  - `cal`: Final calibration parameters
    - `par`: Polynomial coefficients with units and uncertainties
    - `func`: Human-readable calibration expression
    - `gof`: Goodness-of-fit diagnostics (χ², p-value, residuals)
  - `fit`: Photo-electron peak fitting results
    - `positions`: Peak positions in ADC units
    - `resolutions_cal`: Peak resolutions in calibrated units
    - `peaks`: Photo-electron numbers corresponding to peaks

**Plots:**
- **Path:** `$JLPLT_PATH/phy/<period>/<run>/`
- **Files:**
  - `l200-p<period>-r<run>-<detector>-pe_uncalibrated_<energy_type>.png`: Raw amplitude spectrum
  - `l200-p<period>-r<run>-<detector>-sipm_simple_calibration_<energy_type>.png`: Simple calibration results
  - `l200-p<period>-r<run>-<detector>-simp_peak_fits_<energy_type>.png`: Multi-PE peak fits
  - `l200-p<period>-r<run>-<detector>-sipm_calibration_curve_<energy_type>.png`: Final calibration curve

**Notes:**
- Requires valid SiPM channel configuration in hardware database (`system=:spms`)
- Pulser channel must be properly configured in QC config
- Quality cuts applied to remove non-physical events before calibration
- Processing supports multiple energy estimator types simultaneously
- Failed calibrations are logged but don't prevent processing of other energy types
