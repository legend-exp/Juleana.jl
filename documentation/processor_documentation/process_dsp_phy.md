# process_dsp_phy.jl

**Purpose:** Applies Digital Signal Processing to raw physics data for all detector types (HPGe, SiPM, PMT) to compute physical parameters using previously optimized filter settings. This processor transforms multi-detector raw physics waveforms into calibrated DSP parameters, creating the `jldsp` data tier for physics analysis. Unlike calibration DSP, this handles heterogeneous detector systems with type-specific processing paths and real-time physics event classification.

---

## Path Variables

```
$RAW_DATA_PATH = .../legend_data_production/raw_compressed
$METADATA_PATH = .../legend_data_production/jl-v0.5.0/legend-metadata_new_yaml_p14
$GENERATED_DATA_PATH = .../legend_data_production/jl-v0.5.0/generated
$JLPLS_PATH = .../legend_data_production/jl-v0.5.0/generated/jlpls
$JLML_PATH = .../legend_data_production/jl-v0.5.0/generated/jlml
```

---

## Inputs

**Raw Physics Data:**
- **Path:** `$RAW_DATA_PATH/phy/<period>/<run>/`
- **Data Keys:** Multi-detector raw physics data across different systems
  - **HPGe detectors:** `waveform_presummed`, `waveform_windowed`, `baseline`, `timestamp`, `eventnumber`, `daqenergy`, `presum_rate`, `t_sat_lo`, `t_sat_hi`, `deadtime`
  - **SiPM detectors:** `waveform_bit_drop`, `baseline`, `timestamp`, `eventnumber`, `daqenergy`
  - **PMT detectors:** `waveform`, `timestamp`, `channel`, `eventnumber`, `daqenergy`

**DSP Config:**
- **Path:** `$METADATA_PATH/jldataprod/config/dsp/`
- **Parameters:** Core DSP configuration for HPGe detectors and additional channels
  - `default`: Default DSP settings for all HPGe detectors
  - `additional_channel`: Special processing functions for auxiliary channels
  - Per-detector overrides with detector-specific DSP parameters

**Multi-System Config:**
- **SiPM Config:** `$METADATA_PATH/jldataprod/config/sipm/dsp/`
- **PMT Config:** `$METADATA_PATH/jldataprod/config/pmt/dsp/`
- **Parameters:** System-specific DSP settings with `default` and per-detector customization

**Parameters:**
- **Decay Times:** `$GENERATED_DATA_PATH/jlpar/rpars/pz/<period>/<run>.yaml` OR `$GENERATED_DATA_PATH/jlpar/ppars/pz/<period>/<run>.yaml` (from process_decay_time)
- **Filter Optimization:** `$GENERATED_DATA_PATH/jlpar/rpars/fltopt/<period>/<run>.yaml` OR `$GENERATED_DATA_PATH/jlpar/ppars/fltopt/<period>/<run>.yaml` (from process_filter_optimization)
- **A/E Optimization:** `$GENERATED_DATA_PATH/jlpar/rpars/aoeopt/<period>/<run>.yaml` OR `$GENERATED_DATA_PATH/jlpar/ppars/aoeopt/<period>/<run>.yaml` (from process_aoe_optimization)
- **SiPM Optimization:** `$GENERATED_DATA_PATH/jlpar/rpars/sipmopt/<period>/<run>.yaml` OR `$GENERATED_DATA_PATH/jlpar/ppars/sipmopt/<period>/<run>.yaml` (from process_sipm_optimization_phy)

**ML Model:**
- **Path:** `$JLML_PATH/phy/<period>/<run>/` (optional for HPGe QC)
- **Content:** Trained Support Vector Machine model for waveform quality classification
- **Fallback:** Processing continues without ML QC if model unavailable

---

## Functions

### 1. dsp_icpc_compressed()
**Location:** `LegendDSP.jl/src/dsp_icpc.jl:297`

**Parameters:**
```julia
dsp_icpc_compressed(
    data::Table,
    config::DSPConfig,
    τ::Quantity,
    pars_filter::PropDict;
    f_evaluate_qc::Union{Function, Missing}=missing
)
```

