# pz (decay time) run parameters — schema and field descriptions

Purpose: Document the structure and semantics of the decay-time (pz) run parameters saved under rpars. These parameters are produced by the `process_decay_time` processor and used downstream for pole-zero correction.

---

## Location

- Path per run: `.../legend_data_production/jl-v0.5.0/generated/jlpar/rpars/pz/p<period>/r<run>.yaml`
- Scope: One YAML file per run, with one top-level entry per detector (detector ID as key, e.g., `P00664A`).

---

## Field descriptions

### Level 1: Detectors (top-level keys)
- **String**: Detector IDs (e.g., `V02166B`, `V07647B`, `V01240A`)
- **Meaning**: Groups decay time determination results for that detector

### Level 2: Decay time results (detector sub-keys)
- **`τ`**: Final decay time constant used for pole-zero correction
- **`fit`**: Detailed fit results from truncated Gaussian analysis

#### Physical Meaning and PZ Process (from L-Note Section IV):
- **Pole-Zero Correction Purpose**: Remove **exponential tail** in detector waveforms caused by **RC decay** in charge-sensitive amplifier (CSA)
- **RC Decay**: CSA feedback has finite resistance → exponential decay with time constant τ
- **Effect**: Long exponential tail can cause **baseline shifts** and **pileup effects**
- **PZ Correction**: Digital filtering to **cancel the exponential tail** using measured decay time τ

#### **Decay Time Measurement Process:**
- **Waveform Analysis**: Extract decay time from **falling edge** of detector pulses
- **Statistical Approach**: Measure many pulses, fit distribution with **truncated Gaussian**
- **Quality Cuts**: Apply cuts to remove outliers and poorly-formed pulses
- **Reference Peak**: Usually calibration peaks with good statistics (e.g., Tl208 lines)

### Level 3: Decay time components

#### 3.1: `τ` (Final Decay Time)
- **Purpose**: Canonical decay time value for downstream pole-zero correction
- **Source**: Directly copied from `fit.μ.val` (mean of fitted distribution)
- **Type**: Object with unit, value, and uncertainty

#### 3.2: `fit` (Fit Analysis Results)
- **Purpose**: Complete statistical analysis of decay time distribution
- **Method**: Truncated Gaussian fit to remove outlier effects
- **Contains**: μ, σ, goodness-of-fit, covariance matrix

### Level 4: Detailed field content

#### 4.1: Final decay time structure (`τ`)
- **`unit`**: String - Always "μs" (microseconds)
- **`val`**: Float - Mean decay time from truncated Gaussian fit
- **`err`**: Float - Uncertainty from fit (typically equal to `fit.μ.err`)
- **Typical Range**: 400-600 μs for HPGe detectors (depends on CSA feedback)

#### 4.2: Fit parameter structure (`fit.μ` and `fit.σ`)
- **`μ` (Mean)**:
  - `unit`: "μs", `val`: Mean decay time, `err`: Fit uncertainty
  - **Physical meaning**: Central value of decay time distribution
- **`σ` (Standard Deviation)**:
  - `unit`: "μs", `val`: Spread of decay times, `err`: Fit uncertainty  
  - **Physical meaning**: Measurement precision and intrinsic variations
- **Typical Values**: μ ~ 400-600 μs, σ ~ 5-15 μs

#### 4.3: Goodness-of-fit structure (`fit.gof`)
- **`chi2`**: Float - Chi-squared statistic (lower better for given dof)
- **`dof`**: Integer - Degrees of freedom in fit
- **`pvalue`**: Float - Statistical p-value (>0.05 typically acceptable)
- **`residuals`**: Vector{Float} - Fit residuals per histogram bin
- **`residuals_norm`**: Vector{Float} - Normalized residuals (unitless)
- **`bin_centers`**: Vector{Float} - Histogram bin centers in μs
- **Quality Assessment**: Good fit has pvalue > 0.01, |residuals_norm| < 3

#### 4.4: Covariance matrix structure (`fit.covmat`)
- **Type**: 2×2 Matrix for parameters (μ, σ)
- **Structure**: `[[var(μ), cov(μ,σ)], [cov(μ,σ), var(σ)]]`
- **Diagonal**: Variances of μ and σ parameters
- **Off-diagonal**: Correlation between μ and σ estimates
- **Usage**: Uncertainty propagation for derived quantities

---

## Provenance and generation

- Producer: `process_decay_time` processor.
- Inputs: jlpeaks waveforms at the configured peak; DSP windows; QC mask (optional ML); histogram window (`min_tau`, `max_tau`, `nbins`, `rel_cut_fit`).
- Fit: `fit_single_trunc_gauss` applied to decay-time values within cuts defined by `cut_single_peak`.
- Mapping: `τ` is set from `fit.μ`; uncertainties derive from the fit (σ and covariance).

---

## Usage guidance

