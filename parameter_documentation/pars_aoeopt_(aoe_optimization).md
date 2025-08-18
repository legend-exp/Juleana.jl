# aoeopt (A/E optimization) run parameters — schema and field descriptions

Purpose: Document the structure and semantics of the A/E optimization (aoeopt) run parameters saved under rpars. These parameters are produced by `process_aoe_optimization` and used for A/E pulse-shape discrimination per detector.

---

## Location

- Path per run: `.../legend_data_production/jl-v0.5.0/generated/jlpar/rpars/aoeopt/p<period>/r<run>.yaml`
- Scope: One YAML file per run, with one top-level entry per detector (detector ID as key). Each detector contains entries for the A/E filter types optimized (e.g., `sg`).

---

## Field descriptions

### Level 1: Detectors (top-level keys)
- **String**: Detector IDs (e.g., `V02166B`, `B00035B`, `P00664A`)
- **Meaning**: Groups A/E optimization results for that detector

### Level 2: Filter types (detector sub-keys)
- **Filter Types**: `sg`, `100`, `raw` (current amplitude estimation methods)
- **Meaning**: Different A/E filter variants optimized for this detector

#### Current Amplitude Estimation Methods (from AOE documentation):
- **`sg`**: **Savitzky-Golay filter** with optimized window length (30-350ns, 32ns steps)
- **`100`**: **Fixed 100ns Savitzky-Golay filter** (3rd order, constant length)
- **`raw`**: **Raw current estimation** (numerical derivative without further filtering)

#### Physical Meaning and Optimization Process:
- **Purpose**: Find optimal filter window length to **maximize Single-Site Event acceptance** while **rejecting Multi-Site Events**
- **Method**: **DEP vs. SEP discrimination** using 2039 keV ²²⁸Th calibration data
- **DEP (Double Escape Peak)**: High-purity Single-Site Events (signal-like)
- **SEP (Single Escape Peak)**: Multi-Site Events from pair production (background-like)
- **Optimization Goal**: Maximize SEP survival fraction at fixed DEP rejection level
- **Window Length Range**: Typically 30-350ns in 32ns steps for SG filter

### Level 3: Optimization results (filter sub-keys)

#### 3.1: `wl` (Window Length)
- **Purpose**: Optimal A/E filter window length from optimization
- **Type**: Object with unit, value, and uncertainty

#### 3.2: `sf` (Survival Fraction) 
- **Purpose**: SEP survival fraction at the optimized working point
- **Type**: Object with unit, value, and uncertainty (if available)

#### 3.3: `n_dep` (DEP Event Count)
- **Purpose**: Number of DEP events used in optimization after QC
- **Type**: Integer - for statistical robustness assessment

#### 3.4: `n_sep` (SEP Event Count)
- **Purpose**: Number of SEP events used in optimization after QC  
- **Type**: Integer - for statistical robustness assessment

### Level 4: Detailed field content

#### 4.1: Window length structure (`wl`)
- **`unit`**: String - Unit of window length ("ns", "samples", or "μs")
- **`val`**: Float - Optimal window length value from optimization
- **`err`**: Float - Uncertainty from optimization routine (typically step size)

#### 4.2: Survival fraction structure (`sf`)
- **`unit`**: String - Always "percent" 
- **`val`**: Float - SEP survival fraction at optimized DEP working point
- **`err`**: Float|null - Uncertainty if available from fit procedure

#### 4.3: Event counting (n_dep, n_sep)
- **Type**: Integer values
- **Purpose**: Statistical robustness indicators
- **Usage**: Low counts warn of unstable optimization results

---

## Provenance and generation

- Producer: `process_aoe_optimization` processor.
- Inputs: jlpeaks waveforms and energies for DEP and SEP peaks; detector RT/FT from `rpars/fltopt`; decay time τ from `rpars/pz`; QC mask (optional ML).
- Steps: For each candidate window length, compute A/E vs energy for DEP/SEP → find DEP cut and SEP survival fraction → choose window length maximizing SEP survival → persist `wl`, `sf`, and counts.

---

## Usage guidance

- Use `wl.val` to configure the A/E filter for this detector and filter type.
- Compare `sf.val` across detectors to monitor expected PSD performance; low counts (`n_dep`, `n_sep`) warn of unstable optimization.

---

## Example Structure

```yaml
V02166B:
  # Savitzky-Golay filter optimization results
  sg:
    wl: { unit: "ns", val: 190.0, err: 32.0 }                    # Optimal window length
    sf: { unit: "percent", val: 5.825494531889814, err: null }  # SEP survival fraction
    n_dep: 11750                                                 # DEP events used
    n_sep: 10601                                                 # SEP events used

B00035B:
  # Different detector with shorter optimal window
  sg:
    wl: { unit: "ns", val: 94.0, err: 32.0 }                    # Shorter optimal window
    sf: { unit: "percent", val: 7.334654252931445, err: null }  # Higher SEP survival
    n_dep: 9841                                                  # DEP events used  
    n_sep: 7687                                                  # SEP events used

V01240A:
  # Detector with longer optimal window
  sg:
    wl: { unit: "ns", val: 286.0, err: 32.0 }                   # Longer optimal window
    sf: { unit: "percent", val: 12.385670999551419, err: null } # Highest SEP survival
    n_dep: 16791                                                 # More DEP events
    n_sep: 15779                                                 # More SEP events

# Example with multiple filter types (if available)
V02166B:
  sg:
    wl: { unit: "ns", val: 190.0, err: 32.0 }
    sf: { unit: "percent", val: 5.8, err: null }
    n_dep: 11750
    n_sep: 10601
  
  # Fixed 100ns filter would have no window optimization
  100:
    wl: { unit: "ns", val: 100.0, err: 0.0 }                    # Fixed length
    sf: { unit: "percent", val: 4.2, err: null }                # Different performance
    n_dep: 11750                                                 # Same event counts
    n_sep: 10601
  
  # Raw filter has no filtering window  
  raw:
    wl: { unit: "ns", val: 0.0, err: 0.0 }                      # No window
    sf: { unit: "percent", val: 3.1, err: null }                # Typically worst performance
    n_dep: 11750
    n_sep: 10601

# Detector with insufficient statistics
V09724A: {}                                                      # Empty - optimization failed
```

### Optimization Results Interpretation:

- **Window Length Trends**: 
  - **Shorter windows** (94ns): Better noise rejection, potentially lower resolution
  - **Longer windows** (286ns): Better signal resolution, potentially more noise
  - **Optimal range**: Typically 30-350ns for SG filter

- **SEP Survival Fraction**:
  - **Lower values** (5.8%): Better MSE rejection, stricter PSD
  - **Higher values** (12.4%): More signal acceptance, looser PSD
  - **Detector dependence**: Varies by detector geometry and performance

- **Event Statistics**:
  - **High counts** (>15000): Robust optimization
  - **Low counts** (<5000): Potentially unstable results
  - **Empty entries**: Optimization failed due to insufficient statistics
