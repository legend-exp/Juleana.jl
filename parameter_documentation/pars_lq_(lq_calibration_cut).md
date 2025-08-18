# lq (LQ calibration and cut) run parameters — schema and field descriptions

Purpose: Document the structure and semantics of LQ calibration and cut parameters saved under rpars by `process_lq_calibration_cut`. Used to compute normalized LQ and apply the optimized high-side cut in downstream analysis.

---

## Location

- Path per run: `.../legend_data_production/jl-v0.5.0/generated/jlpar/rpars/lq/p<period>/r<run>.yaml`
- Scope: One YAML per run; top-level keys are detector IDs.

---

## Field descriptions

### Level 1: Detectors (top-level keys)
- **String**: Detector IDs (e.g., `V02166B`, `B00032C`, `P00712A`)
- **Meaning**: Groups all LQ calibration and classification results for that detector

### Level 2: LQ calibration and classifier (detector sub-keys)
- **`lq`**: Calibration data for charge-trapping correction and normalization
- **`lq_classifier`**: Cut results and performance metrics for PSD

#### LQ Physical Meaning and Purpose:
The **LQ (Late Charge) parameter** characterizes the waveform shape during the **final portion of its rising edge** (after reaching 80% of maximum amplitude):

- **Surface Events**: Alpha and beta interactions have **slow charge collection** and **incomplete charge collection** → **higher LQ values**
- **Bulk Events**: Complete charge collection from germanium volume → **lower LQ values**  
- **Multi-Site Events**: "Kink" in final 20% of waveform → **altered LQ values**
- **Cut Direction**: **High-side cut only** (reject events with `lq_norm > highcut`)

#### LQ Parameter Extraction:
- **Definition**: Difference between two 2.5 µs integrated waveform areas
- **First area**: Starts at **t80** (when waveform reaches 80% of maximum)
- **Second area**: Starts immediately after first area ends
- **Raw Parameter**: `LQ_raw = Area1 - Area2`

### Level 3: Content of `lq` and `lq_classifier`

#### 3.1: `lq` (Calibration data)
- **`func`**: Final normalized LQ expression in σ units
- **`drift_result`**: Charge-trapping correction (CTC) 
- **`fit_result`**: DEP normalization fit results
- **`mean_lq`**, **`median_lq`**, **`std_lq`**: Optional statistics

#### 3.2: `lq_classifier` (Classification data)
- **`highcut`**: Cut threshold (Float, σ units, typically 3.0)
- **`peaks`**: Validation peak performance (Dictionary)
- **`qbb`**: Performance at Qββ (Struct)

### Level 4: Calibration vs Classification content

#### 4.1: Calibration fields (for `lq`)
- **`func`**: String - Final normalized LQ expression in σ units to evaluate on hit data
- **`drift_result`**: Object - Charge-trapping correction (CTC)
  - `func`: String - Polynomial correction expression in `qdrift/e_cusp`
  - `fit_result`: Object - Linear fit parameters and convergence
  - `box_constraints`: Object - Selection bounds used in fitting (energy/drift windows)
- **`fit_result`**: Object - DEP normalization fit results
  - `μ`: `{val, err}` - Mean of truncated Gaussian fit
  - `σ`: `{val, err}` - Sigma of truncated Gaussian fit  
  - `n`: `{val, err}` - Amplitude of fit
  - `gof`: Object - Goodness-of-fit metrics (pvalue, dof, chi2, residuals, covmat)
- **`mean_lq`**, **`median_lq`**, **`std_lq`**: Float - Optional descriptive statistics

#### 4.2: Classification fields (for `lq_classifier`)
- **`highcut`**: Float - High-side LQ cut threshold in σ units (typically 3.0)
- **`peaks`**: Object - Survival fractions at validation peaks
- **`qbb`**: Object - Continuum survival around Qββ

### Level 5: Peak/QBB content (same structure for all)

#### 5.1: Common fields (all peaks and qbb)
- **`fit_func`**: Fit function used (e.g., "gamma_def")
- **`n_before`**: `{val, err}` - Events before LQ cut (from fit integral)
- **`n_after`**: `{val, err}` - Events after LQ cut (from fit integral)  
- **`sf`**: `{val, err, unit}` - Survival fraction in % (n_after/n_before)

