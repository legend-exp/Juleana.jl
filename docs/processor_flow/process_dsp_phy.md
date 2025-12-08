# Processor: process_dsp_phy

| Property | Value |
|----------|-------|
| **Input Tier** | `raw` |
| **Output Tier** | `jldsp` |
| **Category** | `phy` |
| **Detector Types** | HPGe (ICPC), SiPM, PMT, Auxiliary (Pulser, Baseline, Muon) |

---

# 1 Input

<details>
<summary><b>1.1 Tier Data</b></summary>

| Tier | Description |
|------|-------------|
| `raw` | Raw waveform data from FlashCam DAQ |

<details>
<summary>1.1.1 HPGe Raw Data Keys</summary>

| Key | Type | Description |
|-----|------|-------------|
| `waveform_presummed` | ArrayOfRDWaveforms | Presummed waveform data (compressed readout) |
| `waveform_windowed` | ArrayOfRDWaveforms | Windowed waveform data (compressed readout) |
| `presum_rate` | Vector | Presum rate for decompression |
| `baseline` | Vector | Baseline from FlashCam |
| `timestamp` | Vector | Timestamp from DAQ |
| `eventnumber` | Vector | Event number from DAQ |
| `daqenergy` | Vector | Energy from FlashCam |
| `t_sat_lo` | Vector | Time of low saturation |
| `t_sat_hi` | Vector | Time of high saturation |
| `deadtime` | Vector | Deadtime from DAQ |

</details>

<details>
<summary>1.1.2 SiPM Raw Data Keys</summary>

| Key | Type | Description |
|-----|------|-------------|
| `waveform_bit_drop` | ArrayOfRDWaveforms | Bit-dropped waveform data (compressed readout) |
| `baseline` | Vector | Baseline from FlashCam |
| `timestamp` | Vector | Timestamp from DAQ |
| `eventnumber` | Vector | Event number from DAQ |
| `daqenergy` | Vector | Energy from FlashCam |

</details>

<details>
<summary>1.1.3 PMT Raw Data Keys</summary>

| Key | Type | Description |
|-----|------|-------------|
| `waveform` | ArrayOfRDWaveforms | Full waveform data (uncompressed readout) |
| `baseline` | Vector | Baseline from FlashCam |
| `timestamp` | Vector | Timestamp from DAQ |
| `eventnumber` | Vector | Event number from DAQ |
| `daqenergy` | Vector | Energy from FlashCam |
| `channel` | Vector | Channel ID |

</details>

<details>
<summary>1.1.4 Auxiliary Raw Data Keys</summary>

| Key | Type | Description |
|-----|------|-------------|
| `waveform_presummed` | ArrayOfRDWaveforms | Presummed waveform data |
| `waveform_windowed` | ArrayOfRDWaveforms | Windowed waveform data |
| `presum_rate` | Vector | Presum rate |
| `baseline` | Vector | Baseline from FlashCam |
| `timestamp` | Vector | Timestamp from DAQ |
| `eventnumber` | Vector | Event number from DAQ |
| `daqenergy` | Vector | Energy from FlashCam |

</details>

</details>

<details>
<summary><b>1.2 Configuration Files</b></summary>

| Config | Path | Description |
|--------|------|-------------|
| DSP Config | `dataprod_config(l200).dsp(filekey)` | DSP processing parameters for HPGe detectors (windows, thresholds, filter lengths) |
| SiPM Config | `dataprod_config(l200).sipm(filekey)` | SiPM-specific DSP parameters (trigger thresholds, discharge detection) |
| PMT Config | `dataprod_config(l200).pmt(filekey)` | PMT-specific DSP parameters (baseline window, saturation limits) |

</details>

<details>
<summary><b>1.3 Parameter Files</b></summary>

| Parameter | Source | Description |
|-----------|--------|-------------|
| Decay Time (tau) | `l200.par.rpars.pz(filekey)` or `l200.par.ppars.pz` | Detector decay time for pole-zero correction (per detector) |
| Filter Optimization | `l200.par.rpars.fltopt(filekey)` or `l200.par.ppars.fltopt` | Optimized rise/flat-top times for Trap, CUSP, ZAC filters (per detector) |
| A/E Optimization | `l200.par.rpars.aoeopt(filekey)` or `l200.par.ppars.aoeopt` | Optimized Savitzky-Golay window length for current extraction (per detector) |
| SiPM Optimization | `l200.par.rpars.sipmopt(filekey)` | SiPM Savitzky-Golay window length (per detector) |
| ML QC Model | `get_mltrainfilename(l200, filekey)` | Trained SVM model for waveform quality classification |
| ML Config | `l200.par.rpars.ml(filekey)` | ML model configuration parameters |

