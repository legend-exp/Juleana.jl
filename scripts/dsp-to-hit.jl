ENV["LEGEND_DATA_CONFIG"] = "/home/iwsatlas1/henkes/l200/auto/config.json"
using LegendDataManagement
using TypedTables
using PropertyFunctions
using LegendHDF5IO
using LegendDataTypes: fast_flatten
using Dates, Unitful
using Plots, UnitfulRecipes, Measures, Formatting
using RadiationDetectorDSP, LegendDSP
using ArraysOfArrays, RadiationDetectorSignals
using LegendSpecFits
using StructArrays
using StatsBase
using RadiationSpectra

l200 = LegendData(:l200)

period = DataPeriod(3)
run = DataRun(0)

filekeys = sort(search_disk(FileKey, l200.tier[:dsp, :phy, period, run]), by = x-> x.time)

chinfo = channel_info(l200, filekeys[1])
chinfo = channel_info(l200, filekeys[1]) |> filterby(@pf $system == :spms && $processable) # && $usability == :on)

det = :S012
i = findfirst(chinfo.detector .== det)
ch_short = chinfo.channel[i]
ch = "ch$ch_short"

ch_filekeys = Vector{FileKey}()
for fk in filekeys
    if !isfile(l200.tier[:dsp, fk])
        @warn "File $(basename(l200.tier[:dsp, fk])) does not exist, skip"
        continue
    end
    if !haskey(LHDataStore(l200.tier[:dsp, fk], "r"), ch)
        @warn "Channel $ch not found in $(basename(l200.tier[:dsp, fk])), skip"
        continue
    end
    push!(ch_filekeys, fk)
end


data_ch = fast_flatten([
            LHDataStore(
                ds -> begin
                    @debug "Reading from \"$(ds.data_store.filename)\""
                    ds[ch][:]
                end,
                l200.tier[:dsp, fk]
            ) for fk in ch_filekeys
        ])

    
out_table = data_ch

# make discharge flags
filtered_table = filter(row -> length(row.trig_pos_DC) > 0, out_table)
wf_has_DC = map(row -> length(row.trig_pos_DC) > 0, out_table)

is_DC = map(row -> [any(abs.(row.trig_pos_DC .- pos) .< 100u"ns") for pos in row.trig_pos], out_table)


using JSON
# calibrate maxes
cal_vals = JSON.parsefile("calib_params.json")

name = "$det"
m = cal_vals[name]["m"]
a = cal_vals[name]["a"]

trig_max_cal = map(row -> row.trig_max .*m .-a, out_table)

# make new table
hit_table = Table(timestamp = out_table.timestamp, trig_pos = out_table.trig_pos, trig_max_cal = trig_max_cal,
                is_DC = is_DC, wf_has_DC = wf_has_DC)


# plot pe spectrum

calib_table_noDC = filter(row -> row.wf_has_DC==false, hit_table)

function sum_max_within_range(row::NamedTuple)
    x = row.trig_pos
    max = row.trig_max_cal
    if isempty(x)
        return 0.0 # 0 p.e. for no peaks
    end
    
    t_start = 47000.0f0 * u"ns"
    t_end = 53000.0f0 * u"ns"
    
    # Calculate the sum of max values within the range
    total_max = sum((t_start .<= x .<= t_end) .* max)
    
    return total_max
end


sums = Float64[]

for row in calib_table_noDC
    push!(sums, sum_max_within_range(row))
end

# plot spectrum
hist = histogram(sums, bins=0.:.01:5., yscale = :log10)
