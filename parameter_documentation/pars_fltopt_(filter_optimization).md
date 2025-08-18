# fltopt (filter optimization) run parameters — schema and field descriptions

Purpose: Document the structure and semantics of the filter optimization (fltopt) run parameters saved under rpars. These parameters are produced by `process_filter_optimization` and used to configure DSP filters per detector and filter type.

---

## Location

- Path per run: `.../legend_data_production/jl-v0.5.0/generated/jlpar/rpars/fltopt/p<period>/r<run>.yaml`
- Scope: One YAML file per run, with one top-level entry per detector (detector ID as key, e.g., `P00664A`). Each detector contains entries for the optimized filter types (e.g., `trap`, `cusp`, `zac`).

---

## Field descriptions

### Level 1: Detectors (top-level keys)
- **String**: Detector IDs (e.g., `V02166B`, `V07647B`, `V01240A`, `B00035B`)
- **Meaning**: Groups filter optimization results for that detector

### Level 2: Filter types (detector sub-keys)
- **Filter Types**: `trap`, `cusp`, `zac` (DSP filter families)
- **Meaning**: Different digital signal processing filters optimized for this detector

#### DSP Filter Types (from L-Note Section V):
- **`trap`**: **Trapezoidal filter** - symmetric filter with linear rise/fall times and flat-top
- **`cusp`**: **CUSP filter** - finite-length cusp-like filter with flat-top center and sinh curves
- **`zac`**: **ZAC filter** - Zero-Area CUSP with parabola subtraction for zero-area constraint

#### Physical Meaning and Optimization Process (from L-Note Section V):

**Digital Signal Processing Context:**
- **Purpose**: Transform detector waveforms into optimal energy estimates
- **Method**: Apply digital filters to baseline-corrected, pole-zero corrected waveforms
- **Goal**: **Minimize noise** while **preserving signal amplitude** and **correcting ballistic deficit**

**Two-Step Sequential Optimization:**

#### **Step 1: Rise Time (RT) Optimization - ENC Minimization**
- **ENC Definition**: **Equivalent Noise Charge** - amount of charge (number of electrons) that, when injected into the CSA, produces a signal-to-noise ratio equal to one
- **ENC Measurement**: ADC value of baseline at fixed time point (40μs for trap, 41μs for CUSP/ZAC)
- **Physical Meaning**: Lower ENC = better noise performance = better energy resolution at low energies
- **Grid Search**: Rise time varied from **1μs to 16μs** in **0.5μs steps**
- **Method**: Apply filter with varying RT to up to 15,000 waveforms, measure baseline noise
- **Selection**: RT corresponding to **minimal ENC** is chosen

#### **Step 2: Flat-Top Time (FT) Optimization - FWHM Minimization**  
- **Input**: Fixed RT from Step 1, applied to **FEP waveforms** (Tl208 2614.51 keV)
- **FWHM Measurement**: Energy values from **fixed time pickoff** at center of filtered waveform
- **Grid Search**: Flat-top time varied from **1μs to 4μs** in **0.2μs steps**
- **Method**: Fit gamma peak shape to energy histogram, extract FWHM
- **Plateau Rule**: Optimal FT selected where **FWHM doesn't vary more than 0.1 keV** for next 3 grid points
- **Purpose**: Avoid numerical instabilities while ensuring optimal resolution

**Filter-Specific Characteristics:**
- **Trapezoidal Filter**: 
  - Symmetric rise/fall (RT), flat-top (FT), linear transitions
  - Generally prefers **longer RT** (better ballistic deficit correction)
  - More stable against pulse shape variations
- **CUSP Filter**: 
  - Cusp-like shape with flat-top center, sinh curve sides
  - Generally prefers **shorter RT** (faster processing, lower noise)
  - Better for high-rate applications
- **ZAC Filter**: 
  - Zero-Area CUSP with parabola subtraction
  - Zero-area constraint improves baseline stability
  - Similar characteristics to CUSP but more robust against baseline shifts

**Physical Trade-offs:**
- **Shorter RT**: Lower noise (ENC) but poorer ballistic deficit correction
- **Longer RT**: Better ballistic deficit correction but higher noise
- **Shorter FT**: Higher throughput, faster processing, acceptable resolution
- **Longer FT**: Better energy resolution, lower throughput, slower processing
- **Ballistic Deficit**: Incomplete charge collection due to finite filter timing vs. detector charge collection time

### Level 3: Optimization results (filter sub-keys)

#### 3.1: `rt` (Rise Time)
- **Purpose**: Optimal rise time from ENC vs RT optimization
- **Type**: Object with unit, value, and uncertainty

#### 3.2: `ft` (Flat-Top Time)
- **Purpose**: Optimal flat-top time from FWHM vs FT optimization  
- **Type**: Object with unit, value, and uncertainty

#### 3.3: `min_enc` (Minimum ENC)
- **Purpose**: Minimum Equivalent Noise Charge achieved at optimal RT
- **Type**: Object with value and uncertainty