</details>

<details>
<summary><b>1.4 Channel Information</b></summary>

| System | Variable | Description |
|--------|----------|-------------|
| HPGe | `chinfo` | Channel info for germanium detectors (system=:geds, only_processable=true) |
| SiPM | `chinfo_sipm` | Channel info for silicon photomultipliers (system=:spms, only_processable=true) |
| PMT | `chinfo_pmts` | Channel info for photomultiplier tubes (system=:pmts, only_processable=true) |
| Auxiliary | `dsp_config_pd.additional_channel` | Additional channels defined in config (e.g., Puls01, Bsln01, Muon01) |

</details>

---

# 2 Workflow

<details>
<summary><b>2.1 Detailed Workflow Steps</b></summary>

```
1. Initialize
   - Search filekeys on disk for period/run
   - Load channel info for HPGe, SiPM, PMT systems
   - Load DSP configs (dsp, sipm, pmt)
   
2. Load Parameters (global, all detectors)
   - pars_tau: all decay times
   - pars_fltoptimization: all filter parameters (fltopt + aoeopt merged)
   - pars_sipm: all SiPM parameters
   - Load or create QC ML classifier
   
3. (Optional) Load Default Parameters
   - If use_dsp_config_defaults=true: load fallback values from config
   - tau default: 460.0 us
   - filter defaults: from dsp_config.default.flt_defaults
   - SiPM default: 148.0 ns
   
4. For each FileKey (parallel via worker pool):
   a. Open raw file (read) and output file (create/modify)
   b. Process Auxiliary channels (Puls01, Bsln01, Muon01)
   c. Process PMT detectors
   d. Process SiPM detectors (extract pars per detector)
   e. Process HPGe detectors (extract pars per detector)
   f. Save results to jldsp tier
   g. Track timing and failed detectors
   
5. Generate Report
   - Processing time, detector counts, failed detectors
   - Default parameter usage summary
```

</details>

<details>
<summary><b>2.2 Main Processing Functions</b></summary>

<details>
<summary>2.2.1 HPGe Detectors - <code>dsp_icpc_compressed()</code></summary>

**Source:** `LegendDSP.jl/src/dsp_icpc.jl`

**Parameter extraction per detector:**
```julia
# Decay time (single value)
detector_tau = pars_tau[det]  # Contains: τ (decay time in us)

# Filter optimization (PropDict with filter parameters)
detector_fltopt = PropDict()
# Copy from pars_fltoptimization[det]:
#   - trap: {rt, ft} (rise time, flat-top time)
#   - cusp: {rt, ft}
#   - zac: {rt, ft}
#   - sg: {wl} (Savitzky-Golay window length for A/E)
```

**Function Call:**
```julia
outdata_ch = dsp_icpc_compressed(
    raw_data[raw_key].raw[:],   # raw waveform data
    dsp_config_ch,               # DSP configuration (DSPConfig)
    detector_tau.τ,              # decay time (Quantity, e.g. 460.0u"μs")
    detector_fltopt;             # filter parameters (PropDict)
    f_evaluate_qc=f_evaluate_qc  # QC classifier function (optional)
)
```

**Detailed Documentation:** [analysis_functions/dsp_icpc_compressed.md](../analysis_functions/dsp_icpc_compressed.md)

</details>

<details>
<summary>2.2.2 SiPM Detectors - <code>dsp_sipm_compressed()</code></summary>

**Source:** `LegendDSP.jl/src/dsp_sipm.jl`

**Parameter extraction per detector:**
```julia
detector_sipmopt = pars_sipm[det]  # Contains: sg.wl (Savitzky-Golay window length)
```

**Function Call:**
```julia
outdata_ch = dsp_sipm_compressed(
    raw_data[raw_key].raw[:],   # raw waveform data
    dsp_meta_ch,                 # SiPM configuration (PropDict)
    detector_sipmopt             # SiPM optimization parameters
)
```

**Detailed Documentation:** [analysis_functions/dsp_sipm_compressed.md](../analysis_functions/dsp_sipm_compressed.md)

</details>

<details>
<summary>2.2.3 PMT Detectors - <code>dsp_pmts()</code></summary>

