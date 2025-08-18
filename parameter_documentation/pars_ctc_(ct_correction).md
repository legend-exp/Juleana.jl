# ctc (charge trapping correction) run parameters — schema and field descriptions

Purpose: Document the structure and semantics of the charge-trapping correction (ctc) run parameters saved under rpars. These parameters are produced by the `process_ct_correction` processor and used downstream to build corrected energy estimators (e.g., `e_trap_ctc`).

---

## Location

- Path per run: `.../legend_data_production/jl-v0.5.0/generated/jlpar/rpars/ctc/p<period>/r<run>.yaml`
- Scope: One YAML file per run, with one top-level entry per detector (detector ID as key).

---

## Field descriptions

### Level 1: Detectors (top-level keys)
- **String**: Detector IDs (e.g., `V02166B`, `V07647B`, `V01240A`)
- **Meaning**: Groups charge-trapping correction results for that detector

### Level 2: Energy estimator types (detector sub-keys)
- **Energy Types**: `e_trap`, `e_cusp`, `e_zac` (and variants like `e_535`)
- **Meaning**: Different energy estimation methods requiring CTC

#### Energy Estimator Types (from L-Note Section V):
- **`e_trap`**: **Trapezoidal filter** - symmetric filter with configurable timing
- **`e_cusp`**: **CUSP filter** - cusp-like filter with flat-top center
- **`e_zac`**: **ZAC filter** - Zero-Area CUSP with parabola subtraction

#### Physical Meaning and CTC Process (from L-Note Section VI.A):
- **Charge Trapping**: Electrons/holes get trapped at crystal impurities during drift
- **Effect**: **Position-dependent energy response** - deeper interactions appear lower in energy
- **Qdrift Parameter**: **Drift distance proxy** - typically proportional to rise time or A/E ratio
- **CTC Goal**: Remove correlation between measured energy and drift distance
- **Method**: **Polynomial correction** in qdrift to minimize FWHM at reference peak
- **Reference Peak**: Usually **Tl208 FEP at 2614.51 keV** (highest statistics, good resolution)

### Level 3: CTC optimization results (energy type sub-keys)

#### 3.1: `fct` (Correction Coefficients)
- **Purpose**: Polynomial coefficients for qdrift-based correction
- **Type**: Vector{Float64} - typically [a1, a2] for quadratic correction

#### 3.2: `peak` (Reference Peak)
- **Purpose**: Energy of reference line used for optimization
- **Type**: Object with unit and value (typically 2614.51 keV)

#### 3.3: `window` (Fit Window)
- **Purpose**: Left/right window sizes around reference peak
- **Type**: Array of objects with val fields

#### 3.4: `fwhm_before` / `fwhm_after` (Resolution Improvement)
- **Purpose**: Energy resolution before/after CTC application
- **Type**: Objects with unit, value, and uncertainty

#### 3.5: `converged` (Optimization Status)
- **Purpose**: Whether optimization reached valid solution
- **Type**: Boolean flag

#### 3.6: `func` (Human-readable Formula)
- **Purpose**: Readable correction expression
- **Type**: String representation

#### 3.7: `m_cal_simple` (Calibration Scale)
- **Purpose**: ADC→keV scale from simple calibration
- **Type**: Object with unit and value

### Level 4: Detailed field content

#### 4.1: Correction coefficients structure (`fct`)
- **Type**: Vector{Float64} - polynomial coefficients
- **Default Order**: Quadratic (2nd order) → [a1, a2]
- **Correction Formula**: `E_ctc = E_raw + a1*qdrift + a2*qdrift^2`
- **Application**: Applied to **calibrated energies** (keV scale)

#### 4.2: Peak and window structure
- **`peak`**: `{unit: "keV", val: 2614.51}` - Tl208 FEP reference
- **`window`**: `[{val: 35}, {val: 30}]` - [left_window, right_window] in keV
- **Purpose**: Define fit region around reference peak

#### 4.3: Resolution improvement structure
- **`fwhm_before`**: `{unit: "keV", val: <Float>, err: <Float>}` - Before CTC
- **`fwhm_after`**: `{unit: "keV", val: <Float>, err: <Float>}` - After CTC
- **Typical Improvement**: 10-30% FWHM reduction
- **Quality Metric**: Larger improvement indicates stronger charge trapping

#### 4.4: Optimization metadata
- **`converged`**: Boolean - successful optimization flag
- **`func`**: String - human-readable correction formula
- **`m_cal_simple`**: `{unit: "keV", val: <Float>}` - calibration scale factor

---

## Provenance and generation

- Producer: `process_ct_correction` processor.
- Inputs: `jlhit` physics events (`dataQC`) including chosen energy estimators and `qdrift`; energy YAML config with calibration lines and CTC settings.
- Fit: `simple_calibration` to obtain ADC→keV scaling for the estimator; `ctc_energy` to optimize polynomial in `qdrift` minimizing FWHM near the reference line.