- Use `τ.val` (unit `μs`) as the decay time constant for pole-zero correction.
- Inspect `fit.gof` (chi2/dof, pvalue) to validate fit quality.
- Large `σ.val` or extreme residuals may indicate poor statistics or windowing; consider adjusting DSP/cut parameters.
- Correlations (covmat off-diagonal) can inform uncertainty propagation when combining parameters.

---

## Example Structure

```yaml
V02166B:
  # Final decay time for pole-zero correction
  τ: { unit: "μs", val: 475.70011130173674, err: 0.08976651819402667 }

  # Detailed fit analysis
  fit:
    μ: { unit: "μs", val: 475.70011130173674, err: 0.08976651819402667 }    # Mean decay time
    σ: { unit: "μs", val: 9.50802783994246, err: 0.08361401515406337 }      # Spread of distribution
    
    gof:
      chi2: 63.51652114663188                    # Chi-squared statistic
      dof: 36                                    # Degrees of freedom  
      pvalue: 0.003121569483185909              # P-value (marginal fit quality)
      residuals: [-20.563, 4.847, -4.818, ...]  # Fit residuals per bin
      residuals_norm: [-2.542, 0.536, -0.479, ...] # Normalized residuals
      bin_centers: [455.514, 456.542, 457.571, ...] # Histogram bin centers (μs)
    
    covmat: [[0.008058027788678522, 0.0004379337215579016],     # var(μ), cov(μ,σ)
             [0.0004379337215579016, 0.006991303530183939]]     # cov(μ,σ), var(σ)

V07647B:
  # Different detector with shorter decay time and better precision
  τ: { unit: "μs", val: 454.56809613655975, err: 0.04147879354390721 }

  fit:
    μ: { unit: "μs", val: 454.56809613655975, err: 0.04147879354390721 }    # Shorter decay time
    σ: { unit: "μs", val: 4.306536281542118, err: 0.03979337338072136 }     # Much smaller spread
    
    gof:
      chi2: 45.23                               # Better chi-squared
      dof: 38                                   # Similar degrees of freedom
      pvalue: 0.187                             # Good p-value
      residuals: [...]                          # Better residuals pattern
      residuals_norm: [...]                     # Better normalized residuals
      bin_centers: [...]                        # Similar bin structure
    
    covmat: [[0.00171, 0.0001],                 # Smaller uncertainties
             [0.0001, 0.00158]]                 # Less correlation

V01240A:
  # High-quality detector with excellent fit statistics
  τ: { unit: "μs", val: 489.2, err: 0.03 }

  fit:
    μ: { unit: "μs", val: 489.2, err: 0.03 }                               # Very precise measurement
    σ: { unit: "μs", val: 3.8, err: 0.025 }                               # Excellent precision
    
    gof:
      chi2: 32.1                                # Excellent chi-squared
      dof: 35                                   # Good statistics
      pvalue: 0.62                              # Excellent p-value
      residuals: [...]                          # Small, random residuals
      residuals_norm: [...]                     # All |residuals_norm| < 2
      bin_centers: [...]                        # Fine binning
    
    covmat: [[0.0009, 0.00005],                 # Minimal uncertainties
             [0.00005, 0.000625]]               # Weak correlation
```

### Decay Time Results Interpretation:

#### **Decay Time Values (τ):**
- **V02166B**: 475.7 μs (typical value, moderate precision)
- **V07647B**: 454.6 μs (shorter decay, better precision)
- **V01240A**: 489.2 μs (longer decay, excellent precision)
- **Physical Range**: 400-600 μs typical for HPGe detectors
- **CSA Dependence**: Different electronics may have different RC time constants

#### **Distribution Width (σ):**
- **V02166B**: 9.5 μs (broader distribution, possibly more noise)
- **V07647B**: 4.3 μs (narrow distribution, good stability)
- **V01240A**: 3.8 μs (excellent stability and measurement quality)
- **Interpretation**: 
  - **Narrow σ**: Stable electronics, good waveform quality, sufficient statistics
  - **Wide σ**: Possible electronics instability, noise, or insufficient cuts

#### **Fit Quality Assessment:**
- **V02166B**: pvalue = 0.003 (marginal fit quality, some systematic deviations)
- **V07647B**: pvalue = 0.187 (good fit quality, acceptable residuals)
- **V01240A**: pvalue = 0.62 (excellent fit quality, no significant deviations)

#### **Quality Indicators:**
- **Excellent**: pvalue > 0.1, σ < 5 μs, small uncertainties, |residuals_norm| < 2
- **Good**: pvalue > 0.01, σ < 10 μs, reasonable uncertainties
- **Acceptable**: pvalue > 0.001, σ < 15 μs, larger but usable uncertainties
- **Poor**: pvalue < 0.001, σ > 15 μs, systematic deviations in residuals

#### **Pole-Zero Correction Impact:**
- **Accurate τ**: Proper exponential tail cancellation, improved baseline stability
- **Inaccurate τ**: Residual exponential tails, baseline shifts, pileup effects
- **Precision Requirements**: δτ/τ < 1% typically sufficient for good PZ correction


