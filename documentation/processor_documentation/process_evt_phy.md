# process_evt_phy.jl

**Purpose:** Builds multi-detector global physics events from DSP data by calibrating all detector systems (HPGe, SiPM, PMT, auxiliary), applying cross-system coincidence logic, and creating the final `jlevt` and `jlpmt` data tiers for physics analysis. This processor transforms individual detector hits into correlated multi-detector events suitable for 0νββ searches by establishing temporal coincidences, applying calibrated energy scales, computing pulse shape discrimination parameters, and implementing cross-system veto logic.

---

## Path Variables

```
$RAW_DATA_PATH = .../legend_data_production/raw_compressed
$METADATA_PATH = .../legend_data_production/jl-v0.5.0/legend-metadata_new_yaml_p14
$GENERATED_DATA_PATH = .../legend_data_production/jl-v0.5.0/generated
$JLDSP_PATH = .../legend_data_production/jl-v0.5.0/generated/tier/jldsp
$JLEVT_PATH = .../legend_data_production/jl-v0.5.0/generated/tier/jlevt
$JLPMT_PATH = .../legend_data_production/jl-v0.5.0/generated/tier/jlpmt
```

---

## Inputs

**DSP Physics Data:**
- **Path:** `$GENERATED_DATA_PATH/tier/jldsp/phy/<period>/<run>/`
- **Data Keys:** Complete DSP parameter tables from `process_dsp_phy` for all detector systems
  - **HPGe DSP:** Energy estimators, timing parameters, A/E amplitudes, QC flags, pile-up detection
  - **SiPM DSP:** Photo-electron triggers, discharge flags, timing information
  - **PMT DSP:** Pulse parameters, saturation flags, multi-pulse detection
  - **Auxiliary DSP:** Forced triggers, pulser events, special system channels

**Calibration Parameters (Flexible Parameter Types):**
- **Energy Calibration:** `$GENERATED_DATA_PATH/jlpar/rpars/ecal/<period>/<run>.yaml` OR `$GENERATED_DATA_PATH/jlpar/ppars/ecal/<period>/<partition>.yaml`
- **A/E Calibration:** `$GENERATED_DATA_PATH/jlpar/rpars/aoe/<period>/<run>.yaml` OR `$GENERATED_DATA_PATH/jlpar/ppars/aoe/<period>/<partition>.yaml`  
- **LQ Calibration:** `$GENERATED_DATA_PATH/jlpar/rpars/lq/<period>/<run>.yaml` OR `$GENERATED_DATA_PATH/jlpar/ppars/lq/<period>/<partition>.yaml`
- **SiPM Calibration:** `$GENERATED_DATA_PATH/jlpar/rpars/sipmcal/<period>/<run>.yaml` OR `$GENERATED_DATA_PATH/jlpar/ppars/sipmcal/<period>/<partition>.yaml`
- **Parameter Types:**
  - **`rpars`** (Run-based parameters): Calibration parameters determined per individual run
  - **`ppars`** (Partition-based parameters): Averaged parameters over multiple runs within data partitions
  - **Selection Logic:** Functions automatically select available parameter type based on data availability and configuration

**Event Configuration:**
- **HPGe Event Config:** `$METADATA_PATH/jldataprod/config/evt/`
- **SiPM Event Config:** `$METADATA_PATH/jldataprod/config/evt/`
- **PMT Event Config:** `$METADATA_PATH/jldataprod/config/evt/`
- **Cross-System Config:** Coincidence windows, veto thresholds, topology cuts

---

## Functions

### 1. calibrate_all()
**Location:** `LegendEventAnalysis.jl/src/calibrate_all.jl:10`

**Parameters:**
```julia
calibrate_all(
    data::LegendData,
    sel::AnyValiditySelection,
    datastore::AbstractDataStore,
    tier::DataTierLike=:jldsp
)
```

**Returns:**
- `result_t::Table`: Complete multi-detector event table with calibrated parameters, coincidence flags, and cross-system cuts
- `pmt_events::Table`: Separate PMT event table for muon veto analysis