**Source:** `LegendDSP.jl/src/dsp_pmts.jl`

**Function Call:**
```julia
outdata_ch = dsp_pmts(
    raw_data[raw_key].raw[:],   # raw waveform data
    dsp_meta_ch                  # PMT configuration (PropDict)
)
```

**Detailed Documentation:** [analysis_functions/dsp_pmts.md](../analysis_functions/dsp_pmts.md)

</details>

<details>
<summary>2.2.4 Auxiliary Channels - <code>dsp_puls_compressed()</code> (dynamic)</summary>

**Source:** `LegendDSP.jl/src/dsp_puls.jl`

DSP function is determined dynamically from config:
```julia
# Config defines which function to use per channel
# e.g., dsp_config_pd.additional_channel.Puls01 = "dsp_puls_compressed"

config_name = dsp_config_pd.additional_channel[Symbol(det)]
dsp_function = getfield(LegendDSP, Symbol(config_name))
```

**Function Call:**
```julia
outdata_ch = getfield(LegendDSP, Symbol(config_name))(
    raw_data[raw_key].raw[:],   # raw waveform data
    dsp_config_ch                # DSP configuration
)
```

**Detailed Documentation:** [analysis_functions/dsp_puls_compressed.md](../analysis_functions/dsp_puls_compressed.md)

</details>

</details>

<details>
<summary><b>2.3 Parallel Processing Structure</b></summary>

The processor uses parallel processing via `ParallelProcessingTools.jl`:

| Level | Unit | Description |
|-------|------|-------------|
| Parallel | FileKey | Each worker processes one filekey (one raw file) independently |
| Sequential | Detector | Within each filekey, detectors are processed sequentially in loops |

The worker pool is obtained via `get_workerPool(processing_config, nameof(var"#self#"))` and the parallel execution is done via `parallel(filekeys, filekey_dsp, log_nt, wpool; ...)`.

</details>

---

# 3 Output

<details>
<summary><b>3.1 Tier Data</b></summary>

| Tier | Description |
|------|-------------|
| `jldsp` | DSP-processed data with extracted parameters, one group per detector |

<details>
<summary>3.1.1 HPGe (dsp_icpc_compressed)</summary>

<details>
<summary>3.1.1.1 Baseline Parameters</summary>

| Column | Type | Unit | Description |
|--------|------|------|-------------|
| `blmean` | Float | ADC | Baseline mean in baseline window |
| `blsigma` | Float | ADC | Baseline standard deviation |
| `blslope` | Float | ADC/sample | Baseline slope (linear fit) |
| `bloffset` | Float | ADC | Baseline offset (linear fit) |

</details>

<details>
<summary>3.1.1.2 Tail Parameters</summary>

| Column | Type | Unit | Description |
|--------|------|------|-------------|
| `tailmean` | Float | ADC | Tail mean after pole-zero correction |
| `tailsigma` | Float | ADC | Tail sigma after pole-zero correction |
| `tailslope` | Float | ADC/sample | Tail slope |
| `tailoffset` | Float | ADC | Tail offset |
| `tail_tau` | Float | us | Extracted decay time from tail (before PZ) |
| `tail_mean` | Float | ADC | Tail mean before PZ correction |
| `tail_sigma` | Float | ADC | Tail sigma before PZ correction |

</details>

<details>
<summary>3.1.1.3 Timing Parameters</summary>

| Column | Type | Unit | Description |
|--------|------|------|-------------|
| `t0` | Float | us | Start time of waveform drift (signal onset) |
| `t10` | Float | us | Time at 10% of maximum |
| `t50` | Float | us | Time at 50% of maximum |
| `t50_pre` | Float | us | Time at 50% of maximum (presummed waveform) |
| `t80` | Float | us | Time at 80% of maximum |
| `t90` | Float | us | Time at 90% of maximum |
| `t99` | Float | us | Time at 99% of maximum |
| `t50_current` | Float | us | Time of current rise to 50% |
| `drift_time` | Float | ns | Drift time (t90 - t0) |
| `t0_inv` | Float | us | Start time of inverted waveform (for DC tagging) |

</details>

<details>
<summary>3.1.1.4 Energy Parameters (Robust)</summary>