#### 3.4: `min_fwhm` (Minimum FWHM)
- **Purpose**: Best energy resolution achieved at optimal FT
- **Type**: Object with unit, value, and uncertainty (often null)

### Level 4: Detailed field content

#### 4.1: Rise time structure (`rt`)
- **`unit`**: String - Always "μs" (microseconds)
- **`val`**: Float - Optimal rise time from ENC minimization
- **`err`**: Float - Uncertainty from ENC fit (curvature around minimum)
- **Typical Range**: 1-10 μs depending on detector and filter type

#### 4.2: Flat-top time structure (`ft`)
- **`unit`**: String - Always "μs" (microseconds)
- **`val`**: Float - Optimal flat-top time from FWHM minimization
- **`err`**: Float - Uncertainty from FWHM fit (may use plateau rule)
- **Typical Range**: 0.5-5 μs depending on detector characteristics

#### 4.3: Minimum ENC structure (`min_enc`)
- **`val`**: Float - Minimum **Equivalent Noise Charge** in ADC units
- **`err`**: Float - Uncertainty from ENC measurement/fit spread
- **Technical Definition**: 
  - **ENC = baseline noise level** when filter applied with optimal RT
  - **Units**: ADC counts (before keV calibration)
  - **Measurement**: Fixed time pickoff at baseline region (40μs trap, 41μs CUSP/ZAC)
- **Physical Interpretation**:
  - **Lower ENC**: Better noise performance, better resolution at low energies
  - **ENC ∝ 1/√(signal integration time)**: Longer RT generally reduces noise
  - **ENC limited by**: Electronics noise, detector leakage current, microphonics
- **Performance Categories**:
  - **Excellent**: < 30 ADC units (premium detectors)
  - **Good**: 30-40 ADC units (standard performance)
  - **Acceptable**: 40-50 ADC units (minimum requirements)

#### 4.4: Minimum FWHM structure (`min_fwhm`)
- **`unit`**: String - Always "keV" 
- **`val`**: Float - Best energy resolution at **Tl208 FEP (2614.51 keV)**
- **`err`**: Float|null - Often null (fit uncertainty not always estimated)
- **Technical Definition**:
  - **FWHM = Full Width at Half Maximum** of fitted gamma peak
  - **Measurement**: Fixed time pickoff at center of filtered FEP waveforms
  - **Reference Peak**: Tl208 FEP provides highest statistics and best S/N
- **Physical Interpretation**:
  - **Lower FWHM**: Better energy resolution, better peak separation
  - **FWHM contributions**: Electronics noise, charge statistics (Fano), charge trapping, ballistic deficit
  - **Filter dependence**: FT length affects resolution vs. throughput trade-off
- **Performance Categories**:
  - **Excellent**: < 3.0 keV at 2.6 MeV (< 0.11% relative resolution)
  - **Good**: 3.0-3.5 keV at 2.6 MeV (0.11-0.13% relative resolution)
  - **Acceptable**: 3.5-4.0 keV at 2.6 MeV (0.13-0.15% relative resolution)
- **Scaling**: FWHM ∝ √E for Fano-limited resolution, but electronics noise adds constant term

---

## Provenance and generation

- Producer: `process_filter_optimization` processor.
- Inputs: jlpeaks waveforms at configured peak; τ from `rpars/pz`; QC mask (optional ML); qdrift; grids `e_grid_rt`, `e_grid_ft` from DSP config.
- Steps: RT sweep (FT fixed) → fit ENC vs RT → FT sweep (RT fixed to optimum) → fit FWHM vs FT → persist best `rt`, `ft`, `min_enc`, `min_fwhm` per filter type.

---

## Usage guidance

- Use `rt.val` and `ft.val` to configure DSP filters for the detector and filter type.
- Check `min_fwhm.val` as an energy-resolution QA metric; compare across filters to select the preferred filter per detector.
- Large uncertainties or missing entries indicate poor statistics or failed fits; consider revisiting QC, grids, or fit windows.

---

## Example Structure