**Purpose:** Master event building function that orchestrates calibration and coincidence analysis across all detector systems. **Central to 0νββ Physics Analysis:** Creates correlated multi-detector events by combining HPGe energy measurements with SiPM scintillation light and PMT muon veto information, enabling comprehensive background discrimination and event topology reconstruction essential for 0νββ searches.

**Detailed Multi-System Workflow:**

**Step 1: Channel Selection and System Identification**
- **HPGe Channel Discovery:** Identify all active HPGe channels using `get_ged_evt_chsel_propfunc()` based on hardware configuration and run validity
- **Hit Channel Filtering:** Select subset of HPGe channels designated for hit-level analysis using `get_ged_evt_hitchsel_propfunc()`
- **SiPM Channel Selection:** Identify operational SiPM channels using `get_spms_evt_chsel_propfunc()` from liquid argon light detection system
- **PMT Channel Mapping:** Enumerate PMT channels from liquid scintillator veto system using `get_pmts_evt_chsel_propfunc()`
- **Auxiliary Channel Registration:** Collect auxiliary channels (forced triggers, pulser events) using `get_aux_evt_chsel_propfunc()`

**Step 2: Per-Detector HPGe Calibration and Quality Assessment**
- **Parallel Calibration:** Thread-parallel processing of all HPGe channels using `calibrate_ged_channel_data()` with detector-specific parameters
- **Energy Calibration:** Apply ADC→keV conversion using `rpars/ecal` parameters for all energy estimators (trap, cusp, zac, robust variants)
- **Pulse Shape Discrimination:** Compute calibrated A/E ratios using `rpars/aoe` correction functions and classify events using optimized cuts
- **Liquid Scintillator Parameter:** Apply LQ normalization using `rpars/lq` parameters for additional background discrimination
- **Quality Control:** Apply comprehensive QC cuts including ML classification, saturation detection, pile-up identification, and baseline quality assessment
- **Physical Trigger Identification:** Flag events passing all QC criteria as valid physics triggers using `is_physical_trig` combining multiple quality indicators

**Step 3: HPGe Global Event Construction**
- **Temporal Coincidence:** Group HPGe hits into global events using `build_global_events()` with configurable time window (default 25 µs)
- **Multiplicity Analysis:** Compute event multiplicity (number of HPGe detectors firing) and identify highest-energy detector per event
- **Trigger Channel Arrays:** Create per-event lists of triggered HPGe channels with corresponding energies and timing information
- **Event-Level Parameters:** Compute event-wide quantities including total energy, energy distribution, and timing characteristics
- **Quality Validation:** Assess event-level quality including trigger validity, hit consistency, and PSD performance across all triggered detectors

**Step 4: SiPM Light Detection Integration**
- **SiPM Calibration:** Apply photo-electron calibration using `calibrate_spm_channel_data()` with `rpars/sipmcal` parameters
- **Photo-Electron Processing:** Convert SiPM DSP triggers to calibrated photo-electron counts and timing information
- **HPGe-SiPM Coincidence:** Establish temporal correlation between HPGe energy deposits and SiPM light detection within configured time windows
- **Light Yield Analysis:** Compute total photo-electron yield, channel multiplicity, and spatial light distribution for event topology reconstruction
- **Background Discrimination:** Use combined energy-light information to distinguish single-site (0νββ-like) from multi-site (background-like) events

**Step 5: PMT Muon Veto Processing**
- **PMT Event Building:** Process PMT channels using `calibrate_pmt_channel_data()` for liquid scintillator muon veto system
- **Muon Detection:** Apply muon identification algorithm using energy thresholds, multiplicity cuts, and spatial correlation across PMT array
- **Veto Decision Logic:** Implement configurable veto criteria based on total scintillation energy, PMT multiplicity, and noise discrimination
- **Timing Correlation:** Establish coincidence between PMT muon triggers and HPGe physics events for background rejection
- **Cosmic Ray Identification:** Flag events associated with cosmic muon interactions for removal from 0νββ analysis

**Step 6: Auxiliary System Integration**
- **Forced Trigger Processing:** Handle system-generated forced triggers for detector monitoring and calibration
- **Pulser Event Identification:** Process calibration pulser events for system stability monitoring
- **Special Channel Data:** Integrate data from auxiliary channels including timing references and system diagnostics
- **Trigger Classification:** Categorize events as physics triggers, forced triggers, or pulser events for appropriate downstream processing