| Column | Type | Unit | Description |
|--------|------|------|-------------|
| `e_max` | Float | ADC | Maximum of waveform (windowed) |
| `e_min` | Float | ADC | Minimum of waveform (windowed) |
| `e_max_pre` | Float | ADC | Maximum of waveform (presummed) |
| `e_min_pre` | Float | ADC | Minimum of waveform (presummed) |
| `e_10410` | Float | ADC | Energy with Trap filter (10us rise, 4us flat-top) |
| `e_535` | Float | ADC | Energy with Trap filter (5us rise, 3us flat-top) |
| `e_313` | Float | ADC | Energy with Trap filter (3us rise, 1us flat-top) |
| `e_10410_inv` | Float | ADC | Inverted waveform energy (Trap 10-4-10) |
| `e_313_inv` | Float | ADC | Inverted waveform energy (Trap 3-1-3) |

</details>

<details>
<summary>3.1.1.5 Energy Parameters (Optimized)</summary>

| Column | Type | Unit | Description |
|--------|------|------|-------------|
| `e_trap` | Float | ADC | Energy with optimized Trapezoidal filter |
| `e_cusp` | Float | ADC | Energy with optimized CUSP filter |
| `e_zac` | Float | ADC | Energy with optimized ZAC filter |
| `e_trap_max` | Float | ADC | Maximum of trap-filtered waveform |
| `e_cusp_max` | Float | ADC | Maximum of CUSP-filtered waveform |
| `e_zac_max` | Float | ADC | Maximum of ZAC-filtered waveform |
| `t_trap_max` | Float | us | Time of trap filter maximum |
| `t_cusp_max` | Float | us | Time of CUSP filter maximum |
| `t_zac_max` | Float | us | Time of ZAC filter maximum |

</details>

<details>
<summary>3.1.1.6 Current / A/E Parameters</summary>

| Column | Type | Unit | Description |
|--------|------|------|-------------|
| `a_sg` | Float | ADC/sample | Current maximum with optimized SG filter |
| `a_60` | Float | ADC/sample | Current maximum with 60ns SG filter |
| `a_100` | Float | ADC/sample | Current maximum with 100ns SG filter |
| `a_raw` | Float | ADC/sample | Raw derivative maximum |

</details>

<details>
<summary>3.1.1.7 Pulse Shape Parameters</summary>

| Column | Type | Unit | Description |
|--------|------|------|-------------|
| `qdrift` | Float | ADC*sample | Q-drift parameter (charge in drift region) |
| `lq` | Float | ADC*sample | LQ parameter (late charge) |

</details>

<details>
<summary>3.1.1.8 Quality Parameters</summary>

| Column | Type | Unit | Description |
|--------|------|------|-------------|
| `qc_label` | Int | - | QC classifier label (0=good, 1=bad) |
| `inTrace_intersect` | Float | us | Position of in-trace pile-up |
| `inTrace_n` | Int | - | Multiplicity of in-trace pile-up |

</details>

<details>
<summary>3.1.1.9 Saturation Parameters</summary>

| Column | Type | Unit | Description |
|--------|------|------|-------------|
| `n_sat_low` | Int | - | Number of samples saturated at low ADC range |
| `n_sat_high` | Int | - | Number of samples saturated at high ADC range |
| `n_sat_low_cons` | Int | - | Consecutive samples saturated at low |
| `n_sat_high_cons` | Int | - | Consecutive samples saturated at high |
| `t_sat_lo` | Float | us | Time of low saturation |
| `t_sat_hi` | Float | us | Time of high saturation |

</details>

<details>
<summary>3.1.1.10 DAQ Parameters (pass-through)</summary>

| Column | Type | Unit | Description |
|--------|------|------|-------------|
| `blfc` | Float | ADC | Baseline from FlashCam |
| `timestamp` | Int | - | Timestamp from DAQ |
| `eventID_fadc` | Int | - | Event ID from DAQ |
| `e_fc` | Float | ADC | Energy from FlashCam |
| `deadtime` | Float | - | Deadtime from DAQ |

</details>

</details>

<details>
<summary>3.1.2 SiPM (dsp_sipm_compressed)</summary>