---

## Usage guidance

- Apply coefficients to calibrated energies only (after `simple_calibration`).
- Validate with the provided before/after plots and compare `fwhm_before` vs `fwhm_after`.
- If improvement is marginal or convergence fails, consider:
  - Increasing statistics (more runs or wider selection windows)
  - Adjusting `left/right_window_size` around the reference line
  - Lowering polynomial order if overfitting is suspected

---

## Example Structure

```yaml
V02166B:
  # CUSP filter charge trapping correction
  e_cusp:
    fct: [5.58495950340756e-5, 2.787427442547898e-12]         # [a1, a2] coefficients
    peak: { unit: "keV", val: 2614.51 }                       # Tl208 FEP reference
    window: [{ val: 35 }, { val: 30 }]                        # [left, right] window in keV
    fwhm_before: { unit: "keV", val: 3.4237882494198857, err: 0.015014857973574765 }
    fwhm_after: { unit: "keV", val: 3.3068811083730907, err: 0.014071603737216616 }
    converged: true
    func: "e_cusp + 5.58495950340756e-5 * qdrift^1 + 2.787427442547898e-12 * qdrift^2"
    m_cal_simple: { unit: "keV", val: 0.02329961231102969 }

  # Trapezoidal filter charge trapping correction
  e_trap:
    fct: [6.053088585932206e-5, 1.5565157989709747e-13]       # Different coefficients
    peak: { unit: "keV", val: 2614.51 }                       # Same reference peak
    window: [{ val: 35 }, { val: 30 }]                        # Same fit window
    fwhm_before: { unit: "keV", val: 3.4223034267711228, err: 0.014900330145635536 }
    fwhm_after: { unit: "keV", val: 3.307861907785991, err: 0.014139396294864225 }
    converged: true
    func: "e_trap + 6.053088585932206e-5 * qdrift^1 + 1.5565157989709747e-13 * qdrift^2"
    m_cal_simple: { unit: "keV", val: 0.02328569574535158 }

V07647B:
  # Different detector with stronger charge trapping
  e_cusp:
    fct: [9.812928537851134e-5, 2.167381658361727e-12]        # Larger a1 coefficient
    peak: { unit: "keV", val: 2614.51 }
    window: [{ val: 35 }, { val: 30 }]
    fwhm_before: { unit: "keV", val: 2.9010192037872002, err: 0.01793700804342198 }
    fwhm_after: { unit: "keV", val: 2.7216631448613953, err: 0.01655438044153378 }
    converged: true
    func: "e_cusp + 9.812928537851134e-5 * qdrift^1 + 2.167381658361727e-12 * qdrift^2"
    m_cal_simple: { unit: "keV", val: 0.01883975376792243 }

  e_trap:
    fct: [9.979133296085468e-5, 1.506815108363156e-13]        # Similar large a1
    peak: { unit: "keV", val: 2614.51 }
    window: [{ val: 35 }, { val: 30 }]
    fwhm_before: { unit: "keV", val: 2.9087179486123205, err: 0.017808602615720613 }
    fwhm_after: { unit: "keV", val: 2.7226318574221295, err: 0.016079305087841268 }
    converged: true
    func: "e_trap + 9.979133296085468e-5 * qdrift^1 + 1.506815108363156e-13 * qdrift^2"
    m_cal_simple: { unit: "keV", val: 0.018823630951719374 }
```

### CTC Results Interpretation:

#### **Coefficient Analysis:**
- **Linear term (a1)**: Primary correction strength
  - **V02166B**: 5.58e-5 (moderate charge trapping)
  - **V07647B**: 9.81e-5 (stronger charge trapping, ~75% higher)
- **Quadratic term (a2)**: Non-linear effects (typically small)
  - Usually ~1e-12 to 1e-13 range
  - Smaller than linear term by 7-8 orders of magnitude

#### **Resolution Improvement:**
- **V02166B e_cusp**: 3.424 → 3.307 keV (~3.4% improvement)
- **V07647B e_cusp**: 2.901 → 2.722 keV (~6.2% improvement)
- **Pattern**: Detectors with stronger charge trapping show larger improvements

#### **Filter Comparison:**
- **Similar CTC coefficients** between e_cusp and e_trap for same detector
- **Similar resolution improvement** for both filters
- **Consistent results** indicate robust CTC optimization

#### **Quality Indicators:**
- **`converged: true`**: Optimization successful
- **Consistent windows**: [35, 30] keV standard fit region
- **Reasonable coefficients**: a1 ~ 1e-5 to 1e-4, a2 ~ 1e-13 to 1e-12
- **FWHM improvement**: Larger improvements indicate stronger charge trapping effects