**Step 7: Cross-System Event Assembly**
- **Multi-System Merging:** Combine HPGe, SiPM, PMT, and auxiliary data into unified event structure using `build_cross_system_events()`
- **Coincidence Logic:** Apply cross-system timing constraints to establish correlated multi-detector events
- **LAr Cut Integration:** Implement HPGe-SiPM coincidence cuts using `_build_lar_cut()` for liquid argon light-based background discrimination  
- **Muon Veto Application:** Apply PMT-based muon veto using `_build_muon_evt_cut()` for cosmic ray background rejection
- **Event Quality Assessment:** Evaluate overall event quality considering all detector systems and cross-system consistency

**Physics Analysis Context:**
- **0νββ Event Signatures:** Single-site energy deposits in HPGe with minimal SiPM light and no PMT activity (no muon veto)
- **Background Discrimination:** Multi-site events show distributed energy deposits with higher SiPM light yield; muon-induced events trigger PMT veto
- **Event Topology:** Combined energy-light-veto information enables powerful background rejection while maintaining high 0νββ detection efficiency
- **Systematic Monitoring:** Cross-system correlations provide independent validation of detector performance and data quality

### 2. calibrate_ged_channel_data()
**Location:** `LegendEventAnalysis.jl/src/calibrate_geds.jl:13`

**Parameters:**
```julia
calibrate_ged_channel_data(
    data::LegendData,
    sel::AnyValiditySelection,
    detector::DetectorIdLike,
    channel_data::AbstractVector;
    e_cal_pars_type::Symbol=:rpars,
    e_cal_pars_cat::Symbol=:ecal,
    psd_pars_type::Symbol=:ppars,
    aoe_cal_pars_type::Symbol=:ppars,
    aoe_cal_pars_cat::Symbol=:aoe,
    lq_cal_pars_type::Symbol=:ppars,
    lq_cal_pars_cat::Symbol=:lq,
    keep_chdata::Bool=false
)
```

**Returns:**
- `calibrated_data::StructVector`: Fully calibrated HPGe event data with applied energy scales, PSD parameters, and quality cuts

**Purpose:** Comprehensive per-detector HPGe calibration applying all optimized parameters from previous processing steps. **Critical for Physics Precision:** Transforms raw DSP parameters into physics-ready measurements using detector-specific calibrations optimized during calibration runs, ensuring accurate energy reconstruction and maximum background discrimination performance.

**Detailed Calibration Workflow:**

**Step 1: Energy Scale Application**
- **Multi-Estimator Calibration:** Apply energy calibration functions from `rpars/ecal` to all energy estimators (e_trap, e_cusp, e_zac, robust variants)
- **CTC Integration:** Include charge-trapping corrected energies (e_trap_ctc, e_cusp_ctc) using corrections from `rpars/ctc`
- **Energy Resolution:** Apply energy-dependent resolution functions for uncertainty propagation and analysis cuts
- **Cross-Validation:** Compare multiple energy estimators for consistency checks and systematic uncertainty assessment

**Step 2: Pulse Shape Discrimination Enhancement**
- **A/E Correction:** Apply energy-dependent A/E correction functions from `rpars/aoe` to normalize pulse shape parameters
- **Multi-Amplitude Integration:** Process all A/E variants (a_sg, a_100, a_raw) using detector-specific correction parameters
- **PSD Classification:** Apply optimized A/E cuts for single-site vs multi-site event discrimination using classifier thresholds from `rpars/aoe`
- **LQ Parameter Processing:** Compute normalized liquid scintillator parameter using `rpars/lq` for additional background discrimination

**Step 3: Quality Control Implementation**
- **ML Classification Application:** Apply trained waveform quality model results stored in DSP `qc_label` field
- **Physics Event Selection:** Implement comprehensive physics cuts combining ML classification, baseline quality, saturation detection, and pile-up identification
- **Baseline Event Flagging:** Identify baseline events for noise characterization and detector monitoring
- **Trigger Event Classification:** Flag events suitable for trigger studies and efficiency measurements