| Column | Type | Unit | Description |
|--------|------|------|-------------|
| `blfc` | Float | ADC | Baseline from FlashCam |
| `timestamp` | Int | - | Timestamp from DAQ |
| `eventID_fadc` | Int | - | Event ID from DAQ |
| `e_fc` | Float | ADC | Energy from FlashCam |
| `t_max` | Float | us | Time of waveform maximum |
| `t_min` | Float | us | Time of waveform minimum |
| `t_max_lar` | Float | us | Time of maximum in LAr window |
| `t_min_lar` | Float | us | Time of minimum in LAr window |
| `e_max` | Float | ADC | Waveform maximum |
| `e_min` | Float | ADC | Waveform minimum |
| `e_max_lar` | Float | ADC | Maximum in LAr window |
| `e_min_lar` | Float | ADC | Minimum in LAr window |
| `blmean` | Float | ADC | Baseline mean |
| `blsigma` | Float | ADC | Baseline sigma |
| `threshold` | Float | ADC | Trigger threshold |
| `threshold_DC` | Float | ADC | Discharge threshold |
| `trig_pos` | VectorOfVectors | us | Trigger positions |
| `trig_max` | VectorOfVectors | ADC | Trigger maxima |
| `trig_pos_DC` | VectorOfVectors | us | Discharge positions |
| `trig_max_DC` | VectorOfVectors | ADC | Discharge maxima |

</details>

<details>
<summary>3.1.3 PMT (dsp_pmts)</summary>

| Column | Type | Unit | Description |
|--------|------|------|-------------|
| `timestamp` | Int | - | Timestamp from DAQ |
| `eventID_fadc` | Int | - | Event ID from DAQ |
| `e_fc` | Float | ADC | Energy from FlashCam |
| `channel` | Int | - | Channel ID |
| `raw_pulse_height` | Float | ADC | Raw pulse maximum |
| `raw_pulse_low` | Float | ADC | Raw pulse minimum |
| `raw_t0_hi` | Float | us | Time of raw maximum |
| `raw_t0_low` | Float | us | Time of raw minimum |
| `trig_max` | VectorOfVectors | ADC | Trigger maxima |
| `trig_t` | VectorOfVectors | us | Trigger times |
| `trig_mult` | Int | - | Trigger multiplicity |
| `sat_low` | Int | - | Low saturation count |
| `sat_high` | Int | - | High saturation count |
| `pulse_height` | Float | ADC | Smoothed pulse height |
| `pulse_low` | Float | ADC | Smoothed pulse low |
| `t0_hi` | Float | us | Time of smoothed maximum |
| `t0_low` | Float | us | Time of smoothed minimum |
| `bl_mean` | Float | ADC | Baseline mean |
| `bl_sigma` | Float | ADC | Baseline sigma |
| `bl_slope` | Float | ADC/sample | Baseline slope |

</details>

<details>
<summary>3.1.4 Auxiliary Channels (dsp_puls_compressed)</summary>

| Column | Type | Unit | Description |
|--------|------|------|-------------|
| `blmean` | Float | ADC | Baseline mean |
| `blsigma` | Float | ADC | Baseline sigma |
| `blslope` | Float | ADC/sample | Baseline slope |
| `bloffset` | Float | ADC | Baseline offset |
| `t50` | Float | us | Time at 50% of maximum |
| `e_max` | Float | ADC | Waveform maximum |
| `e_10410` | Float | ADC | Energy with Trap filter (10us rise, 4us flat-top) |
| `blfc` | Float | ADC | Baseline from FlashCam |
| `timestamp` | Int | - | Timestamp |
| `eventID_fadc` | Int | - | Event ID |
| `e_fc` | Float | ADC | Energy from FlashCam |

</details>

</details>

<details>
<summary><b>3.2 Reports</b></summary>

| Output | Path | Description |
|--------|------|-------------|
| Processing Report | `get_rreportfilename(l200, filekey, :dsp_phy)` | Markdown report with processing summary, timing, and failed detectors |

</details>

---

# 4 kwargs Parameters

<details>
<summary><b>4.1 All Parameters</b></summary>

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `reprocess` | `Bool` | `false` | If true: delete existing DSP output and reprocess all detectors. If false: skip already processed detectors. |
| `timeout` | `Int` | `0` | Timeout in seconds for parallel processing per filekey. 0 = no timeout. If exceeded, the filekey processing is aborted. |
| `max_wvfs` | `Int` | `10000` | Maximum number of waveforms to load per detector. Used to limit memory usage during testing or partial processing. |
| `use_partition_filter` | `Bool` | `false` | If true: use partition-based parameters (ppars) instead of run-based parameters (rpars). |
| `use_dsp_config_defaults` | `Bool` | `false` | If true: use default values from DSP config when detector-specific parameters are missing. |

</details>