#### 5.2: Peak-specific fields (only for peaks, not qbb)
- **`peak`**: Peak metadata (energy, fit window)
- **`gof`**: Detailed goodness-of-fit structure

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
- **`survived`**: Reference fit metrics (all events)
  - `covmat`: Matrix - Reference covariance matrix
  - `pvalue`: Float - Reference p-value
  - `dof`: Integer - Reference degrees of freedom
  - `chi2`: Float - Reference chi-squared
  - `residuals`: Vector - Fit residuals for diagnostics

---

## Provenance and generation

- Producer: `process_lq_calibration_cut`.
- Inputs: `jlhit` data (dataQC), `rpars/ecal` (DEP µ, σ), LQ PSD config.
- Steps: LQ CTC in DEP → DEP-based normalization (sideband subtraction + truncated Gaussian) → choose high-side cut → evaluate SFs at peaks and Qββ.

---

## Usage guidance

- Evaluate `lq.func` to compute normalized LQ on hits, then apply `lq_classifier.highcut` for background rejection.
- Compare peak and Qββ SFs across detectors to monitor stability; adjust `high_cut_sigma` in config if needed.

---

## Example Structure

```yaml
V02166B:
  # LQ calibration data
  lq:
    func: " ( (( ( lq / e_cusp ) / 0.24396426873158966 ) - 0.9946708730146661 * (qdrift / e_cusp)^0 - 0.0017241501386760756 * (qdrift / e_cusp)^1)  - 0.00019871076556826194 ) / ( 0.026049117881587508 )"
    
    # Charge-trapping correction results  
    drift_result:
      func: "( ( lq / e_cusp ) / 0.24396426873158966 ) - 0.9946708730146661 * (qdrift / e_cusp)^0 - 0.0017241501386760756 * (qdrift / e_cusp)^1"
      fit_result:
        converged: true
        par: 
          - { val: 0.9946708730146661, err: null }
          - { val: 0.0017241501386760756, err: null }
      box_constraints:
        lq_lower: 0.9184969223282617
        lq_upper: 1.0991022178363659  
        t_lower: 5.359121625356089
        t_upper: 10.712121746790986
    
    # DEP normalization fit results
    fit_result:
      μ: { val: 0.00019871076556826194, err: 0.002756240476861678 }
      σ: { val: 0.026049117881587508, err: 0.0037546904442682695 }  
      n: { val: 705.961661085101, err: 81.33632886459581 }
      gof:
        pvalue: 0.04008876343230844
        dof: 2
        chi2: 6.43331839518988
        residuals: [5.402981377667935, -7.306876068551574, ...]
        covmat: [[7.596861566290689e-6, ...], [...], ...]
    
    # Optional statistics
    mean_lq: 0.26615482816954017
    median_lq: 0.23682618257220842
    std_lq: 0.18723056743197936

  # LQ classification results  
  lq_classifier:
    highcut: 3.0  # σ units
    
    # Performance at validation peaks
    peaks:
      Tl208FEP:
        fit_func: "gamma_def"
        n_before: { val: 41870.10467333232, err: 208.23045263264808 }
        n_after: { val: 34036.32132072399, err: 186.38311616657525 }
        sf: { val: 81.35545824894528, err: 0.1947585482461791, unit: "percent" }
        gof:
          after:
            converged: true  
            survived:
              covmat: [[7.107903134264773e-5, ...], [...], ...]
              pvalue: 8.426833633842744e-11
              dof: 144
              chi2: 655.5746632354056
            cut:
              covmat: [[1.4688158775090547e-5, ...], [...], ...]
              pvalue: 1.5646139005190896e-19
              dof: 144  
              chi2: 867.9029701829193
          before:
            converged: true
            survived:
              covmat: [[6.239051822273126e-5, ...], [...], ...]
              pvalue: 1.0030056458340993e-22
              dof: 144
              chi2: 1026.8088491142776
              residuals: [24.831133834966313, -9.051096398493004, ...]
      
      Tl208DEP:
        # ... similar structure
      
      Bi212FEP: 
        # ... similar structure
        
      Tl208SEP:
        # ... similar structure
    
    # Performance at Qββ  
    qbb:
      window: { val: 2039.0, err: 35.0, unit: "keV" }
      n_before: { val: 8268.0, err: 90.92854337335444 }  
      n_after: { val: 6432.0, err: 80.19975062305369 }
      sf: { val: 77.79390420899854, err: 0.4570972982954241, unit: "percent" }
```
