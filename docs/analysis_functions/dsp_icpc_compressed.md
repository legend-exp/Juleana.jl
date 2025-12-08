# dsp_icpc_compressed

Digital Signal Processing for HPGe (ICPC) detectors with compressed waveform readout.

| Property | Value |
|----------|-------|
| **Source** | `LegendDSP.jl/src/dsp_icpc.jl` |
| **Package** | `LegendDSP.jl` |
| **Input** | Compressed raw waveforms (presummed + windowed) |
| **Output** | TypedTables.Table with ~50 DSP parameters |

---

# 1 Function Signature

```julia
function dsp_icpc_compressed(
    data::Q, 
    config::DSPConfig, 
    τ::Quantity{T}, 
    pars_filter::PropDict; 
    f_evaluate_qc::Union{Function, Missing}=missing
) where {Q <: Table, T<:Real}
```

---

# 2 Input Parameters

<details>
<summary><b>2.1 data (Raw Table)</b></summary>

| Column | Type | Description |
|--------|------|-------------|
| `waveform_presummed` | ArrayOfRDWaveforms | Presummed waveform (16 samples averaged) |
| `waveform_windowed` | ArrayOfRDWaveforms | High-resolution window around trigger |
| `presum_rate` | Vector | Presum rate (typically 16) |
| `baseline` | Vector | Baseline from FlashCam |
| `timestamp` | Vector | Timestamp from DAQ |
| `eventnumber` | Vector | Event number |
| `daqenergy` | Vector | Energy from FlashCam |
| `t_sat_lo` | Vector | Time of low saturation |
| `t_sat_hi` | Vector | Time of high saturation |
| `deadtime` | Vector | Deadtime |

</details>

<details>
<summary><b>2.2 config (DSPConfig)</b></summary>

| Parameter | Type | Description |
|-----------|------|-------------|
| `bl_window` | Interval | Baseline window (e.g., 0..2us) |
| `t0_threshold` | Float | Threshold for t0 detection |
| `tail_window` | Interval | Tail window for decay time extraction |
| `inTraceCut_std_threshold` | Float | Threshold for pile-up detection |
| `sg_flt_degree` | Int | Savitzky-Golay polynomial degree |
| `current_window` | Interval | Window for current maximum search |
| `qdrift_int_length` | Quantity | Integration length for Q-drift |
| `lq_int_length` | Quantity | Integration length for LQ |
| `flt_length_zac` | Quantity | ZAC filter length |
| `flt_length_cusp` | Quantity | CUSP filter length |
| `kwargs_pars.*` | Various | Additional parameters (fc_bit_depth, mintot, etc.) |

</details>

<details>
<summary><b>2.3 τ (Decay Time)</b></summary>

| Parameter | Type | Example | Description |
|-----------|------|---------|-------------|
| `τ` | `Quantity{T}` | `460.0u"μs"` | Detector decay time for pole-zero correction |

Source: `l200.par.rpars.pz(filekey)[det].τ`

</details>

<details>
<summary><b>2.4 pars_filter (Filter Optimization)</b></summary>

| Key | Subkeys | Description |
|-----|---------|-------------|
| `trap` | `rt`, `ft` | Trapezoidal filter rise time, flat-top |
| `cusp` | `rt`, `ft` | CUSP filter rise time, flat-top |
| `zac` | `rt`, `ft` | ZAC filter rise time, flat-top |
| `sg` | `wl` | Savitzky-Golay window length |

Source: Merged from `fltopt` and `aoeopt` parameters

</details>

---

# 3 Processing Pipeline

<details>
<summary><b>Stage 1: Data Extraction & Decoding</b></summary>

```julia
wvfs_pre = decode_data(data.waveform_presummed)
wvfs_wdw = decode_data(data.waveform_windowed)
```

Decodes compressed waveform data into RDWaveform arrays.

</details>

<details>
<summary><b>Stage 2: Saturation Detection</b></summary>

```julia
sat_stats = saturation.(wvfs_pre, sat_low, sat_high)
```

<details>
<summary>Sub-Function: <code>saturation()</code></summary>

**Source:** `LegendDSP.jl/src/dsp_routines.jl`

**Purpose:** Count samples at ADC saturation limits

**Input:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `wvf` | RDWaveform | Input waveform |
| `sat_low` | Int | Low saturation threshold (0) |
| `sat_high` | Int | High saturation threshold (2^14 - 14) * presum_rate |

