using LegendDataManagement, PropertyFunctions, TypedTables, PropDicts
using Unitful, Formatting, LaTeXStrings, Measures
using Plots, StatsBase
using LegendHDF5IO, LegendDSP, LegendSpecFits
using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked

using RadiationDetectorDSP

ENV["JULIA_DEBUG"] = Main # enable debug

gr()
# plotlyjs(size=(800, 500))
plotlyjs(size=(800, 500))

@info "Loading Legend MetaData"
l200 = LegendData(:l200)

period = DataPeriod(3)
run    = DataRun(1)
reprocess = true

#Search for all data periods available 
# search_disk(DataPeriod,l200.tier[:raw, :cal])

@info "SiPM DSP for period $period and run $run"

#Search for files for period and run specified, time ordered
#   :cal => Calibration data (no SiPM data)
#   :phy => Physics data 
filekeys = sort(search_disk(FileKey, l200.tier[:raw, :phy, period, run]), by = x-> x.time)
#First file in time period 
filekey = filekeys[1]
#Find channel info from filekey
#Filter using $system 
#   :geds => HPGe detectors 
#   :spms => SiPM detectors 
chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :spms && $processable && $usability == :on)

#Print table of channels 
Table(chinfo)

#Select detector channel number (from table)
det = :S050
#Find channel position in table
i = findfirst(chinfo.detector .== det)
ch_short = chinfo.channel[i]
#Define channel key for retriving waveforms 
ch = "ch$ch_short"

#Retrieve data for :raw, from filekey 1, for only channel ch
#   [:] => Takes all the events 
data_ch = LHDataStore(l200.tier[:raw, filekeys[1]])["$ch/raw"][:]

#Get all waveforms from data 
wvfs = data_ch.waveform

plot(wvfs[11:20])
plot(wvfs[20])

#Shift waveform by 0 so filters will work
wvfs = shift_waveform.(wvfs, 0.0)

#Create Savitzky-Golay filter 
#   100u"ns" => Define length 
#   2 => Define polynomial order 
#   1 or 0   => Derivative (1) or no Derivative (0)
sgflt = SavitzkyGolayFilter(100u"ns", 2, 1)
wvfs_sgflt = sgflt.(wvfs)
plot(wvfs_sgflt[1:10])

plot(wvfs_sgflt[11:20])
plot(wvfs_sgflt[20])
plot(wvfs[6])
plot(wvfs_sgflt[6])

int_max = IntersectMaximum(mintot=40.0u"ns", maxtot=100.0u"ns")
inters = int_max.(wvfs_sgflt, 5.0)

plot(wvfs_sgflt[6])
vline!(inters[6].x, lw=1.5, color=:red)
hline!(inters[6].max, lw=1.5, color=:green)


plot(wvfs[6])
vline!(inters[6].x, lw=1.5, color=:red)

cut_select = [any(inters[i].max .< 0.0) for i in eachindex(inters)]
count(cut_select)

plot(wvfs_sgflt[cut_select][1])
plot(wvfs[cut_select][1])
vline!([inters.x[cut_select][1]])
hline!([inters.max[cut_select][1]])

inters[20]
vline!(inters[20].x, lw=3, color=:red)
hline!(inters[20].max, lw=3, color=:red)
#Run intersect filter 
#   mintot => Minimum time it must be above threshold
intflt = Intersect(mintot=20u"ns")
#Returns first intersection in waveform 
inters = intflt.(wvfs_sgflt,5.0)
inters[inters.multiplicity .== 2]
inters.x

vline!(inters.x[1:10])