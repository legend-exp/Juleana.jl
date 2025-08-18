# sipmopt (SiPM optimization on physics data) — run parameters: schema and field descriptions

Purpose: Document the structure of SiPM optimization parameters saved by `process_sipm_optimization_phy`. Used to configure downstream SiPM selections and monitoring (WL, gain, resolution, thresholds).

---

## Location

- Path per run: `.../legend_data_production/jl-v0.5.0/generated/jlpar/rpars/sipmopt/p<period>/r<run>.yaml`
- Scope: One YAML per run; top-level keys are detector IDs.

---

## Field descriptions

### Level 1: SiPM Detectors (top-level keys)
- **String**: SiPM detector IDs (e.g., `S012`, `S098`, `S050`, `S070`)
- **Meaning**: Groups SiPM optimization results for that individual SiPM detector

### Level 2: Filter types (detector sub-keys)
- **Filter Types**: `sg`, `cusp`, `trap` (digital signal processing filters)
- **Meaning**: Different DSP filter variants optimized for this SiPM detector

#### SiPM Physical Context and Purpose:
- **SiPM Role**: **Silicon Photomultipliers** used in **Liquid Scintillator Veto (LSV)** system
- **LSV Purpose**: **Anti-Compton shield** around germanium detectors to reject external γ-rays and muons
- **SiPM Function**: Convert **scintillation photons** to **electrical signals** for event detection
- **Signal Characteristics**: 
  - **Single Photo-Electron (1 pe)**: Basic unit of light detection
  - **Avalanche multiplication**: Each photon creates avalanche with gain ~10⁶
  - **Discrete nature**: Signal amplitude proportional to number of detected photons

#### **SiPM Optimization Process:**
- **Window Length (WL) Optimization**: Find optimal integration window for signal extraction
- **Gain Calibration**: Measure amplification factor per photo-electron
- **Resolution Measurement**: Determine single photo-electron resolution
- **Threshold Setting**: Configure trigger thresholds for different observables
- **Physics Data**: Use real detector data (not pulser) for optimization

### Level 3: SiPM optimization results (filter sub-keys)

#### 3.1: `wl` (Window Length)
- **Purpose**: Optimal integration window for signal extraction
- **Type**: Object with unit, value, and uncertainty

#### 3.2: `gain` (SiPM Gain)
- **Purpose**: Amplification factor per photo-electron
- **Type**: Object with value and uncertainty

#### 3.3: `pos_1pe` (1 PE Position) 
- **Purpose**: Signal amplitude corresponding to single photo-electron
- **Type**: Object with value and uncertainty

#### 3.4: `res_1pe` (1 PE Resolution)
- **Purpose**: Energy resolution for single photo-electron signals
- **Type**: Object with value, uncertainty, and unit

#### 3.5: `threshold` (Threshold Value)
- **Purpose**: Optimized threshold value for signal discrimination
- **Type**: Float value

#### 3.6: `obj` (Objective Function)
- **Purpose**: Optimization objective function value
- **Type**: Object with value and uncertainty

#### 3.7: `trig_threshold` (Trigger Thresholds)
- **Purpose**: Threshold values for different trigger observables
- **Type**: Object with multiple observable types

### Level 4: Detailed field content

#### 4.1: Window length structure (`wl`)
- **`unit`**: String - Always "ns" (nanoseconds)
- **`val`**: Float - Optimal integration window length
- **`err`**: Float - Uncertainty from optimization (typically step size)
- **Typical Range**: 100-300 ns depending on SiPM and electronics

#### 4.2: SiPM performance parameters
- **`gain`**: `{val, err}` - SiPM amplification factor (ADC units per photo-electron)
- **`pos_1pe`**: `{val, err}` - Single PE signal amplitude in ADC units
- **`res_1pe`**: `{val, err}` - Single PE resolution (width/position ratio)
- **`threshold`**: Float - Optimized discrimination threshold

#### 4.3: Trigger threshold structure (`trig_threshold`)
- **`bsl`**: Baseline statistics (μ, σ)
  - **μ**: Mean baseline level
  - **σ**: Baseline noise level (used for threshold setting)
- **`bsl_flipped`**: Inverted baseline statistics
- **`bsl_deriv`**: Baseline derivative statistics
  - **μ**: Mean derivative level
  - **σ**: Derivative noise level (for timing triggers)
- **`μ_simple`**, **`σ_simple`**: Simple statistical estimators

#### 4.4: SiPM-specific considerations
- **Positive vs. Negative Signals**: Some SiPMs may have inverted polarity
- **Empty Entries**: `{}` indicates SiPM not operational or insufficient data
- **Gain Variations**: Different SiPMs have different gains due to manufacturing variations
- **Resolution Dependence**: Resolution depends on overvoltage, temperature, aging

---

## Provenance and generation

- Producer: `process_sipm_optimization_phy`.
- Inputs: raw `phy` waveforms, pulser tags (from the same processor), SiPM DSP and optimization configs.
- Steps: pulser coincidence removal → DSP WL sweeps → WL fit → thresholds at WL → write `rpars/sipmopt` and plots.

---

## Usage guidance

- Use `wl` and `trig_threshold` to configure acquisition or analysis-level SiPM discriminators.
- Monitor `gain` and `res_1pe` per run to detect drifts; compare across periods.

---

## Example Structure