**Returns:**
- `dsp_results::Table`: Complete per-event DSP table with all physical parameters computed using individually optimized filter settings. Contains 40+ fields per event including baseline parameters, energy estimators, timing parameters, A/E amplitudes, quality control flags, pile-up detection, and metadata. Same field structure as calibration DSP but with physics-optimized parameter values.

**Purpose:** Main production DSP function for HPGe detectors in physics runs. Transforms raw presummed and windowed waveforms into comprehensive physical parameter sets using detector-specific optimized filter parameters from previous optimization steps. **Critical for 0νββ physics analysis** as it applies the best-performing filter settings determined during calibration to actual physics data.

**Detailed Workflow per Event:**

**Step 1: Waveform Preparation and PZ Correction**
- Decode both presummed (coarse sampling, ~4 MHz) and windowed (fine sampling around pulse, ~100 MHz) waveforms from physics data
- Estimate baseline statistics using `config.bl_window` on presummed domain: mean, sigma, slope, offset with robust outlier handling
- Cross-domain baseline transfer: account for `presum_rate` when transferring baseline between presummed/windowed domains to maintain amplitude consistency
- Apply pole-zero deconvolution using detector-specific decay time `τ` from `pars_tau[det].τ` to remove exponential tail from charge-sensitive amplifier
- Compute tail statistics on PZ-corrected waveform using `config.tail_window`: mean, sigma, slope, offset for quality monitoring

**Step 2: Physics-Specific QC and ML Classification**
- **Optional ML QC:** If `f_evaluate_qc` provided, apply trained SVM model to classify waveform quality into categories 0-13 (Normal, Pileup, Saturation, etc.)
- **Physics Context:** ML model trained on calibration data applied to physics waveforms; may encounter different background rates and event topologies
- **Fallback Behavior:** If ML model unavailable, processing continues without ML-based event rejection; all waveforms processed
- **Saturation Detection:** Compute saturation statistics using FADC bit depth and presum rate; flag consecutive saturation samples

**Step 3: Optimized Timing and Drift Parameter Extraction**
- **Threshold Timing:** Find `t0` using first rising-edge crossing above baseline + `config.t0_threshold × baseline_sigma` with sub-sample interpolation
- **Fractional Rise Times:** Compute `t10`, `t50`, `t80`, `t90`, `t99` as interpolated threshold crossings between baseline and signal maximum
- **Charge Collection:** Define `drift_time = t90 - t0` as measure of charge collection time in detector
- **Advanced Parameters:** Compute `qdrift` by integrating PZ-corrected waveform around `t0`; compute `lq` (liquid scintillator parameter) around `t80`
- **Current Timing:** Extract `t50_current` from derivative domain for cross-validation of charge-domain timing

**Step 4: Multi-Filter Energy Reconstruction with Optimization**
- **Robust Energies (Fixed Parameters):** Apply canonical filters with fixed shaping for cross-detector stability
  - `e_10410`: 10µs RT, 4µs FT trapezoidal (reference energy)
  - `e_535`: 5µs RT, 3µs FT trapezoidal (fast shaping)
  - `e_313`: 3µs RT, 1µs FT trapezoidal (very fast, pile-up resistant)
- **Optimized Energies (Detector-Specific):** Apply individually optimized filters using `pars_filter` parameters
  - `e_trap`: Trapezoidal filter with optimized RT/FT from `pars_filter.trap.rt/ft` (main energy estimator)
  - `e_cusp`: CUSP filter with optimized RT/FT from `pars_filter.cusp.rt/ft` (low-noise alternative)
  - `e_zac`: Zero-Area CUSP with optimized RT/FT from `pars_filter.zac.rt/ft` (pile-up rejection)
- **Signal Estimation:** Use `SignalEstimator` with detector-optimized pick-off strategy; select stable flat-top region and average for robust energy extraction
- **Maximum Tracking:** Store `e_*_max` and `t_*_max` for each filter for timing-independent energy cross-checks