**Step 4: Post-Calibration Analysis**
- **PSD Classifier Evaluation:** Apply final pulse shape discrimination classifiers using calibrated A/E and LQ parameters
- **Event Validation:** Verify event quality using calibrated parameters and detector-specific performance criteria
- **Parameter Integration:** Merge calibrated energies, corrected PSD parameters, and quality flags into unified event structure
- **Physics Readiness:** Prepare fully calibrated per-detector data for global event building and cross-system analysis

### 3. build_global_events()
**Location:** `LegendEventAnalysis.jl/src/build_global_events.jl:121`

**Parameters:**
```julia
build_global_events(
    data::AbstractDict{<:ChannelIdLike},
    channels::AbstractVector{<:ChannelIdLike} = collect(keys(data));
    ts_window::Number = 25u"μs"
)
```

**Returns:**
- `global_events::StructVector`: Time-correlated multi-detector events with vector-of-vectors structure for per-event channel lists

**Purpose:** Constructs global multi-detector events by identifying temporal coincidences across detector channels. **Essential for Multi-Site Background Rejection:** Groups individual detector hits into correlated events based on timing, enabling identification of single-site energy deposits (0νββ-like) versus distributed multi-site interactions (background-like) through analysis of event topology and energy distribution.

**Detailed Event Building Process:**

**Step 1: Data Flattening and Preparation**
- **Channel Data Consolidation:** Flatten per-channel event data using `flatten_over_channels()` creating unified timestamp-sorted dataset
- **Temporal Sorting:** Sort all events across all channels by timestamp to enable efficient coincidence window processing
- **Channel Mapping:** Maintain channel-to-event associations for reconstruction of per-event detector lists

**Step 2: Coincidence Window Analysis**
- **Event Map Construction:** Build global event map using `build_global_event_map()` with configurable time window (default 25 µs)
- **Timing Association:** Group events with timestamps within `ts_window` of each other as belonging to the same global event
- **Multiplicity Tracking:** Record number of detectors participating in each global event for background discrimination
- **Time Ordering:** Maintain chronological ordering within each global event for timing analysis

**Step 3: Event Structure Assembly**
- **Vector-of-Vectors Creation:** Construct per-event lists of participating channels, energies, and timing parameters using VectorOfVectors format
- **Event Indexing:** Create efficient indexing structure for fast access to per-event multi-detector information
- **Parameter Aggregation:** Collect all calibrated parameters (energies, PSD, timing) organized by global event

**Step 4: Physics Event Characterization**
- **Topology Analysis:** Enable analysis of energy distribution across multiple detectors within each event
- **Site Classification:** Support single-site vs multi-site discrimination based on spatial energy distribution
- **Timing Precision:** Maintain sub-microsecond timing precision for detailed coincidence analysis and background studies

### 4. build_cross_system_events()
**Location:** `LegendEventAnalysis.jl/src/build_global_events.jl:147`

**Parameters:**
```julia
build_cross_system_events(
    data::NamedTuple,
    ts_window::Number = 25u"μs"
)
```

**Returns:**
- `cross_system_events::StructVector`: Unified event structure with synchronized timing across all detector systems

**Purpose:** Merges global events from different detector systems (HPGe, SiPM, PMT) into unified cross-system events with synchronized timing. **Critical for 0νββ Background Rejection:** Enables comprehensive event analysis combining germanium energy measurements with liquid argon light detection and muon veto information for maximum background discrimination while preserving 0νββ signal efficiency.

**Detailed Cross-System Integration:**

**Step 1: System Synchronization**
- **Timing Validation:** Verify consistent global event timing across all detector systems using `tstart` column comparison
- **Event Alignment:** Ensure HPGe, SiPM, and PMT events are properly time-aligned for accurate coincidence analysis
- **System Merging:** Combine per-system global events into unified structure maintaining individual system information

**Step 2: Cross-System Correlation**
- **HPGe-SiPM Coincidence:** Establish correlation between germanium energy deposits and liquid argon scintillation light
- **PMT Veto Integration:** Apply muon veto logic based on liquid scintillator PMT activity
- **Auxiliary System Inclusion:** Integrate forced triggers, pulser events, and timing references