```yaml
S012:
  # Working SiPM with normal polarity (positive signals)
  sg:
    wl: { unit: "ns", val: 196.0, err: 24.0 }                  # Optimal window length
    
    # Single photo-electron characteristics
    pos_1pe: { val: 0.9297895213193159, err: 0.07310378230773147 }     # 1 PE amplitude
    gain: { val: 0.07152640876403182, err: 0.0 }                        # SiPM gain factor
    res_1pe: { val: 0.19377578471117318, err: 0.0 }                     # 1 PE resolution
    
    # Optimization results
    threshold: 0.717570229548637                                # Discrimination threshold
    obj: { val: 5.21333386225438, err: 0.0 }                    # Objective function value
    
    # Trigger threshold settings for different observables
    trig_threshold:
      bsl:                                                      # Baseline statistics
        μ: -0.002025040640085739                               # Mean baseline
        σ: 0.8259314009799658                                  # Baseline noise
        μ_simple: -0.002025040640085739
        σ_simple: 0.8259314009799658
      
      bsl_flipped:                                              # Inverted baseline
        μ: 0.002025040640085739
        σ: 0.8259314009799658
        μ_simple: 0.002025040640085739
        σ_simple: 0.8259314009799658
      
      bsl_deriv:                                                # Baseline derivative
        μ: 3.467431926877788e-7                                # Mean derivative
        σ: 0.24225109728665822                                 # Derivative noise
        μ_simple: 3.467431926877788e-7
        σ_simple: 0.24225109728665822

S098:
  # Working SiPM with inverted polarity (negative signals)
  sg:
    wl: { unit: "ns", val: 172.0, err: 24.0 }                  # Different optimal window
    
    # Single photo-electron characteristics
    pos_1pe: { val: 3.775034015780589, err: 0.20202809130422328 }       # Higher 1 PE amplitude
    gain: { val: -1.8749495104179066, err: 0.0 }                        # Negative gain (inverted)
    res_1pe: { val: 0.2674452297879264, err: 0.0 }                      # Worse resolution
    
    # Optimization results
    threshold: 1.0626990627719062                               # Higher threshold needed
    obj: { val: -0.28433675291013844, err: 0.0 }               # Negative objective value
    
    # Trigger thresholds adapted for inverted signals
    trig_threshold:
      bsl:
        μ: 0.02102851847463754                                 # Positive baseline offset
        σ: 0.9522358872269202                                  # Higher noise level
        μ_simple: 0.02102851847463754
        σ_simple: 0.9522358872269202
      
      bsl_flipped:
        μ: -0.02102851847463754                                # Flipped baseline
        σ: 0.9522358872269202
        μ_simple: -0.02102851847463754
        σ_simple: 0.9522358872269202
      
      bsl_deriv:
        μ: 1.0959721166634881e-5                               # Small derivative offset
        σ: 0.36400424281174887                                 # Higher derivative noise
        μ_simple: 1.0959721166634881e-5
        σ_simple: 0.36400424281174887

S050: {}                                                        # Non-operational SiPM

S070: {}                                                        # Non-operational SiPM

S052:
  # Another working SiPM with excellent performance
  sg:
    wl: { unit: "ns", val: 148.0, err: 24.0 }                  # Shorter optimal window
    pos_1pe: { val: 0.8528459927610879, err: 0.02496768825096267 }      # Low uncertainty
    gain: { val: 0.06234512345678901, err: 0.0 }                        # Good gain stability
    res_1pe: { val: 0.1587654321098765, err: 0.0 }                      # Excellent resolution
    threshold: 0.5234567890123456
    obj: { val: 8.765432109876543, err: 0.0 }
    # ... similar trig_threshold structure
```

### SiPM Optimization Results Interpretation:

#### **Window Length Optimization:**
- **S012**: 196 ns (longer integration for better S/N)
- **S098**: 172 ns (moderate integration window)
- **S052**: 148 ns (shorter window, faster response)
- **Typical Range**: 100-300 ns depending on SiPM characteristics and noise

#### **SiPM Performance Analysis:**
- **Gain Polarity**:
  - **S012**: +0.0715 (positive polarity, normal)
  - **S098**: -1.875 (negative polarity, inverted electronics)
  - **S052**: +0.0623 (positive polarity, consistent)
- **1 PE Resolution**:
  - **S012**: 19.4% (good performance)
  - **S098**: 26.7% (worse resolution, possibly due to noise)
  - **S052**: 15.9% (excellent resolution)

#### **Signal Quality Indicators:**
- **Baseline Noise Levels**:
  - **S012**: σ = 0.826 (moderate noise)
  - **S098**: σ = 0.952 (higher noise, may need attention)
  - **Lower noise = better threshold setting precision**
- **Derivative Noise**:
  - Used for timing triggers
  - **S012**: σ = 0.242 (good timing precision)
  - **S098**: σ = 0.364 (worse timing precision)

#### **Operational Status:**
- **Working SiPMs**: S012, S098, S052 (have complete optimization data)
- **Non-operational**: S050, S070 (empty entries, may be dead or disconnected)
- **Performance Ranking**: S052 (excellent) > S012 (good) > S098 (marginal)

#### **Quality Assessment Criteria:**
- **Excellent**: res_1pe < 20%, low baseline noise, stable gain
- **Good**: res_1pe < 25%, moderate noise, consistent operation  
- **Marginal**: res_1pe < 30%, higher noise, may need monitoring
- **Poor/Dead**: Empty entries or extremely poor resolution

#### **Monitoring and Maintenance:**
- **Gain Drift**: Monitor gain stability across runs (temperature, aging effects)
- **Resolution Degradation**: Watch for increasing res_1pe (indicates SiPM degradation)
- **Threshold Adjustment**: Update trigger thresholds based on noise levels
- **Dead Channel Detection**: Empty entries indicate need for hardware investigation
