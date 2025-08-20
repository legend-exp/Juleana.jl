# ecal (energy calibration) run parameters — schema and field descriptions

Purpose: Document the structure and semantics of the energy calibration (ecal) run parameters saved under rpars. Produced by `process_energy_calibration` and used to convert ADC to keV and to evaluate energy resolution.

---

## Location

- Path per run: `.../legend_data_production/jl-v0.5.0/generated/jlpar/rpars/ecal/p<period>/r<run>.yaml`
- Scope: One YAML per run; top-level keys are detector IDs.

---

## Field descriptions

### Level 1: Detectors (top-level keys)
- **String**: Detector IDs (e.g., `V02166B`, `B00032C`, `P00712A`)
- **Meaning**: Groups all energy calibration results for that detector

### Level 2: Energy estimator types (detector sub-keys)
- **Energy Types**: `e_trap`, `e_cusp`, `e_trap_ctc`, `e_cusp_ctc` (and variants like `e_trap_max`, `e_cusp_max`)
- **Meaning**: Different energy estimation methods and their calibration results

#### Energy Estimator Types (from L-Note Section V):
- **`e_trap`**: **Trapezoidal filter** - symmetric filter with configurable rise/flat-top/fall times
- **`e_cusp`**: **CUSP filter** - finite-length cusp-like filter with flat-top center and sinh curves on sides
- **`e_zac`**: **ZAC filter** - Zero-Area CUSP with parabola subtraction for zero-area constraint
- **`_ctc` variants**: Charge-trapping corrected versions of the above filters
- **`_max` variants**: Maximum-finding estimation method instead of fixed-time pickoff

#### Physical Meaning and Process:
- **Purpose**: Convert raw ADC units from DSP filters to calibrated keV energy scale
- **Method**: **Weekly calibration** using ²²⁸Th sources with 7 distinct γ-peaks
- **Calibration peaks used**: Tl208a (583 keV), Bi212a (727 keV), Tl208b (861 keV), Tl208DEP (1593 keV), Bi212FEP (1621 keV), Tl208SEP (2104 keV), Tl208FEP (2615 keV)
- **Process**: Simple calibration → Peak fitting → Calibration curve → Resolution curve

### Level 3: Calibration data structure

#### 3.1: `cal` (Calibration curve)
- **Purpose**: ADC to keV conversion parameters
- **Contains**: Polynomial coefficients, measured peak positions, goodness-of-fit

#### 3.2: `fwhm` (Energy resolution)
- **Purpose**: Energy-dependent resolution model
- **Contains**: Resolution model coefficients, FWHM at Qββ, goodness-of-fit

#### 3.3: `fit` (Individual peak fits)
- **Purpose**: Detailed results for each fitted γ-line
- **Contains**: Peak properties, fit parameters, goodness-of-fit per peak

#### 3.4: `m_cal_simple` (Simple calibration)
- **Purpose**: First-pass calibration constant from FEP position
- **Contains**: Rough gain factor for initial spectrum preparation

### Level 4: Calibration vs Resolution vs Individual Fits

#### 4.1: Calibration fields (for `cal`)
- **`par`**: Vector{Object} - Polynomial coefficients with units and errors
  - **Default model**: Linear polynomial `E_cal = a0 + a1 * E_raw`
  - **a0**: Intercept in keV (additive offset)
  - **a1**: Slope in keV/ADC (multiplicative gain)
- **`func`**: String - Human-readable calibration expression
- **`func_err`**: String - Function with coefficient uncertainties
- **`μ`**: Vector{Object} - Measured peak centroids in ADC domain
- **`peaks`**: Vector{Object} - Literature γ-line energies and uncertainties
- **`gof`**: Object - Goodness-of-fit metrics for calibration curve

#### 4.2: Resolution fields (for `fwhm`)
- **`par`**: Vector{Object} - Resolution model coefficients
  - **Default model**: `FWHM(E) = sqrt(a0 + a1*E)` 
  - **a0**: Electronics/noise term in keV²
  - **a1**: Fano/statistical term in keV
- **`func`**: String - Resolution model expression in raw energy
- **`func_cal`**: String - Resolution model in calibrated energy
- **`func_err`**: String - Function with coefficient uncertainties
- **`func_cal_err`**: String - Calibrated function with uncertainties
- **`qbb`**: Object - FWHM at Qββ = 2039.061 keV with error
- **`peaks`**: Vector{Object} - Reference γ-lines for resolution fit
- **`fwhm`**: Vector{Object} - Measured FWHM values from individual fits
- **`gof`**: Object - Goodness-of-fit metrics for resolution model

