# process_peak_split.jl

**Purpose:** Split peak-specific event samples per channel. The processor (1) reads raw data (DAQ online energy, waveforms, timestamps), (2) automatically calibrates energy using Th-228 lines, (3) applies the calibration and filters events into configured energy windows (e.g., Tl-208 SEP/FEP), and (4) writes compact `jlpeaks` files for downstream processing. The goal is robust per-channel extraction of relevant events with diagnostic plots and clear logs for validation and debugging.

---

## Path Variables

```
$RAW_DATA_PATH = .../legend_data_production/raw_compressed
$METADATA_PATH = .../legend_data_production/jl-v0.5.0/legend-metadata_new_yaml_p14
$GENERATED_DATA_PATH = .../legend_data_production/jl-v0.5.0/generated
$JLPEAKS_PATH = .../legend_data_production/jlpeaks
$JLML_PATH = .../legend_data_production/jlml
```

---

## Inputs

**Raw Data:**
- **Path:** `$RAW_DATA_PATH/<period>/<run>/`
- **Data Keys:** `daqenergy`, `waveform` (presummed), `timestamp` (per channel/detector)

**Config:**
- **Path:** `$METADATA_PATH/jldataprod/config/raw/`
- **Parameters:** 
  - `th228_cal_lines`: Known Th-228 photopeak energies for calibration
  - `peaks`: Energy window definitions (e.g., `Tl208FEP: [2609, 2619]`)
  - `min_e`: Minimum energy for calibration 
  - `max_e`: Maximum energy for calibration
  - `max_e_binning_quantile`: Quantile cutoff for binning
  - `σ`: Peak width parameter for fitting
  - `threshold`: Peak detection threshold
  - `min_n_peaks`: Minimum number of peaks required
  - `max_n_peaks`: Maximum number of peaks allowed
  - `α`: Statistical significance level
  - `rtol`: Relative tolerance for fitting

---

## Functions

### 1. autocal_energy()
**Location:** `LegendSpecFits.jl/src/auto_calibration.jl:8-38`

**Parameters:**
```julia
autocal_energy(
    e::AbstractArray{<:Real}, 
    photon_lines::Vector{<:Unitful.Energy{<:Real}}; 
    mode::Symbol=:ratio, 
    min_e::Real=100, 
    max_e::Real=maximum(e), 
    max_e_binning_quantile::Real=0.5, 
    σ::Real=2.0, 
    threshold::Real=50.0, 
    min_n_peaks::Int=length(photon_lines), 
    max_n_peaks::Int=4*length(photon_lines), 
    α::Real=0.01, 
    rtol::Real=5e-3
)
```

**Returns:**
- `result::NamedTuple` with fields
  - `f_calib::Function`: calibration function mapping raw DAQ energy (ADC) to keV. Usage: `keV = f_calib(adc)` or vectorized `f_calib.(adc_vec)`.
  - `h_cal`: histogram object of the calibrated energy distribution (includes binning and counts; concrete type provided by the fitting/plotting stack).
  - `h_uncal`: histogram object of the uncalibrated DAQ distribution (ADC units).
  - `c`: calibration coefficients (e.g., offset/gain or polynomial coefficients) defining the form of `f_calib`.
  - `peak_positions::Vector{<:Real}`: fitted peak positions (in keV) corresponding to the provided reference lines; useful as a calibration quality indicator.
  - `threshold::Real`: detection threshold used for peak finding in the spectrum.
- `report`: diagnostic structure compatible with `LegendMakie.lplot(...)` to render calibration plots (includes spectra, reference line markers, and fit information).

**Purpose:** Create an automatic energy calibration by fitting known Th-228 photopeaks in the DAQ energy spectrum. Returns an ADC→keV mapping, histograms for un/calibrated spectra, fitted peak positions, the applied detection threshold, and a report structure for diagnostic plotting.

### 2. filter_raw_data_by_energy()
**Location:** `LegendDataTypes.jl/src/data_filters.jl:99-116`