**Step 3: Multi-Detector Event Analysis**
- **Topology Reconstruction:** Enable analysis of event topology using combined energy-light-veto information
- **Background Classification:** Support sophisticated background discrimination using multi-system signatures
- **Physics Event Selection:** Prepare events for final 0νββ analysis with all available discrimination parameters

### 5. build_global_event_map()
**Location:** `LegendEventAnalysis.jl/src/build_global_events.jl:24`

**Parameters:**
```julia
build_global_event_map(
    data::StructVector;
    ts_window::Number = 25u"μs"
)
```

**Returns:**
- `event_map::StructVector`: Global event mapping with fields `tstart`, `dataidx`, `chevtno`, `channel`, `timestamp` organizing temporal coincidences

**Purpose:** Creates efficient mapping structure for grouping individual detector hits into global events based on temporal proximity. **Fundamental for Event Reconstruction:** Provides the algorithmic foundation for multi-detector event building by implementing sliding time window algorithm that identifies which detector hits belong to the same physical interaction.

**Detailed Mapping Algorithm:**

**Step 1: Temporal Organization**
- **Timestamp Sorting:** Order all detector hits chronologically across all channels for efficient window processing
- **Event Initialization:** Initialize global event structure with timing and channel tracking arrays

**Step 2: Sliding Window Processing**
- **Coincidence Detection:** Implement sliding time window algorithm scanning for hits within `ts_window` of each other
- **Event Boundary Detection:** Identify event boundaries when time gaps exceed coincidence window
- **Event Flushing:** Complete events when new hits fall outside current event's time window

**Step 3: Mapping Structure Creation**
- **Event Start Times:** Record global event start times for chronological event ordering
- **Channel Lists:** Maintain per-event lists of participating detector channels
- **Index Mapping:** Create efficient index mapping for fast retrieval of event-associated data
- **Event Validation:** Ensure proper event structure and timing consistency

**Algorithm Performance:**
- **Linear Complexity:** O(N) algorithm complexity for N total hits across all detectors
- **Memory Efficiency:** Minimal memory overhead using vector-of-vectors structure
- **Real-Time Capability:** Suitable for online event processing during data acquisition

---

## Internal Functions

**filekey_evt(fk::FileKey)**
- **Returns:** `(timer, log, processed=Bool)` - processing results per DSP file
- **Purpose:** Main processing logic **per DSP file** - orchestrates multi-detector event building by calling `calibrate_all()` and writing results to `jlevt` and `jlpmt` tiers

**Processing Workflow per File:**
1. **File Validation:** Check if output files exist and handle reprocessing logic
2. **Multi-System Calibration:** Call `calibrate_all()` to process all detector systems in DSP file
3. **Event Statistics:** Count physical triggers, forced triggers, and pulser events for monitoring
4. **Data Writing:** Write main event data to `jlevt` tier and PMT-specific data to `jlpmt` tier
5. **Error Handling:** Implement robust error handling with detailed logging for debugging

**get_data_key_for_channel(ds, ch::ChannelIdLike, det::DetectorIdLike)**
- **Returns:** `string` or `nothing` - data key for channel access
- **Purpose:** Resolves channel vs detector name conflicts in HDF5 files (inherited from DSP processors)

---

## Outputs

**Data Tier (Main Events):**
- **Path:** `$GENERATED_DATA_PATH/tier/jlevt/phy/<period>/<run>/`
- **Files:** `l200-<period>-r<run>-phy-<filekey>.lh5` (one per DSP file)
- **Structure:** `jlevt/` with comprehensive multi-detector event information

**Event Structure (jlevt):**

**HPGe System (`geds`):**
- **Event Identification:**
  - `tstart`: Global event start time for cross-system synchronization
  - `multiplicity`: Number of HPGe detectors triggered per event
  - `trig_e_ch`: List of triggered HPGe channels per event
  - `trig_e_ch_idxs`: Channel indices for efficient data access