```yaml
V02166B:
  # CUSP filter optimization results
  cusp:
    rt: { unit: "μs", val: 1.5, err: 0.5 }                     # Short rise time
    ft: { unit: "μs", val: 2.8, err: 0.2 }                     # Moderate flat-top
    min_enc: { val: 38.375691750619104, err: 0.7044438980053799 }   # Noise level
    min_fwhm: { unit: "keV", val: 3.41376750058306, err: null }     # Best resolution

  # Trapezoidal filter optimization results  
  trap:
    rt: { unit: "μs", val: 4.0, err: 0.5 }                     # Longer rise time
    ft: { unit: "μs", val: 2.4, err: 0.2 }                     # Shorter flat-top
    min_enc: { val: 40.34803091987046, err: 0.9849554476176882 }    # Slightly higher noise
    min_fwhm: { unit: "keV", val: 3.4452771503526, err: null }      # Slightly worse resolution

V07647B:
  # Better performing detector with lower noise
  cusp:
    rt: { unit: "μs", val: 5.0, err: 0.5 }                     # Longer optimal RT
    ft: { unit: "μs", val: 2.0, err: 0.2 }                     # Shorter optimal FT
    min_enc: { val: 30.099748291529586, err: 0.5955682903907011 }   # Lower noise
    min_fwhm: { unit: "keV", val: 2.8828495485264463, err: null }   # Better resolution

  trap:
    rt: { unit: "μs", val: 7.5, err: 0.5 }                     # Much longer RT
    ft: { unit: "μs", val: 1.8, err: 0.2 }                     # Shorter FT
    min_enc: { val: 30.070169481897288, err: 0.6511099202385892 }   # Similar low noise
    min_fwhm: { unit: "keV", val: 2.886765101356411, err: null }    # Comparable resolution

V01240A:
  # Another detector showing filter performance differences
  cusp:
    rt: { unit: "μs", val: 3.5, err: 0.5 }                     # Intermediate RT
    ft: { unit: "μs", val: 3.4, err: 0.2 }                     # Longer FT needed
    min_enc: { val: 25.652424093954206, err: 0.502978863850186 }    # Excellent noise
    min_fwhm: { unit: "keV", val: 3.294598197533851, err: null }    # Good resolution

  trap:
    rt: { unit: "μs", val: 8.5, err: 0.5 }                     # Longest RT
    ft: { unit: "μs", val: 2.8, err: 0.2 }                     # Moderate FT
    min_enc: { val: 25.684012359620127, err: 0.5144657530543473 }   # Excellent noise
    min_fwhm: { unit: "keV", val: 3.1854357170755243, err: null }   # Best resolution

B00035B:
  # BeGe detector with different optimization characteristics
  cusp:
    rt: { unit: "μs", val: 2.5, err: 0.5 }                     # Shorter RT
    ft: { unit: "μs", val: 1.6, err: 0.2 }                     # Short FT
    min_enc: { val: 28.5, err: 0.6 }                           # Low noise
    min_fwhm: { unit: "keV", val: 2.875460507256945, err: null }    # Excellent resolution
```

### Filter Optimization Results Interpretation:

#### **Rise Time (RT) Optimization (ENC Minimization):**
- **CUSP filters**: Generally prefer **shorter RT** (1.5-5.0 μs)
  - **Advantage**: Faster signal processing, inherently lower noise
  - **Mechanism**: Cusp shape provides efficient signal integration with less baseline integration
  - **Trade-off**: Some ballistic deficit but compensated by superior noise performance
  - **Application**: Better for high-rate applications, low-noise front-end electronics

- **Trapezoidal filters**: Generally prefer **longer RT** (4.0-8.5 μs)
  - **Advantage**: Superior ballistic deficit correction through longer integration
  - **Mechanism**: Symmetric rise/fall ensures complete charge collection compensation
  - **Trade-off**: Higher noise due to longer baseline integration time
  - **Application**: Better for detectors with slower charge collection, varying pulse shapes

- **Physical Basis**: ENC ∝ 1/√(RT) for electronics noise, but ballistic deficit increases with shorter RT

#### **Flat-Top Time (FT) Optimization (FWHM Minimization):**
- **Shorter FT** (1.6-2.8 μs): 
  - **Advantage**: Higher throughput (faster processing), reduced pileup probability
  - **Resolution**: Acceptable for most applications (typically 0.1-0.2 keV penalty)
  - **Stability**: Less sensitive to timing variations and microphonics
  
- **Longer FT** (2.8-4.0 μs):
  - **Advantage**: Better energy resolution through improved signal averaging
  - **Mechanism**: Longer integration reduces statistical fluctuations
  - **Trade-off**: Lower throughput, increased pileup sensitivity
  - **Plateau Rule**: Often hits FWHM plateau where further FT increase gives minimal improvement

- **Detector Dependence**: 
  - **Fast detectors** (short charge collection): Can use shorter FT
  - **Slow detectors** (long charge collection): Require longer FT for complete collection
  - **High-noise detectors**: Benefit more from longer FT averaging

#### **Performance Metrics:**
- **ENC comparison**:
  - **Excellent**: < 30 ADC units (V01240A, V07647B)
  - **Good**: 30-40 ADC units (V02166B, B00035B)
  - **Acceptable**: 40-50 ADC units
- **FWHM comparison**:
  - **Excellent**: < 3.0 keV (V07647B, B00035B)
  - **Good**: 3.0-3.5 keV (V01240A, V02166B)
  - **Acceptable**: 3.5-4.0 keV

#### **Filter Selection Guidance:**
- **V07647B**: Both filters perform similarly - choose based on application
- **V01240A**: Trap filter gives better resolution (3.19 vs 3.29 keV)
- **V02166B**: CUSP filter slightly better (3.41 vs 3.45 keV)
- **BeGe detectors**: Often favor CUSP for shorter timing and excellent resolution

#### **Quality Indicators:**
- **Reasonable uncertainties**: err ~ 0.2-0.5 μs indicates good fits
- **Consistent ENC errors**: ~0.5-1.0 ADC units typical
- **Missing FWHM errors**: Common when fit uncertainty not estimated