**Output:**
| Field | Type | Description |
|-------|------|-------------|
| `.low` | Int | Number of samples at low saturation |
| `.high` | Int | Number of samples at high saturation |
| `.max_cons_low` | Int | Max consecutive samples at low |
| `.max_cons_high` | Int | Max consecutive samples at high |

</details>

</details>

<details>
<summary><b>Stage 3: Baseline Extraction</b></summary>

```julia
bl_stats = signalstats.(wvfs_pre, leftendpoint(bl_window), rightendpoint(bl_window))
wvfs_pre = shift_waveform.(wvfs_pre, -bl_stats.mean)
wvfs_wdw = shift_waveform.(wvfs_wdw, -bl_stats.mean ./ presum_rate_value)
```

<details>
<summary>Sub-Function: <code>signalstats()</code></summary>

**Source:** `RadiationDetectorDSP.jl/src/signalstats.jl`

**Purpose:** Calculate signal statistics in a window

**Input:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `wvf` | RDWaveform | Input waveform |
| `start` | Quantity | Window start time |
| `stop` | Quantity | Window end time |

**Output:**
| Field | Type | Description |
|-------|------|-------------|
| `.mean` | Float | Mean value in window |
| `.sigma` | Float | Standard deviation |
| `.slope` | Float | Linear slope (from fit) |
| `.offset` | Float | Linear offset (from fit) |

**Algorithm:**
1. Select samples within [start, stop] window
2. Calculate mean and standard deviation
3. Perform linear fit: `y = slope * x + offset`

</details>

<details>
<summary>Sub-Function: <code>shift_waveform()</code></summary>

**Source:** `LegendDSP.jl/src/dsp_routines.jl`

**Purpose:** Subtract baseline from waveform

**Input:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `wvf` | RDWaveform | Input waveform |
| `offset` | Float | Value to subtract |

**Output:** RDWaveform with shifted signal

</details>

</details>

<details>
<summary><b>Stage 4: Quality Classification (optional)</b></summary>

```julia
qc_labels = if !ismissing(f_evaluate_qc)
    get_qc_classifier_compressed(wvfs_pre, f_evaluate_qc)
else
    zeros(length(wvfs_pre))
end
```

<details>
<summary>Sub-Function: <code>get_qc_classifier_compressed()</code></summary>

**Source:** `LegendDSP.jl/src/ml_routines.jl`

**Purpose:** ML-based waveform quality classification

**Input:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `wvfs` | Vector{RDWaveform} | Input waveforms |
| `f_evaluate` | Function | Trained classifier function |

**Output:** Vector{Int} with labels (0=good, 1=bad)

</details>

</details>

<details>
<summary><b>Stage 5: Decay Time Extraction (before PZ)</b></summary>

```julia
tail_stats = tailstats.(wvfs_pre, leftendpoint(tail_window), rightendpoint(tail_window))
```

<details>
<summary>Sub-Function: <code>tailstats()</code></summary>

**Source:** `LegendDSP.jl/src/dsp_routines.jl`

**Purpose:** Extract decay time from waveform tail

**Input:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `wvf` | RDWaveform | Input waveform (before PZ correction) |
| `start` | Quantity | Tail window start |
| `stop` | Quantity | Tail window end |

**Output:**
| Field | Type | Description |
|-------|------|-------------|
| `.τ` | Float | Extracted decay time |
| `.mean` | Float | Tail mean |
| `.sigma` | Float | Tail sigma |

**Algorithm:**
1. Select tail samples in window
2. Fit exponential decay: `y = A * exp(-t/τ)`
3. Extract τ from fit

</details>

</details>

<details>
<summary><b>Stage 6: Pole-Zero Correction</b></summary>

```julia
deconv_flt = InvCRFilter(τ)
wvfs_pre = deconv_flt.(wvfs_pre)
wvfs_wdw = deconv_flt.(wvfs_wdw)
```

<details>
<summary>Sub-Function: <code>InvCRFilter()</code></summary>

**Source:** `RadiationDetectorDSP.jl/src/first_order_iir.jl`

**Purpose:** Pole-zero correction (deconvolution of preamplifier response)

**Input:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `τ` | Quantity | Decay time constant |