- **Energy Information:**
  - `max_e_trap_cal`, `max_e_cusp_cal`: Maximum energies per event (keV)
  - `max_e_trap_ctc_cal`, `max_e_cusp_ctc_cal`: CTC-corrected maximum energies
  - `max_e_short_cal`: Maximum short-filter energy for pile-up studies
  - `trig_e_trap_max_cal`, `trig_e_cusp_max_cal`: Per-detector energy arrays
  - `trig_e_trap_ctc_cal`, `trig_e_cusp_ctc_cal`: CTC-corrected energy arrays
- **Timing Parameters:**
  - `t0_start`: Earliest t0 across all triggered detectors
  - `trig_t0`: Per-detector t0 timing arrays
- **Quality Flags:**
  - `is_valid_qc`: Event-level quality control status
  - `is_valid_trig`: Trigger validity based on hit channel requirements
  - `is_valid_hit`: Hit-level parameter validity for all triggered detectors
  - `is_valid_psd`: Pulse shape discrimination quality across event
  - `is_discharge_recovery`, `is_saturated`, `is_discharge`: Problem event flags

**SiPM System (`spms`):**
- **Photo-Electron Detection:**
  - `energy_sum`: Total photo-electron yield across all SiPM channels
  - `multiplicity`: Number of SiPM channels with detected light
  - `t0_good`: Timing of photo-electron signals in HPGe coincidence window
  - `energy_good`: Photo-electron amplitudes in coincidence window
- **Coincidence Analysis:**
  - `geds_coincidence_classifier`: Likelihood-based HPGe-SiPM correlation
  - `is_trig_coin_pulse`: Boolean flags for pulses in coincidence window
- **Event Topology:**
  - Spatial distribution of light across SiPM array for topology reconstruction
  - Timing correlation with HPGe energy deposits for background discrimination

**Auxiliary Systems (`aux`):**
- **Forced Triggers (`forcedtrigger`):**
  - `aux_trig`: Boolean flags for system-generated forced triggers
  - Used for detector monitoring and calibration validation
- **Pulser Events (`pulser`):**
  - `aux_trig`: Boolean flags for calibration pulser events  
  - Used for system stability monitoring and energy scale validation

**Cross-System Correlations:**
- **HPGe-SiPM Correlation (`ged_spm`):**
  - Liquid argon cut results combining energy and light information
  - Background discrimination based on expected light yield for energy deposits
- **Forced Trigger-SiPM (`ft_spm`):**
  - SiPM response validation during forced trigger events
- **HPGe-PMT Correlation (`ged_pmt`):**
  - Muon veto decisions based on PMT activity coincident with HPGe events
  - Background rejection for cosmic muon-induced interactions

**Data Tier (PMT Events):**
- **Path:** `$GENERATED_DATA_PATH/tier/jlpmt/phy/<period>/<run>/`
- **Files:** `l200-<period>-r<run>-phy-<filekey>.lh5` (when PMT data available)
- **Structure:** `jlpmt/` with PMT-specific muon veto information

**PMT Event Structure (jlpmt):**
- **Muon Detection:**
  - `timestamp`: PMT event timing for coincidence analysis
  - `energy_sum`: Total scintillation energy across PMT array
  - `multiplicity`: Number of PMTs detecting scintillation light
  - `is_muon`: Boolean muon identification based on energy and multiplicity thresholds
  - `energy_max`: Maximum energy in single PMT channel
- **Noise Discrimination:**
  - `muon_noise_peaks`: Number of noise-like peaks for background rejection
  - Quality metrics for distinguishing genuine muon signals from electronics noise

**Processing Reports:**
- **Path:** `$GENERATED_DATA_PATH/jlreports/phy/<period>/<run>/`
- **Files:** Processing logs with event building statistics and timing information
- **Content:** Per-file trigger counts, processing times, and error diagnostics

**Notes:**
- **Event Building Philosophy:** Multi-detector events enable sophisticated background discrimination combining energy, light, and veto information
- **0νββ Optimization:** Event structure optimized for 0νββ searches with comprehensive background rejection capabilities
- **Cross-System Integration:** Unified event structure supports advanced analysis techniques using all available detector information
- **Data Efficiency:** Vector-of-vectors structure provides memory-efficient storage for variable-multiplicity events
- **Physics Analysis Ready:** Output format directly suitable for final 0νββ analysis without additional processing steps