**Step 5: A/E Pulse Shape Discrimination with Optimization**
- **Current Signal Generation:** Differentiate windowed waveform to obtain current pulse (derivative of charge signal)
- **Multi-Amplitude Estimation:** Compute current amplitudes using different filtering approaches
  - `a_raw`: Peak of unfiltered numerical derivative (minimal processing, maximum fidelity)
  - `a_sg`: Peak after optimized Savitzky-Golay filter using `pars_filter.sg.wl` (detector-specific window length from A/E optimization)
  - `a_60`, `a_100`: Fixed 60ns, 100ns SG filters for systematic studies and stability monitoring
- **Optimization Context:** `a_sg` uses window length optimized per detector on DEP/SEP data to maximize background rejection while maintaining signal efficiency
- **Maximum Finding:** Apply quadratic interpolation around peak sample for sub-sample amplitude precision
- **A/E Formation:** Ratios computed downstream as `a_* / e_*` for pulse shape discrimination between single-site (0νββ-like) and multi-site (background-like) events

**Step 6: Advanced Pile-Up Detection and Current Analysis**
- **In-Trace Pile-Up:** Search presummed domain for multiple significant peaks in derivative before main rise using scaled SG filter
- **Pile-Up Characterization:** Record `inTrace_n` (number of pile-up candidates) and `inTrace_intersect` (approximate positions from curvature analysis)
- **Current Domain Analysis:** Cross-validate timing measurements between charge and current domains for consistency checks
- **Physics Relevance:** Critical for physics data where pile-up rates may be higher than calibration due to continuous operation

**Step 7: Inverted Analysis for DC Behavior Tagging**
- **Waveform Inversion:** Multiply waveforms by -1 and recompute robust energy estimators (`e_10410_inv`, `e_313_inv`) and timing (`t0_inv`)
- **DC Detection:** Flag waveforms with anomalous inverted behavior indicating discharge or baseline instability
- **Quality Assessment:** Compare normal vs inverted parameters to identify and tag problematic events

**Physics-Specific Considerations:**
- **Continuous Operation:** Physics data collected during continuous detector operation with potentially different baseline stability compared to calibration
- **Background Rates:** Higher background event rates may increase pile-up probability and require more stringent quality cuts
- **Event Topology:** Physics events may include rare topologies (0νββ candidates) not present in calibration data
- **Long-Term Stability:** Filter parameters optimized on calibration data applied over extended physics data collection periods

### 2. dsp_sipm_compressed()
**Location:** `LegendDSP.jl/src/dsp_sipm.jl:125`

**Parameters:**
```julia
dsp_sipm_compressed(
    data::Table,
    config::PropDict,
    pars_optimization::PropDict
)
```

**Returns:**
- `dsp_results::Table`: SiPM-specific DSP parameter table with photo-electron detection results, trigger information, and discharge flagging. Contains fields: `blfc`, `timestamp`, `eventID_fadc`, `e_fc`, `trig_pos`, `trig_max`, `trig_pos_DC`, `trig_max_DC` optimized for liquid argon scintillation light detection and HPGe coincidence analysis.

**Purpose:** Digital signal processing for Silicon Photo-Multiplier (SiPM) detectors in the liquid argon scintillation light detection system. **Physics Context:** SiPMs detect scintillation photons from energy depositions in the liquid argon, providing complementary information to HPGe energy measurements for background discrimination and event topology reconstruction. Essential for identifying single-site vs multi-site events in 0νββ searches.

**Detailed Workflow per Event:**

**Step 1: Waveform Decoding and Preparation**
- **Data Extraction:** Decode `waveform_bit_drop` data from compressed SiPM readout format to floating-point waveforms
- **Type Conversion:** Apply `shift_waveform(wvfs, 0.0)` for explicit Float64 conversion ensuring numerical precision in subsequent processing
- **Baseline Extraction:** Extract FADC baseline (`blfc`), timestamp (`ts`), event number (`evID`), and DAQ energy (`efc`) for event correlation

