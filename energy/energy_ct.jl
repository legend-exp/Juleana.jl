using LegendDataManagement, PropertyFunctions, TypedTables, PropDicts
using Unitful, Formatting, LaTeXStrings, Measures
using Plots, StatsBase
using LegendHDF5IO, LegendDSP, LegendSpecFits
using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked

ENV["JULIA_DEBUG"] = Main # enable debug

gr(size=(1200, 800))
# plotlyjs(size=(1200, 800))

@info "Loading Legend MetaData"
l200 = LegendData(:l200)

period = DataPeriod(3)
run    = DataRun(1)



@info "Energy calibration for period $period and run $run"

filekeys = sort(search_disk(FileKey, l200.tier[:raw, :cal, period, run]), by = x-> x.time)
filekey = filekeys[1]
@info "Found filekey $filekey"

chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable)

sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)

@debug "Create Hit folder"
hit_folder = l200.tier[:hit, :cal, period, run]
ifelse(isdir(hit_folder), @debug("Hit folder $hit_folder already exists"), mkpath(hit_folder))

@debug "Create figures folder"
figures_folder = joinpath(l200.tier[:plt, :cal, period, run], "energy")
ifelse(isdir(figures_folder), @debug("Figure folder $figures_folder already exists"), mkpath(figures_folder))

for str in unique(chinfo.string)
    figures_folder_string = joinpath(figures_folder, format("string{:02d}", str))
    ifelse(isdir(figures_folder_string), @debug("String Figure folder $figures_folder_string already exists"), mkpath(figures_folder_string))
end

@debug "Create pars folder"
pars_folder = joinpath(l200.tier[:par, :cal, period, run], "energy")
ifelse(isdir(pars_folder), @debug("Pars folder $pars_folder already exists"), mkpath(pars_folder))

@debug "Create pars db"
pars_db = PropDict()

# for (i, ch_short) in enumerate(chinfo.channel)

i = 67
# i = 20
# det = :V09372A
# findfirst(x -> x == det, chinfo.detector)
ch_short = chinfo.channel[i]
ch = format("ch{}", ch_short)
string_number = chinfo.string[i]
det = chinfo.detector[i]

figures_folder_string = joinpath(figures_folder, format("string{:02d}", string_number))

@debug "Processing channel $ch ($det)"

filename = joinpath(l200.tier[:qc, :cal, period, run], format("{}-{}-{}-{}-{}-tier_qc.lh5", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch))

if !isfile(filename)
    @warn "File $(basename(filename)) does not exist, skip"
end

data = LHDataStore(filename, "r")

@debug "Loading data from $(basename(filename))"
dsp_data = data["$ch/after_qc"][:]

close(data)

if length(dsp_data) < 50000
    @warn "Not enough data points for channel $ch, skip"
end

if haskey(l200.metadata.dataprod.config.cal.energy(sel), det)
    energy_config = l200.metadata.dataprod.config.cal.energy(sel)[det]
    @debug "Use config for detector $det"
else
    energy_config = l200.metadata.dataprod.config.cal.energy(sel).default
    @debug "Use default config"
end

th228_lines = Vector{Float64}(energy_config.th228_lines)
th228_names = Symbol.(energy_config.th228_names)
window_sizes = Vector{Float64}(energy_config.window_sizes)
n_bins = energy_config.n_bins
quantile_perc = energy_config.quantile_perc

# get detector pars
pars_det  = pars_db[det]

@debug "Get simple calibration"

result_simple, report_simple = simple_calibration(dsp_data.e_trap, th228_lines, window_sizes, n_bins=n_bins, quantile_perc=quantile_perc, calib_type=:th228)
plot(report_simple, cal=true, title=format("{} Simple Calibration ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))

m_cal_simple = result_simple.c
savefig(joinpath(figures_folder_string, format("{}-{}-{}-{}-{}-simple_calibration.png", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch)))

e_simple = dsp_data.e_trap .* m_cal_simple
qdrift   = dsp_data.qdrift

fep, fep_window = 2614.5, 25.0

result_ctc, report_ctc = ctc_energy(e_simple, qdrift, fep, fep_window)
plot(report_ctc, plot_title=format("{} Charge Trapping Correction ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
