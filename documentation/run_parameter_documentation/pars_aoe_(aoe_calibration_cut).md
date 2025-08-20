# aoe (A/E calibration and cuts) run parameters — schema and field descriptions

Purpose: Document the structure and semantics of A/E calibration and cut parameters saved under rpars by `process_aoe_calibration_cut`. Used to build corrected A/E expressions and to apply optimized AoE cuts in downstream analysis.

---

## Location

- Path per run: `.../legend_data_production/jl-v0.5.0/generated/jlpar/rpars/aoe/p<period>/r<run>.yaml`
- Scope: One YAML per run; top-level keys are detector IDs.

---

## Field descriptions by hierarchy

### Level 1: DetectorId (top-level keys)
- **Type**: String (e.g., `V02166B`, `B00032C`)
- **Meaning**: Groups all AoE calibration and cut results for one detector

### Level 2: AoE types and classifiers (detector sub-keys)
- **AoE Types**: `aoe_sg`, `aoe_100`, `aoe_raw` - Calibration data for different current amplitude variants
- **AoE Classifiers**: `aoe_sg_classifier`, `aoe_100_classifier`, `aoe_raw_classifier` - Cut results for PSD

#### Current Amplitude Estimation Methods:
- **`a_raw`**: Numerical derivative without further filtering (raw current estimation)
- **`a_60`, `a_100`**: Third-order Savitzky-Golay filter applied to waveform
  - Filter length in ns indicated by subscript (60ns, 100ns, etc.)
  - After filtering, numerical derivative calculated to get current
- **`a_sg`**: Optimized third-order Savitzky-Golay filter length
  - Filter length optimized per detector using DEP/SEP data
  - Optimization grid: 30ns to 350ns with 32ns steps
  - Selected based on highest background suppression (lowest SEP survival fraction)

#### A/E Calculation:
All variants use the same formula: **A/E = current_amplitude / energy**
- **`aoe_raw`**: `a_raw / e_cusp` 
- **`aoe_100`**: `a_100 / e_cusp`
- **`aoe_sg`**: `a_sg / e_cusp`

Where `e_cusp` is the calibrated energy from the CUSP filter.

#### Physical Meaning and Purpose:
- **Current Signal**: Derivative of digitized charge signal from CSA (Charge Sensitive Amplifier)
- **A/E Ratio**: Measures pulse shape - single-site events have sharper current pulses (higher A/E) than multi-site events
- **PSD Goal**: Discriminate between single-site events (0νββ signal-like) and multi-site events (background-like)
- **Filter Trade-off**: Balance between noise reduction (filtering) and signal fidelity (raw)
- **Maximum Finding**: After current calculation, maximum found by quadratic interpolation of last three samples around maximum sample

### Level 3: Main categories

#### 3.1: AoE calibration entries (`aoe_sg`, `aoe_100`, `aoe_raw`)
- **Type**: Object with calibration parameters
- **Meaning**: Energy-dependent AoE corrections and expressions for each amplitude variant
- **Contains**: `func`, `correction`, `ctc` (optional)

#### 3.2: AoE classifier entries (`aoe_*_classifier`)
- **Type**: Object with cut results and performance metrics
- **Meaning**: PSD cut parameters and survival fractions for this AoE variant
- **Contains**: `lowcut`, `highcut`, `n0`, `nsf`, `sf`, `peaks`, `qbb`

### Level 4: Calibration vs Classification content

#### 4.1: Calibration fields (for `aoe_sg`, `aoe_100`, `aoe_raw`)
- **`func`**: String - Final corrected A/E expression to evaluate on hit data
- **`correction`**: Object - Energy-dependent calibration parameters
  - `μ`: Vector{Float64} - Polynomial coefficients for μ(E) correction (typically 2nd order)
  - `σ`: Vector{Float64} - Polynomial coefficients for σ(E) correction (typically 2nd order)  
  - `gof`: Object - Goodness-of-fit summary
    - `median_residuals`: Float - Median residuals across Compton bands
    - `std_residuals`: Float - Standard deviation of residuals
- **`ctc`**: Object - Charge-trapping correction (present if applied)
  - `fct`: Vector{Float64} - CTC coefficients
  - `func`: String - CTC-corrected A/E expression

#### 4.2: Classification fields (for `aoe_*_classifier`)
- **`lowcut`**: `{val, err}` - Optimized lower A/E cut (solves for target DEP SF)
- **`highcut`**: Float - High-side A/E cut (typically +σ_high_sided from config)
- **`n0`**: `{val, err}` - Number of events at DEP before cuts
- **`nsf`**: `{val, err}` - Number of events at DEP after cuts
- **`sf`**: `{val, err, unit}` - Survival fraction at DEP in percent
- **`peaks`**: Object - Survival fractions at validation peaks
- **`qbb`**: Object - Continuum survival around Qββ

### Level 5: Peak and QBB structure

#### 5.1: Cut modes (for `peaks` and `qbb`)
- **`low`**: Only AOE low cut applied (`aoe >= lowcut`)
- **`ds`**: AOE double-sided cut (`lowcut <= aoe <= highcut`)

#### 5.2: Peak names (only for `peaks.<mode>`)
- **`Tl208SEP`**: Single escape peak at 2103.53 keV
- **`Tl208FEP`**: Full energy peak at 2614.51 keV

