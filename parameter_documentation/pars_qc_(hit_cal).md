# pars_qc_(hit_cal).md

Purpose: Describe the QC parameter outputs produced by `process_hit_cal.jl` and stored under `rpars/qc/`.

---

## Location

- Path per run: `.../legend_data_production/jl-v0.5.0/generated/jlpar/rpars/qc/p<period>/r<run>.yaml`
- Scope: One YAML file per run, with one top-level entry per detector (detector ID as key)
- Produced by: `legend-julia-dataflow/processors/process_hit_cal.jl`

---

## Field descriptions

### Level 1: Detectors (top-level keys)
- **String**: Detector IDs (e.g., `V02166B`, `V07647B`, `B00035B`)
- **Meaning**: Groups quality control results for that individual detector

### Level 2: QC metrics (detector sub-keys)
- **`sf`**: Final survival fraction after all physics selection cuts
- **`n_pulser`**: Number of pulser events identified after physics selection
- **`cuts`** (optional): Per-cut survival fractions for individual QC criteria

#### Physical Meaning and QC Process:
- **Quality Control Purpose**: **Remove non-physical events** and **poor-quality data** from detector waveforms
- **Event Categories**:
  - **Physical events**: Real detector interactions from γ-rays, particles
  - **Non-physical events**: Electronics noise, saturated pulses, pileup, artifacts
  - **Pulser events**: Calibration pulses for monitoring and testing
- **QC Pipeline**: Raw waveforms → DSP → QC cuts → Physics events (`is_physical` flag)

#### **QC Cut Categories (typical)**:
- **`ml`**: **Machine Learning** discrimination (if available)
- **`is_valid_t0`**: Valid trigger time (timing QC)
- **`is_valid_e`**: Valid energy estimation (energy QC)
- **`is_pileup`**: Pileup rejection (multiple events in waveform)
- **Saturation/Discharge**: ADC saturation and discharge rejection
- **Baseline windows**: Baseline stability checks
- **Trigger quality**: Trigger timing and stability

### Level 3: QC metric content

#### 3.1: `sf` (Survival Fraction)
- **Purpose**: Overall physics event retention rate after all QC cuts
- **Type**: Object with unit and value (percentage)
- **Physical meaning**: Fraction of raw events classified as physical

#### 3.2: `n_pulser` (Pulser Event Count)
- **Purpose**: Monitor pulser system functionality and rate
- **Type**: Integer count of identified pulser events
- **Quality check**: Consistent pulser rate indicates stable calibration system

#### 3.3: `cuts` (Per-Cut Analysis) - Optional
- **Purpose**: Detailed breakdown of individual cut performance
- **Type**: Dictionary with cut names as keys, percentages as values
- **Diagnostic use**: Identify which cuts dominate event rejection

### Level 4: Detailed field content

#### 4.1: Survival fraction structure (`sf`)
- **`unit`**: String - Always "percent"
- **`val`**: Float - Percentage of events passing all QC cuts
- **Typical Range**: 95-99% for good detectors, lower indicates problems
- **Quality Indicators**:
  - **Excellent**: > 99% (minimal rejection, clean data)
  - **Good**: 98-99% (normal operation)
  - **Marginal**: 95-98% (some issues, needs monitoring)
  - **Poor**: < 95% (significant problems, needs investigation)

#### 4.2: Pulser count analysis (`n_pulser`)
- **Type**: Integer - Raw count of pulser events after QC
- **Expected Range**: ~10,000 per run (depends on pulser rate and run length)
- **Consistency Check**: 
  - **Normal**: ~9,600-10,300 events (consistent with expectations)
  - **Low**: < 9,000 events (possible pulser issues or high rejection)
  - **High**: > 11,000 events (possible mis-classification or rate change)

#### 4.3: Individual cut structure (`cuts.<cut_name>`)
- **`unit`**: String - Always "percent"  
- **`val`**: Float - Survival fraction for this specific cut
- **Interpretation**: Higher values = less rejection by this cut
- **Diagnostic use**: Low values indicate dominant rejection sources

---

## Provenance

- Inputs: `jldsp` tier (DSP outputs), QC YAML config at `.../legend_data_production/jl-v0.5.0/legend-metadata_new_yaml_p14/jldataprod/config/qc/*.yaml`, and pulser tags from `jlpls` tier.
- Computation: Per-detector aggregation performed by `process_hit_cal.jl` after writing `jlhit` files. Results are written to `rpars/qc` and validity metadata is updated.