**Parameters:**
```julia
filter_raw_data_by_energy(
    raw_data::TableLike, 
    calib_func::Function, 
    energy_windows::AbstractDict{Symbol,<:AbstractInterval{<:Number}}; 
    chunk_size=10000
)
```

**Returns:**
- `filtered_data::Dict{Symbol, TableLike}`: dictionary keyed by the `energy_windows` labels (e.g., `:Tl208a`, `:Bi212a`, `:Tl208b`, `:Tl208DEP_Bi212FEP`, `:Tl208SEP`, `:Tl208FEP`). Each value is a slim raw-event table including at least calibrated `daqenergy` and corresponding event fields (e.g., `waveform_windowed`, `waveform_presummed`, `timestamp`, depending on the raw table schema). Empty windows yield empty tables.

**Purpose:** Filter full raw events (including waveforms) in predefined energy windows around the peaks of interest (e.g., SEP/FEP) by applying the calibration function and selecting events within each window. Produces per-window slim event tables for downstream processors.

---

## Internal Functions

1) get_data_key_for_channel(ds, ch::ChannelIdLike, det::DetectorIdLike) — processors/process_peak_split.jl:L37-L47
- **Input:** `ds`, `ch`, `det`
- **Returns:** `String | nothing` (data key for channel access)
- **Purpose:** Resolves channel vs detector name conflicts in HDF5 files (tries channel ID first, then detector name).

2) get_daqenergy_for_ch(filelist::Vector{String}, ch::ChannelIdLike, det::DetectorIdLike) — processors/process_peak_split.jl:L49-L64
- **Input:** `filelist`, `ch`, `det`
- **Returns:** `Vector{<:Real}` — concatenated DAQ energies from all files
- **Purpose:** Loads and concatenates DAQ energy across multiple raw files for one channel.

3) channels_in_file(filename::String) — processors/process_peak_split.jl:L66-L70
- **Input:** `filename`
- **Returns:** `Vector{Int}` — sorted list of channel IDs in file
- **Purpose:** Discover available channels in a raw file.

4) check_filekey(fk::FileKey) — processors/process_peak_split.jl:L90-L131
- **Input:** `fk`
- **Returns:** `(result=Bool, timer::TimerOutput, log, processed=Bool)` — file validation results
- **Purpose:** Validate raw files are readable and contain expected channels (using key fallback).

5) split_peak_ch(chinfo_ch::NamedTuple) — processors/process_peak_split.jl:L150-L243
- **Input:** `chinfo_ch` with fields `channel`, `detector`; uses effective `raw_config_ch` and discovered `filelist`
- **Returns:** `(result, processed=Bool, log)` — processing results per channel; `result` commonly contains `(n_fep, n_sep)` counts
- **Purpose:** Main per-channel logic: run autocalibration, filter events by energy windows, write `jlpeaks`, log counts.

---

## Outputs

**Data Tier:**
- **Path:** `$JLPEAKS_PATH/cal/<period>/<run>/`
- **Files:** `l200-p14-r<run>-cal-<detector>.lh5` (per channel)
- **Structure:** `<detector>/jlpeaks/<peak_label>/` (e.g., `V08682A/jlpeaks/Tl208FEP/`)
  - **Saved peak labels:** taken from the raw config windows. Defaults include: `:Tl208a`, `:Bi212a`, `:Tl208b`, `:Tl208DEP_Bi212FEP`, `:Tl208SEP`, `:Tl208FEP`.

**Plots:**
- **Path:** `$GENERATED_DATA_PATH/jlplt/cal/<period>/<run>/`
- **Files:** `l200-p14-r<run>-<detector>-daq_energy.png` (calibrated energy spectra)
 - **Description:** The calibration plot shows the uncalibrated and/or calibrated energy spectrum, the fitted Th-228 reference lines, and diagnostic indicators. It is used to visually verify calibration quality (peak positions, resolution) and that configured windows cover the intended regions.

**Parameters:**
- **Path:** `$GENERATED_DATA_PATH/jlpar/`
- **Content:** None (this processor does not save calibration parameters)