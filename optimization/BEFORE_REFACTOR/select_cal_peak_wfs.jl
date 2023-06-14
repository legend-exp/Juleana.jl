using LegendDataTypes
using HDF5, LegendHDF5IO
using LegendSpecFits
using IntervalSets, Unitful
using Printf
using Glob
using Plots

using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked


function get_all_daqenergies(filelist::AbstractVector{<:AbstractString}, channels::AbstractVector{<:Integer})
    flatten_by_key([
        LHDataStore(
            ds -> IdDict(ch => get_daqenergy(ds, ch) for ch in channels), filename
        ) for filename in filelist
    ])
end



#@time begin

channels = chname2int.(["ch007", "ch066", "ch103", "ch106", "ch032", "ch008", "ch101", "ch068", "ch010", "ch034", "ch005", "ch043", "ch064", "ch088", "ch013", "ch086", "ch118", "ch097", "ch082", "ch065", "ch020", "ch092", "ch044", "ch055", "ch018", "ch089", "ch069", "ch111", "ch091", "ch063", "ch098", "ch104", "ch037", "ch031", "ch060", "ch096", "ch072", "ch070", "ch006", "ch042", "ch057", "ch093", "ch053", "ch102", "ch067", "ch030", "ch083", "ch054", "ch004", "ch024", "ch041", "ch039", "ch074", "ch110", "ch114", "ch012", "ch009", "ch076", "ch019", "ch040", "ch100", "ch113", "ch099", "ch035", "ch081", "ch071", "ch115", "ch107", "ch022", "ch045", "ch073", "ch062", "ch056", "ch109", "ch036", "ch095", "ch021", "ch038", "ch061", "ch087", "ch090", "ch049", "ch025", "ch023", "ch075"])

datadir = joinpath(ENV["LEGEND_DATA"], "l200/raw/cal/p02/r006")
filelist = sort(glob("*.lh5", datadir))

# th228_lines = [583.191, 727.330, 860.564, 1592.53, 1620.50, 2103.53, 2614.50]

energy_windows = IdDict(
    :Tl208b => 558u"keV"..608u"keV",
    :BI212a => 702u"keV"..752u"keV",
    :Tl208dFEP => 836u"keV"..886u"keV",
    :Tl208aDEP_Bi212b => 1568u"keV"..1646u"keV",
    :Tl208aSEP => 2079u"keV"..2129u"keV",
    :Tl208a => 2590u"keV"..2640u"keV"
)

filelist = filelist[3:3]

# channels = LHDataStore(get_all_channels, first(filelist))
daq_energies = get_all_daqenergies(filelist, channels)
calib_funcs = IdDict(((k, autocal_energy(v).result) for (k,v) in daq_energies))


slim_data = flatten_by_key([
    LHDataStore(filename) do ds
        filter_raw_data_by_energy(ds, calib_funcs, energy_windows)
    end for filename in filelist
])

#end #time


ch = channels[3]
stephist(calib_funcs[ch].(slim_data[ch].daqenergy), nbins = 1000)


#=
# Huge output (HDF5 block size set too large?):
LHDataStore("out.lh5", "w") do output
    for ch in channels
        output[int2chname(ch)] = slim_data[ch]
    end
end
=#

# Use LegendDataTypes.writedata instead of LHDataStore for output for now:

@time h5open("out.lh5", "w") do output
    for ch in channels
        LegendDataTypes.writedata(output, int2chname(ch), slim_data[ch])
    end
end