---

## Notes

- Categorical ML label (`qc_label` in DSP) is not stored here; only aggregate post-selection numbers are saved. Event-level QC booleans are written into `jlhit/<channel>/qc` within each hit file.
- The exact set of cut names and their logic are controlled by the QC config via string expressions evaluated with `ljl_propfunc`.

---

## Example Structure

```yaml
V02166B:
  # Excellent performing detector with minimal rejection
  sf: { unit: "percent", val: 99.3347139551647 }              # Excellent survival fraction
  n_pulser: 10109                                             # Normal pulser count

V07647B:
  # Another high-quality detector
  sf: { unit: "percent", val: 99.46099510104436 }             # Excellent survival fraction  
  n_pulser: 9974                                              # Normal pulser count

V01240A:
  # Good detector with slightly more rejection
  sf: { unit: "percent", val: 98.8694115287007 }              # Good survival fraction
  n_pulser: 9669                                              # Normal pulser count

B00035B:
  # BeGe detector with good performance
  sf: { unit: "percent", val: 99.0328793589215 }              # Good survival fraction
  n_pulser: 9599                                              # Normal pulser count

V06643A:
  # Detector with potential issues (lower pulser count)
  sf: { unit: "percent", val: 98.19094924083124 }             # Marginal survival fraction
  n_pulser: 4266                                              # Low pulser count (investigate!)

# Example with detailed cut analysis (optional structure)
V02166B_detailed:
  sf: { unit: "percent", val: 99.33 }
  n_pulser: 10109
  cuts:
    ml: { unit: "percent", val: 99.8 }                        # ML cut very selective
    is_valid_t0: { unit: "percent", val: 99.9 }               # Timing mostly good
    is_valid_e: { unit: "percent", val: 99.95 }               # Energy estimation excellent
    is_pileup: { unit: "percent", val: 99.7 }                 # Some pileup rejection
    saturation: { unit: "percent", val: 99.98 }               # Minimal saturation
    baseline_window: { unit: "percent", val: 99.85 }          # Good baseline stability
```

### QC Results Interpretation:

#### **Survival Fraction Analysis:**
- **Excellent performers** (>99%): V02166B (99.33%), V07647B (99.46%)
  - Minimal event rejection, high data quality
  - Electronics and detector in excellent condition
- **Good performers** (98-99%): V01240A (98.87%), B00035B (99.03%)
  - Normal operation with acceptable rejection rates
  - Standard performance for well-functioning detectors
- **Marginal performers** (95-98%): V06643A (98.19%)
  - Higher rejection rate, may need investigation
  - Still acceptable but requires monitoring

#### **Pulser Count Analysis:**
- **Normal operation**: 9,600-10,300 events
  - V02166B: 10,109 (excellent)
  - V07647B: 9,974 (excellent) 
  - V01240A: 9,669 (good)
  - B00035B: 9,599 (good)
- **Anomalous**: V06643A: 4,266 (low - investigate!)
  - Possible pulser system issues
  - Could indicate electronics problems
  - May affect calibration reliability

#### **Quality Assessment Patterns:**
- **Correlation**: Lower pulser counts often correlate with lower survival fractions
- **Detector Type**: ICPC and BeGe detectors show similar QC performance
- **Consistency**: Most detectors show ~98-99% survival, indicating good QC tuning

#### **Diagnostic Guidance:**
- **Excellent (>99% SF, normal pulser)**: No action needed, optimal performance
- **Good (98-99% SF, normal pulser)**: Monitor trends, standard operation
- **Marginal (95-98% SF)**: Investigate causes, check individual cuts if available
- **Poor (<95% SF or low pulser)**: Immediate investigation required
  - Check electronics connections
  - Review pulser system functionality
  - Examine individual QC cut performance
  - Consider detector-specific issues

#### **Monitoring Strategy:**
- **Run-to-run trends**: Watch for declining survival fractions
- **Detector comparisons**: Identify outliers compared to detector type average
- **Pulser stability**: Consistent pulser counts indicate stable calibration
- **Seasonal effects**: Monitor for temperature or environmental dependencies