**Step 2: Extrema Detection and HPGe Synchronization**
- **Full Waveform Analysis:** Compute extrema statistics (`extremestats`) on complete SiPM waveforms for overall pulse characterization
- **HPGe Window Truncation:** Apply `TruncateFilter(first(t0_hpge_window)..last(t0_hpge_window))` to extract SiPM signals coincident with HPGe trigger timing
- **Coincidence Preparation:** Truncated extrema statistics (`estats_trunc`) provide SiPM response specifically during HPGe energy deposition window for correlation analysis

**Step 3: Optimized Photo-Electron Signal Processing**
- **Savitzky-Golay Filtering:** Apply `SavitzkyGolayFilter(sg_window_length, sg_flt_degree, 1)` using optimized window length from `pars_optimization.sg.wl`
- **Optimization Context:** Window length determined by `process_sipm_optimization_phy` to maximize photo-electron detection efficiency while minimizing noise
- **Derivative Computation:** SG filter computes first derivative (order=1) providing current-like signal proportional to photon arrival rate
- **Noise Reduction:** Polynomial smoothing (degree=`sg_flt_degree`) reduces high-frequency noise while preserving photo-electron pulse shape

**Step 4: Photo-Electron Trigger Detection**
- **Threshold Statistics:** Compute `thresholdstats` on filtered waveforms within amplitude range `[min_threshold, max_threshold]` for adaptive threshold setting
- **Intersection Maximum Detection:** Apply `IntersectMaximum(min_tot_intersect, max_tot_intersect)` filter to find photo-electron candidates above noise floor
- **Adaptive Thresholding:** Use `n_σ_threshold × threshold_stats` for dynamic threshold adaptation based on local noise characteristics
- **Multi-PE Detection:** Identify multiple photo-electron events within single waveform for high light-yield interactions

**Step 5: Discharge Event Identification**
- **Signal Integration:** Apply `IntegratorFilter(gain=1)` to derivative signal, converting current back to charge-like signal
- **DC Threshold Analysis:** Compute threshold statistics for discharge detection using separate `[min_dc_threshold, max_dc_threshold]` range
- **Discharge Flagging:** Apply `n_σ_dc_threshold` criteria to identify and flag SiPM discharge events that could interfere with photo-electron detection
- **Quality Control:** Separate discharge triggers (`trig_pos_DC`, `trig_max_DC`) from physics triggers for downstream analysis

**Step 6: Trigger Output Generation**
- **Physics Triggers:** Extract `trig_pos` (timing) and `trig_max` (amplitude) for genuine photo-electron events passing all quality criteria
- **Discharge Triggers:** Separately record discharge event positions and amplitudes for monitoring and rejection
- **Coincidence Data:** Format trigger information for correlation with HPGe detector events in downstream analysis
- **Timing Precision:** Maintain sub-sample timing precision for accurate HPGe-SiPM coincidence analysis

**SiPM Physics Significance:**
- **Scintillation Light Detection:** SiPMs detect UV scintillation photons (λ~128nm) from ionization events in liquid argon
- **Event Topology:** Light patterns distinguish single-site (point-like, 0νββ-like) from multi-site (extended, background-like) energy depositions
- **Background Discrimination:** Combined HPGe energy + SiPM light information improves background rejection for 0νββ searches
- **Detector Monitoring:** SiPM triggers provide independent validation of HPGe energy measurements and detector performance

### 3. dsp_pmts()
**Location:** `LegendDSP.jl/src/dsp_pmts.jl:3`

**Parameters:**
```julia
dsp_pmts(
    data::Table,
    config::PropDict
)
```

**Returns:**
- `dsp_results::Table`: PMT-specific DSP parameter table for liquid scintillator veto system. Contains fields: `timestamp`, `eventID_fadc`, `e_fc`, `channel`, baseline statistics, raw and smoothed pulse parameters, multiple trigger positions and amplitudes, and saturation flags for large-area muon veto decision logic.