**Algorithm:**
Applies inverse CR filter: $y[n] = x[n] + \frac{\Delta t}{\tau} \cdot y[n-1]$

**Effect:** Converts exponentially decaying tail to flat plateau

</details>

</details>

<details>
<summary><b>Stage 7: Timing Extraction</b></summary>

```julia
t0 = get_t0(wvfs_wdw, t0_threshold; flt_pars=config.kwargs_pars.t0_flt_pars, mintot=config.kwargs_pars.t0_mintot)
t10 = get_threshold(wvfs_wdw, wvf_max_wdw .* 0.1; mintot=config.kwargs_pars.tx_mintot)
t50 = get_threshold(wvfs_wdw, wvf_max_wdw .* 0.5; mintot=config.kwargs_pars.tx_mintot)
# ... t80, t90, t99
```

<details>
<summary>Sub-Function: <code>get_t0()</code></summary>

**Source:** `LegendDSP.jl/src/dsp_routines.jl`

**Purpose:** Detect signal onset time

**Input:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `wvfs` | Vector{RDWaveform} | Input waveforms |
| `threshold` | Float | Detection threshold |
| `flt_pars` | NamedTuple | Filter parameters for smoothing |
| `mintot` | Quantity | Minimum time-over-threshold |

**Output:** Vector{Quantity} with t0 times

**Algorithm:**
1. Apply smoothing filter (optional)
2. Find first sample above threshold
3. Interpolate to find exact crossing time
4. Validate with minimum time-over-threshold

</details>

<details>
<summary>Sub-Function: <code>get_threshold()</code></summary>

**Source:** `LegendDSP.jl/src/dsp_routines.jl`

**Purpose:** Find time when waveform crosses threshold

**Input:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `wvfs` | Vector{RDWaveform} | Input waveforms |
| `thresholds` | Vector{Float} | Threshold values (per waveform) |
| `mintot` | Quantity | Minimum time-over-threshold |

**Output:** Vector{Quantity} with crossing times

</details>

</details>

<details>
<summary><b>Stage 8: Pulse Shape Parameters</b></summary>

```julia
qdrift = get_qdrift(wvfs_wdw, t0, qdrift_int_length; ...)
lq = get_qdrift(wvfs_wdw, t80, lq_int_length; ...)
```

<details>
<summary>Sub-Function: <code>get_qdrift()</code></summary>

**Source:** `LegendDSP.jl/src/dsp_routines.jl`

**Purpose:** Calculate charge in drift region (Q-drift) or late charge (LQ)

**Input:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `wvfs` | Vector{RDWaveform} | Input waveforms |
| `t_start` | Vector{Quantity} | Integration start times |
| `int_length` | Quantity | Integration length |

**Output:** Vector{Float} with integrated charge

**Physics:**
- Q-drift: Integral from t0, sensitive to charge collection
- LQ: Integral from t80, sensitive to surface events

</details>

</details>

<details>
<summary><b>Stage 9: Energy Reconstruction (Robust)</b></summary>

```julia
uflt_10410 = TrapezoidalChargeFilter(10u"µs", 4u"µs")
e_10410 = maximum.((uflt_10410.(wvfs_pre)).signal)
```

<details>
<summary>Sub-Function: <code>TrapezoidalChargeFilter()</code></summary>

**Source:** `RadiationDetectorDSP.jl/src/trapezoidal_filter.jl`

**Purpose:** Trapezoidal shaping filter for energy measurement

**Input:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `avgtime` | Quantity | Rise time (averaging time) |
| `gaptime` | Quantity | Flat-top time (gap time) |

**Algorithm:**
Moving average difference: $y[n] = \frac{1}{L} \sum_{i=0}^{L-1} x[n-i] - \frac{1}{L} \sum_{i=0}^{L-1} x[n-L-G-i]$

Where L = rise time samples, G = flat-top samples

**Variants in dsp_icpc_compressed:**
| Name | Rise Time | Flat-Top | Purpose |
|------|-----------|----------|---------|
| `e_10410` | 10 µs | 4 µs | Long shaping, best resolution |
| `e_535` | 5 µs | 3 µs | Medium shaping |
| `e_313` | 3 µs | 1 µs | Short shaping, pile-up tolerant |

</details>

</details>

<details>
<summary><b>Stage 10: Energy Reconstruction (Optimized)</b></summary>

