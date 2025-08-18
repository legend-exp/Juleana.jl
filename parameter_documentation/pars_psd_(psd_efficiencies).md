# psd (combined PSD efficiencies) run parameters — schema and field descriptions

Purpose: Document the structure of PSD efficiency results saved by `process_psd_efficiencies`. Used for sensitivity estimates, background studies, and cross-checks of classifier performance.

---

## Location

- Path per run: `.../legend_data_production/jl-v0.5.0/generated/jlpar/rpars/psd/p<period>/r<run>.yaml`
- Scope: One YAML per run; top-level keys are detector IDs.

---

## Field descriptions by hierarchy

### Level 1: DetectorId (top-level keys)
- **Type**: String (e.g., `V02166B`, `B00032C`)
- **Meaning**: Groups all PSD efficiency results for one detector

### Level 2: Classifier (detector sub-keys)
- **Type**: String (config-driven name)
- **Examples**: `low_aoe_sg_high_aoe_3_lq_classifier`, `low_aoe_sg_high_aoe_9_lq_classifier`
- **Meaning**: Identifies a specific combination of AoE and LQ cuts
- **Contains**: `cuts`, `peaks`, `qbb`

### Level 3: Main categories

#### 3.1: `cuts`
- **Type**: Object with cut parameters
- **Meaning**: Concrete cut values used for this classifier, resolved from AoE/LQ rpars
- **Contains**:
  - `aoe_type`: String - AoE variant used (e.g., "aoe_sg")
  - `lowcut`: `{val, err}` - AOE lower cut value  
  - `highcut`: `{val, err}` - AOE upper cut value
  - `lq_highcut`: `{val, err}` - LQ upper cut value (present if LQ used)

#### 3.2: `peaks`
- **Type**: Object with peak analysis results
- **Meaning**: Survival fractions at validation peaks for different cut combinations
- **Contains**: `low`, `ds`, `low_lq`, `lq_ds` (mode-dependent)

#### 3.3: `qbb`
- **Type**: Object with continuum analysis results
- **Meaning**: Continuum survival around Qββ for different cut combinations  
- **Contains**: `low`, `ds`, `low_lq`, `lq_ds` (mode-dependent)

### Level 4: Cut modes and peak names

#### 4.1: Cut modes (for `peaks` and `qbb`)
- **`low`**: Only AOE low cut applied (`aoe >= lowcut`)
- **`ds`**: AOE double-sided cut (`lowcut <= aoe <= highcut`)
- **`low_lq`**: AOE low + LQ high cut (`aoe >= lowcut AND lq <= lq_highcut`)
- **`lq_ds`**: All cuts combined (`lowcut <= aoe <= highcut AND lq <= lq_highcut`)

#### 4.2: Peak names (only for `peaks.<mode>`)
- **`Tl208DEP`**: Double escape peak at 1592.53 keV
- **`Bi212FEP`**: Full energy peak at 1620.50 keV  
- **`Tl208SEP`**: Single escape peak at 2103.53 keV
- **`Tl208FEP`**: Full energy peak at 2614.51 keV

### Level 5: Peak/QBB content structure

#### 5.1: Common fields (for all peaks and qbb entries)
- **`n_before`**: `{val, err}` - Number of events before cuts (from fit integral)
- **`n_after`**: `{val, err}` - Number of events after cuts (from fit integral)  
- **`sf`**: `{val, err, unit}` - Survival fraction (n_after/n_before) in percent
- **`window`**: `{val, err, unit}` - Energy window used for analysis (qbb only)

#### 5.2: Peak-specific fields
- **`fit_func`**: String - Fit function used (e.g., "gamma_def", "trunc_gauss_bck")
- **`peak`**: `{val, unit}` - Peak energy in keV
- **`gof`**: Goodness-of-fit metrics (detailed structure below)

### Level 6: Goodness-of-fit structure (peaks only)

#### 6.1: `gof.after` - Fit results after cuts
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

#### 6.2: `gof.before` - Reference fit (no cuts)
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

- Producer: `process_psd_efficiencies`.
- Inputs: `jlhit` data (dataQC), `rpars/aoe`, `rpars/lq`, PSD config for classifier definitions and windows.
- Steps: Resolve classifier → evaluate AoE/LQ expressions → build masks for low/ds/low_lq/lq_ds → fit peaks for SF → compute Qββ survival.

---

## Usage guidance

- Pick the classifier that best balances signal acceptance and background rejection; use `qbb` survival for sensitivity and `peaks` for sanity checks.
- Ensure consistency by using the same energy estimator as referenced by the AoE/LQ rpars.

---

## Example Structure

```yaml
V02166B:
  low_aoe_sg_high_aoe_3_lq_classifier:
    cuts:
      aoe_type: "aoe_sg"
      lowcut: { val: -1.657, err: 0.02 }
      highcut: { val: 3.0, err: 0.0 }
      lq_highcut: { val: 3.0, err: 0.0 }
    peaks:
      lq_ds:                              # AOE double-sided + LQ high cut
        Tl208DEP:
          fit_func: "gamma_tails_bckFlat"
          n_before: { val: 1663.87, err: 0.11 }
          n_after: { val: 1468.93, err: 62.13 }
          sf: { val: 88.28, err: 3.73, unit: "%" }
          peak: { energy: 1592.53, window_left: 20.0, window_right: 20.0 }
          gof:
            after:
              converged: true
              survived:
                covmat: [[...], [...], ...]             # Covariance matrix (survived events)
                pvalue: 1.09e-16                        # P-value of survived fit
                dof: 144                                 # Degrees of freedom
                chi2: 330.46                            # Chi-squared value
              cut:
                covmat: [[...], [...], ...]             # Covariance matrix (rejected events)  
                pvalue: 4.07e-8                         # P-value of rejected fit
                dof: 423                                 # Degrees of freedom
                chi2: 597.95                            # Chi-squared value
            before:
              converged: true
              covmat: [[...], [...], ...]               # Reference covariance (no cuts)
              pvalue: 8.80e-8                           # P-value of reference fit
              dof: 428                                   # Degrees of freedom  
              chi2: 598.71                              # Chi-squared value
              mean_residuals: 0.0026                    # Mean residuals
              median_residuals: 0.201                   # Median residuals
              std_residuals: 1.039                      # Standard deviation residuals
    qbb:
      lq_ds: { val: 33.56, err: 0.52, unit: "%" }      # Qββ continuum survival
```