**Purpose:** Digital signal processing for Photo-Multiplier Tube (PMT) detectors in the liquid scintillator veto system surrounding the germanium detector array. **Physics Context:** PMTs detect scintillation light from muon interactions in the liquid scintillator, providing active veto capability to reject muon-induced backgrounds in 0νββ searches. Essential for identifying and vetoing cosmic muon events that could mimic or induce 0νββ signatures.

**Detailed Workflow per Event:**

**Step 1: Time Axis Calibration and Baseline Processing**
- **Time Axis Correction:** Apply `TimeAxisFilter(time_axis_step_length)` to correct PMT digitizer time axis using configured step length for accurate timing calibration
- **Baseline Statistics:** Compute `signalstats` in pre-trigger window `[baseline_window_start, baseline_window_end]` extracting mean, sigma, slope, offset
- **Baseline Subtraction:** Apply `shift_waveform(wvfs, -baseline_mean)` to remove DC offset and prepare waveforms for pulse detection
- **PMT Calibration:** Baseline correction accounts for PMT dark current and electronics offsets specific to each PMT channel

**Step 2: Raw Pulse Characterization**
- **Extrema Detection:** Compute `extremestats` on baseline-subtracted waveforms to find raw pulse maximum, minimum, and timing information
- **Multi-Channel Processing:** Process all PMT channels simultaneously with channel-specific baseline and gain corrections
- **Pulse Validation:** Identify genuine scintillation pulses vs noise fluctuations using amplitude and timing criteria

**Step 3: Multi-Pulse Detection and Timing**
- **Intersection Maximum Algorithm:** Apply `IntersectMaximum(min_tot_intersect, max_tot_intersect)` to detect multiple pulses within single waveform
- **Threshold-Based Detection:** Use `intersect_threshold` to identify pulse candidates above noise floor with sub-sample timing precision
- **Muon Signature Recognition:** Multiple pulses may indicate extended muon tracks producing distributed scintillation light along particle trajectory
- **Timing Array Generation:** Extract array of pulse positions for coincidence analysis with germanium detector events

**Step 4: Saturation Handling and Dynamic Range**
- **Saturation Detection:** Apply `saturation` function with `[saturation_limit_low, saturation_limit_high]` to identify saturated pulses
- **Dynamic Range Management:** Flag saturated events for special handling in veto logic; saturated pulses indicate high-energy muon interactions
- **Pulse Reconstruction:** Attempt pulse parameter extraction even for partially saturated waveforms using leading/trailing edge information

**Step 5: Weighted Signal Conditioning**
- **Adaptive Filtering:** Apply `WeightedSavitzkyGolayFilter` or standard `SavitzkyGolayFilter` based on `wsg_weight` parameter
- **Noise Reduction:** Use `wsg_window_length` and `wsg_flt_degree` for polynomial smoothing optimized for PMT pulse shapes
- **Smoothed Parameters:** Extract `extremestats` from filtered waveforms providing noise-reduced pulse characteristics for veto decision
- **Signal-to-Noise Optimization:** Weighted filtering adapts to local signal conditions for optimal pulse parameter extraction

**Step 6: Veto Decision Preparation**
- **Multi-Channel Correlation:** Combine information from multiple PMT channels to reconstruct muon trajectory and energy deposition
- **Timing Coincidence:** Prepare timing information for correlation with germanium detector events within veto time window
- **Amplitude Thresholding:** Apply energy-dependent veto criteria based on total scintillation light yield across PMT array
- **Topology Reconstruction:** Use spatial distribution of PMT signals to distinguish muon tracks from other backgrounds

**PMT Veto Physics:**
- **Liquid Scintillator Response:** PMTs detect blue scintillation light (λ~420nm) from organic liquid scintillator surrounding detector array
- **Muon Detection Efficiency:** High-efficiency detection of cosmic muons traversing liquid scintillator volume with >99.9% efficiency
- **Background Rejection:** Active veto reduces muon-induced backgrounds by factor of ~1000 for 0νββ searches
- **Spatial Coverage:** Large PMT array provides 4π steradian coverage around germanium detectors for complete muon rejection
- **Energy Threshold:** Configurable energy thresholds allow optimization of veto efficiency vs accidental veto rate