```julia
uflt_trap_rtft = TrapezoidalChargeFilter(trap_rt, trap_ft)
e_trap = signal_estimator.(uflt_trap_rtft.(wvfs_pre), t50_pre .+ (trap_rt + trap_ft/2))
```

<details>
<summary>Sub-Function: <code>CUSPChargeFilter()</code></summary>

**Source:** `RadiationDetectorDSP.jl/src/cusp_filter.jl`

**Purpose:** CUSP (Cusp-like) shaping filter

**Input:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `rt` | Quantity | Rise time |
| `ft` | Quantity | Flat-top time |
| `τ` | Quantity | Time constant (set very high to disable CR) |
| `length` | Quantity | Total filter length |
| `scale` | Float | Normalization scale |

</details>

<details>
<summary>Sub-Function: <code>ZACChargeFilter()</code></summary>

**Source:** `RadiationDetectorDSP.jl/src/zac_filter.jl`

**Purpose:** ZAC (Zero Area Cusp) shaping filter

**Input:** Same as CUSPChargeFilter

**Advantage:** Better baseline restoration due to zero-area constraint

</details>

<details>
<summary>Sub-Function: <code>SignalEstimator()</code></summary>

**Source:** `RadiationDetectorDSP.jl/src/signal_estimator.jl`

**Purpose:** Precise amplitude estimation at specific time

**Input:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `wvf` | RDWaveform | Filtered waveform |
| `t` | Quantity | Evaluation time |

**Algorithm:** Polynomial interpolation around t for sub-sample precision

</details>

</details>

<details>
<summary><b>Stage 11: Current Extraction (A/E)</b></summary>

```julia
a_sg = get_wvf_maximum.(SavitzkyGolayFilter(sg_wl, sg_flt_degree, 1).(wvfs_wdw), ...)
```

<details>
<summary>Sub-Function: <code>SavitzkyGolayFilter()</code></summary>

**Source:** `RadiationDetectorDSP.jl/src/sg_filter.jl`

**Purpose:** Smoothed derivative for current extraction

**Input:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `wl` | Quantity | Window length |
| `degree` | Int | Polynomial degree (typically 2) |
| `derivative` | Int | Derivative order (1 for current) |

**Physics:** 
Current signal A = dV/dt, proportional to charge drift velocity.
A/E ratio discriminates single-site (SSE) vs multi-site (MSE) events.

</details>

<details>
<summary>Sub-Function: <code>get_wvf_maximum()</code></summary>

**Source:** `LegendDSP.jl/src/dsp_routines.jl`

**Purpose:** Find maximum in time window

**Input:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `wvf` | RDWaveform | Input waveform |
| `start` | Quantity | Window start |
| `stop` | Quantity | Window end |

**Output:** Maximum value in window

</details>

</details>

<details>
<summary><b>Stage 12: Pile-up Detection</b></summary>

```julia
inTrace_pileUp = get_intracePileUp(wvfs_sgflt_deriv, inTraceCut_std_threshold, bl_window; ...)
```

<details>
<summary>Sub-Function: <code>get_intracePileUp()</code></summary>

**Source:** `LegendDSP.jl/src/dsp_routines.jl`

**Purpose:** Detect in-trace pile-up events

**Input:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `wvfs` | Vector{RDWaveform} | Derivative waveforms |
| `threshold` | Float | Detection threshold (in sigma) |
| `bl_window` | Interval | Baseline window for noise estimation |

**Output:**
| Field | Type | Description |
|-------|------|-------------|
| `.intersect` | Vector{Quantity} | Position of pile-up |
| `.n` | Vector{Int} | Multiplicity |

</details>

</details>

<details>
<summary><b>Stage 13: DC Tagging (Inverted Waveform)</b></summary>

```julia
wvfs_pre = multiply_waveform.(wvfs_pre, -1.0)
e_10410_max_inv = maximum.(uflt_10410.(wvfs_pre).signal)
t0_inv = get_t0(wvfs_wdw, t0_threshold; ...)
```

**Purpose:** Detect delayed charge (DC) events by analyzing inverted waveform.

DC events have negative-going signals before the main pulse due to charge trapping.

</details>

---

# 4 Output Table

See [process_dsp_phy.md](../processor_flow/process_dsp_phy.md#311-hpge-dsp_icpc_compressed) for complete output column documentation.