#### 4.3: Individual peak names (for `fit`)
- **`Tl208FEP`**: ²⁰⁸Tl full-energy peak at 2614.511 keV
- **`Tl208SEP`**: ²⁰⁸Tl single-escape peak at 2103.512 keV  
- **`Tl208DEP`**: ²⁰⁸Tl double-escape peak at 1592.513 keV
- **`Bi212FEP`**: ²¹²Bi full-energy peak at 1620.50 keV
- **`Tl208b`**: ²⁰⁸Tl line at 860.557 keV
- **`Bi212a`**: ²¹²Bi line at 727.330 keV
- **`Tl208a`**: ²⁰⁸Tl line at 583.187 keV

### Level 5: Detailed field content

#### 5.1: Goodness-of-fit structure (common for cal, fwhm, and individual fits)
- **`converged`**: Boolean - Whether fit converged successfully
- **`chi2` / `chi2min`**: Float - Chi-squared value of fit
- **`dof`**: Integer - Degrees of freedom
- **`pvalue`**: Float - Statistical p-value of fit quality
- **`covmat`**: Matrix - Covariance matrix of fit parameters
- **`residuals_norm`**: Vector - Normalized residuals per data point

#### 5.2: Individual peak fit parameters (for `fit.<PeakName>`)
- **`n`**: `{val, err}` - Estimated signal counts in peak
- **`centroid`**: `{val, err, unit}` - Effective peak position (including tails)
- **`μ`**: `{val, err, unit}` - Gaussian mean of core component  
- **`σ`**: `{val, err, unit}` - Gaussian width of core component
- **`fwhm`**: `{val, err, unit}` - Full-width at half-maximum
- **`background`**: `{val, err}` - Flat background level
- **`step_amplitude`**: `{val, err}` - Compton step amplitude
- **`skew_fraction`**: `{val, err}` - Low-energy tail fraction (EMG weight)
- **`skew_width`**: `{val, err}` - Low-energy tail width parameter
- **`fit_func`**: String - Peak model used (e.g., "gamma_def")

#### 5.3: Peak fit models (from L-Note)
- **`gamma_def`**: Default model with Gaussian + EMG tail + Compton step + flat background
- **Escape peaks**: Extended model with additional high-energy tail, no Compton step
- **Components**:
  - **Signal**: Gaussian distribution (μ, σ, amplitude)
  - **Low-energy tail**: Exponentially modified Gaussian (EMG) for detector response
  - **High-energy tail**: Additional EMG for escape peaks (annihilation photon re-absorption)
  - **Background**: Energy-independent flat component + Compton step

---

## Provenance and generation

- Producer: `process_energy_calibration`.
- Inputs: `jlhit` data, optional `_ctc` energies derived using `rpars/ctc`, energy config lines and settings.
- Steps: `simple_calibration` → `fit_peaks` → `fit_calibration` → `fit_fwhm`; optionally repeated for `_ctc` types.

---

## Usage guidance

- Use `<energy_type>.cal` to convert to keV.
- Use `<energy_type>.fwhm` to evaluate resolution vs E and at Qββ.
- Compare resolved `qbb` between raw and `_ctc` estimators to quantify the benefit of CTC.

---

## Example Structure