### 4. get_qc_ml_func()
**Location:** `LegendDSP.jl/src/ml.jl:5`

**Parameters:**
```julia
get_qc_ml_func(
    dwts_norm::Matrix{<:Real},
    dc_labels::Vector{<:Real},
    hyperparams::PropDict
)
```

**Returns:**
- `f_evaluate_qc`: Function for ML-based waveform quality control returning per-event classification labels (0-13). Same SVM classifier as calibration but applied to physics waveforms with potentially different statistical properties and background conditions.

**Purpose:** Load and configure trained Support Vector Machine (SVM) model for automated waveform quality assessment in physics data. **Critical for Physics Data Quality:** ML classifier trained on labeled calibration waveforms applied to continuous physics data stream to automatically identify and flag problematic waveforms that could compromise 0νββ analysis sensitivity.

**Detailed Functionality:**

**Training Data Integration:**
- **Feature Matrix:** `dwts_norm` contains normalized discrete wavelet transform coefficients extracted from calibration waveforms as ML features
- **Label Vector:** `dc_labels` provides expert-classified waveform categories (0=Normal through 13=Noise Trigger) from manual calibration data curation
- **Hyperparameter Loading:** `hyperparams` contains SVM training parameters (C, γ, kernel type) optimized during model development

**Model Architecture and Training:**
- **Support Vector Machine:** Multi-class SVM with RBF kernel trained on wavelet features to distinguish waveform quality categories
- **Feature Engineering:** Discrete wavelet transform provides time-frequency decomposition capturing both temporal and spectral waveform characteristics
- **Normalization:** Feature normalization ensures consistent SVM decision boundaries across different detector gains and noise levels

**Quality Classification Categories (0-13):**
- **0: Normal** - Well-formed physics waveforms suitable for analysis
- **1: Negative Going** - Inverted polarity indicating electronics issues
- **2: Upwards Sloping** - Baseline drift during waveform acquisition
- **3: Downwards Sloping** - Baseline decay indicating discharge or instability
- **4: Spike** - High-frequency noise spikes from electronics interference
- **5: Crosstalk** - Inter-channel coupling artifacts
- **6: Slow Rise** - Abnormally slow pulse rise times indicating collection issues
- **7: Early Trigger** - Trigger timing issues with pulse truncation
- **8: Late Trigger** - Late trigger causing pulse tail truncation
- **9: Saturation** - FADC saturation with clipped pulse amplitude
- **10: Soft Pileup** - Overlapping pulses with partial resolution
- **11: Hard Pileup** - Severely overlapping pulses with complete overlap
- **12: Bump** - Anomalous pulse shape features from detector issues
- **13: Noise Trigger** - False triggers on noise fluctuations

**Physics vs Calibration Domain Adaptation:**
- **Statistical Differences:** Physics data may have different waveform quality distributions compared to calibration data due to continuous operation
- **Background Variations:** Higher background rates in physics data may increase pile-up frequency requiring adapted classification thresholds
- **Long-Term Stability:** Model performance monitoring needed to detect drift in waveform characteristics over extended physics runs
- **Calibration Transfer:** SVM trained on calibration data applied to physics data with assumption of stable waveform quality characteristics

**Implementation in Physics Processing:**
- **Real-Time Classification:** Each physics waveform classified in real-time during DSP processing without manual intervention
- **Quality Flagging:** Classification results stored as `qc_label` field in DSP output for downstream analysis cuts
- **Fallback Operation:** If ML model unavailable, processing continues without quality classification; all waveforms processed with warning
- **Performance Monitoring:** Classification statistics logged for model performance assessment and potential retraining needs

---

## Internal Functions

**get_data_key_for_channel(ds, ch::ChannelIdLike, det::DetectorIdLike)**
- **Returns:** `string` or `nothing` - data key for channel access
- **Purpose:** Resolves channel vs detector name conflicts in physics HDF5 files (same logic as calibration)