### Level 6: Peak/QBB content structure

#### 6.1: Common fields (for all peaks and qbb entries)
- **`n_before`**: `{val, err}` - Number of events before cuts (from fit integral)
- **`n_after`**: `{val, err}` - Number of events after cuts (from fit integral)
- **`sf`**: `{val, err, unit}` - Survival fraction (n_after/n_before) in percent
- **`window`**: `{val, err, unit}` - Energy window used for analysis (qbb only)

#### 6.2: Peak-specific fields
- **`fit_func`**: String - Fit function used (e.g., "gamma_def", "gamma_tails_bckFlat")
- **`peak`**: `{val, unit}` - Peak energy in keV
- **`gof`**: Goodness-of-fit metrics (same structure as PSD parameters)

### Level 7: Goodness-of-fit structure (peaks only)

#### 7.1: `gof.after` - Fit results after cuts
- **`converged`**: Boolean - Whether fit converged
- **`survived`**: Fit metrics for events that passed cuts
  - `covmat`: Matrix - Covariance matrix
  - `pvalue`: Float - Statistical p-value
  - `dof`: Integer - Degrees of freedom
  - `chi2`: Float - Chi-squared value
- **`cut`**: Fit metrics for events that failed cuts
  - `covmat`: Matrix - Covariance matrix  
  - `pvalue`: Float - Statistical p-value
  - `dof`: Integer - Degrees of freedom
  - `chi2`: Float - Chi-squared value

#### 7.2: `gof.before` - Reference fit (no cuts)
- **`converged`**: Boolean - Whether reference fit converged
- **`covmat`**: Matrix - Covariance matrix
- **`pvalue`**: Float - Statistical p-value
- **`dof`**: Integer - Degrees of freedom
- **`chi2`**: Float - Chi-squared value
- **`mean_residuals`**: Float - Mean of fit residuals
- **`median_residuals`**: Float - Median of fit residuals  
- **`std_residuals`**: Float - Standard deviation of fit residuals

---

## Provenance and generation

- Producer: `process_aoe_calibration_cut`.
- Inputs: `jlhit` data (dataQC), `rpars/ecal` for energy mapping, AoE PSD config.
- Steps: AoE normalization → Compton bands → per-band fits → μ/σ(E) corrections → optional CTC → cut optimization → SF evaluation.

---

## Usage guidance

- Use `<aoe_type>.func` to compute corrected A/E values on calibrated hits.
- Apply classifier cuts from `<aoe_type>_classifier` (prefer double-sided when configured) to reject MSE.
- Compare SFs across AoE types to pick best-performing classifier for downstream selection.

---

## Example Structure

```yaml
V02166B:
  # Calibration data for aoe_100 variant
  aoe_100:
    func: "( ( a_100 / e_cusp ) / 0.244 ) - 0.995 * (qdrift / e_cusp)^0 - 0.002 * (qdrift / e_cusp)^1"
    correction:
      μ: [-1.657, 0.0024, -3.2e-7]           # 2nd order polynomial coefficients for μ(E)
      σ: [0.026, -1.4e-5, 2.1e-9]           # 2nd order polynomial coefficients for σ(E)
      gof:
        median_residuals: 0.012
        std_residuals: 1.035
    ctc:                                     # Present if charge-trapping correction applied
      fct: [0.995, 0.002]                    # CTC coefficients
      func: "corrected_expression_with_ctc"  # CTC-corrected A/E expression
  
  # Cut results and performance for aoe_100 classifier
  aoe_100_classifier:
    lowcut: { val: -1.878, err: -1.88e-5 }   # Optimized at 90% DEP SF
    highcut: 3.0                             # 3σ high-side cut
    n0: { val: 1154.59, err: 111.92 }       # Events at DEP before cuts
    nsf: { val: 1039.25, err: 152.97 }      # Events at DEP after cuts  
    sf: { val: 90.01, err: 9.97, unit: "%" } # DEP survival fraction
    peaks:
      ds:                                    # Double-sided cut results
        Tl208FEP:
          fit_func: "gamma_def"
          n_before: { val: 41869.98, err: 208.23 }
          n_after: { val: 3819.87, err: 61.80 }
          sf: { val: 9.12, err: 0.14, unit: "%" }
          peak: { val: 2614.51, unit: "keV" }
          gof:
            after:
              converged: true
              survived:
                covmat: [[...], [...], ...]  # Covariance matrix (survived)
                pvalue: 0.0105               # P-value
                dof: 184                     # Degrees of freedom
                chi2: 231.15                 # Chi-squared
              cut:
                covmat: [[...], [...], ...]  # Covariance matrix (rejected)
                pvalue: 8.33e-13
                dof: 423
                chi2: 708.37
            before:
              converged: true
              covmat: [[...], [...], ...]    # Reference covariance
              pvalue: 1.89e-8
              dof: 428
              chi2: 582.16
              mean_residuals: 0.0021
              median_residuals: 0.168
              std_residuals: 1.029
    qbb:
      ds: { val: 34.35, err: 0.52, unit: "%" }    # Qββ continuum survival (double-sided)
      low: { val: 35.53, err: 0.53, unit: "%" }   # Qββ continuum survival (low-only)
```