```yaml
V02166B:
  # CUSP filter energy calibration
  e_cusp:
    # Calibration curve (ADC → keV conversion)
    cal:
      par:
        - { unit: "keV", val: 2.273913646227743, err: 0.043000273458110826 }    # a0: intercept
        - { unit: "keV", val: 0.023282015092759657, err: 4.601417738881464e-7 } # a1: slope
      func: "2.273913646227743keV .* (e_cusp).^0 .+ 0.023282015092759657keV .* (e_cusp).^1"
      func_err: "(2.274 ± 0.043)keV .* (e_cusp).^0 .+ (0.02328202 ± 4.6e-7)keV .* (e_cusp).^1"
      μ: # Measured peak positions in ADC
        - { val: 24955.008186520405, err: 2.256760826203578 }     # Tl208a in ADC
        - { val: 31130.479555841073, err: 5.692533737294767 }     # Bi212a in ADC
        - { val: 36851.517690577806, err: 5.323457808039461 }     # Tl208b in ADC
        - { val: 69483.55410533123, err: 23.511402569559472 }     # Bi212FEP in ADC
        - { val: 112199.98463350553, err: 1.2867395354386326 }    # Tl208FEP in ADC
      peaks: # Literature γ-line energies
        - { unit: "keV", val: 583.187, err: 0.002 }              # Tl208a
        - { unit: "keV", val: 727.33, err: 0.009 }               # Bi212a
        - { unit: "keV", val: 860.557, err: 0.004 }              # Tl208b
        - { unit: "keV", val: 1620.5, err: 0.1 }                 # Bi212FEP
        - { unit: "keV", val: 2614.511, err: 0.01 }              # Tl208FEP
      gof:
        converged: true
        chi2min: 14.153896380952636
        dof: 3
        pvalue: 0.002702984201440912
        residuals_norm: [-1.7077, 2.0761, 2.4636, 0.9146, -0.1472]
        covmat: [[0.0018490235174723104, -1.7899846140980354e-8], [...]]

    # Energy resolution model  
    fwhm:
      par:
        - { unit: "keV", val: 4.509693489816247, err: 0.06703948442820899 }     # a0: noise term
        - { val: 0.002752728177203988, err: 4.3871090136421995e-5 }              # a1: Fano term
      func: "sqrt(4.509693489816247 * (e_cusp)^0 + 0.002752728177203988 * (e_cusp)^1)keV"
      func_cal: "sqrt(4.509693489816247 * e_cusp_cal^0 * keV^2 + 0.002752728177203988 * e_cusp_cal^1 * keV^1)"
      func_err: "sqrt((4.51 ± 0.067) * (e_cusp)^0 + (0.002753 ± 4.4e-5) * (e_cusp)^1)keV"
      func_cal_err: "sqrt((4.51 ± 0.067) * e_cusp_cal^0 * keV^2 + (0.002753 ± 4.4e-5) * e_cusp_cal^1 * keV^1)"
      qbb: { unit: "keV", val: 3.181615023781788, err: 0.01756786450872361 }   # FWHM at Qββ
      peaks: # Same as cal.peaks
        - { unit: "keV", val: 583.187, err: 0.002 }
        - { unit: "keV", val: 727.33, err: 0.009 }
        # ... (same as calibration peaks)
      fwhm: # Measured FWHM from individual fits
        - { unit: "keV", val: 2.482794796451946, err: 0.016190121446278613 }    # Tl208a FWHM
        - { unit: "keV", val: 2.528070795882051, err: 0.03127418116384789 }     # Bi212a FWHM
        # ... (continuing for all peaks)
      gof:
        converged: true
        chi2min: 1.576719253431012
        dof: 3
        pvalue: 0.6646800170281327
        residuals_norm: [0.6135, -0.7597, -0.7496, 0.2347, 0.0787]
        covmat: [[0.004494292472400075, -2.3690472372556594e-6], [...]]

    # Individual peak fit results
    fit:
      Tl208FEP:
        n: { val: 41844.206309467954, err: 208.02280550680382 }
        centroid: { unit: "keV", val: 2614.515649290905, err: 0.07356588001297289 }
        μ: { unit: "keV", val: 2614.681054169322, err: 0.06840602613069768 }
        σ: { unit: "keV", val: 1.4321569162112513, err: 0.007919811806884482 }
        fwhm: { unit: "keV", val: 3.422694463868735, err: 0.01505193443749427 }
        background: { val: 4.47911618937611, err: 0.4277511354303056 }
        step_amplitude: { val: 35.98646272954552, err: 1.570477951596213 }
        skew_fraction: { val: 0.06854805133574655, err: 0.008777937955252843 }
        skew_width: { val: 0.0009236604305874657, err: 9.415356800704113e-5 }
        fit_func: "gamma_def"
        gof:
          converged: true
          chi2: 570.3306051290131
          dof: 433
          pvalue: 9.75377313490873e-6
          mean_residuals: 0.005370172682666186
          median_residuals: 0.2951031606392077
          std_residuals: 0.983749161978705
          covmat: [[0.00016483216951088667, ...], [...], ...]
      
      Tl208b:
        # ... similar structure for 860 keV peak
        
      # ... other peaks: Tl208a, Bi212a, Tl208DEP, Bi212FEP, Tl208SEP

    # Simple calibration slope (first approximation)
    m_cal_simple: { unit: "keV", val: 0.02329961231102969 }

  # Trapezoidal filter calibration (similar structure)
  e_trap:
    # ... same structure as e_cusp
    
  # Charge-trapping corrected variants  
  e_cusp_ctc:
    # ... same structure but using CTC-corrected energies
    
  e_trap_ctc:
    # ... same structure but using CTC-corrected energies
```