**filekey_dsp(fk::FileKey)**
- **Returns:** `(timer, log, processed=Bool)` - processing results per physics file
- **Purpose:** Main processing logic **per physics file** - coordinates multi-system processing:

**Multi-System Processing Workflow:**
1. **Additional Channels:** Process auxiliary channels with custom DSP functions if configured
2. **PMT Processing:** Apply PMT-specific DSP to all PMT channels, skip if no PMT data found
3. **SiPM Processing:** Apply SiPM DSP with optimized parameters, requires SiPM optimization parameters
4. **HPGe Processing:** Apply full ICPC DSP with all optimizations, requires decay times and filter optimization

**Parameter Validation per System:**
- **HPGe:** Requires `pars_tau`, `pars_fltoptimization` (both filter and A/E optimization)
- **SiPM:** Requires `pars_sipm` from SiPM optimization
- **PMT:** Uses configuration only, no optimization parameters required

**Partition-Based Parameter Loading:**
- Support for partition-based parameters (`ppars`) vs run-based (`rpars`)
- Automatic fallback to closest partition if current run not in any partition
- Graceful handling of missing parameters with detector skipping

---

## Outputs

**Data Tier:**
- **Path:** `$GENERATED_DATA_PATH/tier/jldsp/phy/<period>/<run>/`
- **Files:** `l200-<period>-r<run>-phy-<filekey>.lh5` (one per raw physics file)
- **Structure:** `<channel>/jldsp/` with system-specific DSP parameter tables

**Content per System:**

**HPGe Parameters (same as calibration DSP):**
- **Baseline:** `blmean`, `blsigma`, `blslope`, `bloffset`, `blfc`
- **Energy:** `e_trap`, `e_cusp`, `e_zac`, `e_10410`, `e_535`, `e_313`, `e_*_max`, `t_*_max`
- **Timing:** `t0`, `t10`, `t50`, `t80`, `t90`, `t99`, `t50_pre`, `t50_current`, `drift_time`
- **A/E:** `a_sg`, `a_60`, `a_100`, `a_raw`
- **Advanced:** `qdrift`, `lq`, `tail_τ`, `tail_*`, `tailmean`, `tailsigma`, `tailslope`, `tailoffset`
- **QC:** `qc_label`, `inTrace_intersect`, `inTrace_n`, `n_sat_*`, `t_sat_*`
- **Inverted:** `e_10410_inv`, `e_313_inv`, `t0_inv`
- **Metadata:** `timestamp`, `eventID_fadc`, `e_fc`, `deadtime`

**SiPM Parameters:**
- **Baseline:** `blfc`
- **Timing:** `timestamp`, `eventID_fadc`
- **Energy:** `e_fc` (DAQ energy)
- **Trigger Detection:** `trig_pos`, `trig_max` (photo-electron triggers)
- **Discharge Detection:** `trig_pos_DC`, `trig_max_DC` (discharge events)

**PMT Parameters:**
- **Baseline:** Baseline statistics from configured windows
- **Timing:** `timestamp`, `eventID_fadc`, `channel`
- **Energy:** `e_fc` (DAQ energy)
- **Pulse Detection:** Raw and smoothed pulse parameters
- **Trigger Information:** Multiple pulse positions and amplitudes
- **Saturation:** Saturation flags for veto logic

**Plots:**
- **Path:** None (this processor produces no plots)

**Parameters:**
- **Path:** None (this processor uses existing parameters, produces no new ones)

**Processing Reports:**
- **Path:** `$GENERATED_DATA_PATH/jlreports/phy/<period>/<run>/`
- **Files:** Processing logs with per-system timing and failure statistics

**Notes:**
- **System Integration:** Coordinates DSP across heterogeneous detector systems in single processing workflow
- **Parameter Dependencies:** Requires successful completion of all optimization processors for respective detector systems
- **Fallback Logic:** Graceful degradation when ML models or optimization parameters unavailable
- **Scalability:** Parallel processing per file with multi-system coordination and error isolation
- **Physics Context:** Optimized for real-time physics data with potentially different background and pile-up characteristics compared to calibration data
