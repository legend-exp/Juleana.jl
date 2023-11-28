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


l200 = LegendData(:l200)

period = DataPeriod(3)
run = DataRun(0)
search_disk(DataRun, l200.tier[:raw, :phy, period])
search_disk(DataPeriod, l200.tier[:raw, :phy])

filekeys = sort(search_disk(FileKey, l200.tier[:raw, :phy, period, run]), by = x-> x.time)

l200.tier[:raw, filekeys[1]]

chinfo = channel_info(l200, filekeys[1])
Table(chinfo)

chinfo = channel_info(l200, filekeys[1]) |> filterby(@pf $system == :spms && $processable) # && $usability == :on)

det = :S029
i = findfirst(chinfo.detector .== det)
ch_short = chinfo.channel[i]
ch = "ch$ch_short"

filename = l200.tier[:raw, filekeys[1]]
data = LHDataStore(filename, "r")["$ch/raw"][:]

wvfs = data.waveform
wvfs = shift_waveform.(wvfs, 0.0);
SAVITZ_WINDOW_LENGTH = 96u"ns"
sgflt_savitz = SavitzkyGolayFilter(SAVITZ_WINDOW_LENGTH, 2, 1) # savitzky golay filter: takes derivative of waveform plus smoothing
wvfs_sgflt_savitz = sgflt_savitz.(wvfs);

# get threshold
wvfs_bsl = vec(flatview(wvfs_sgflt_savitz.signal)); # project waveforms on the y-axis, histogram that and find fwhm of histogram
MIN_CUT_SAVITZ = -5.
MAX_CUT_SAVITZ = 10.
NBINS_SAVITZ = 100
REL_CUT_SAVITZ = 0.5
cuts_bsl = cut_single_peak(wvfs_bsl, MIN_CUT_SAVITZ, MAX_CUT_SAVITZ, NBINS_SAVITZ, REL_CUT_SAVITZ)
result, report = fit_single_trunc_gauss(wvfs_bsl, cuts_bsl) # fit gaussian
SIGMA_SAVITZ_OUT = result.σ
FRACTION_SIGMA_SAVITZ = 3.
threshold = SIGMA_SAVITZ_OUT*FRACTION_SIGMA_SAVITZ

# get threshold discharges
flt = IntegratorFilter(gain=1)
wvfs_der_int = flt.(wvfs_sgflt_savitz);
flipped_wf = copy(wvfs_der_int)
flipped_wf.signal .= -flipped_wf.signal;
MIN_CUT_DC = -10. # find maxima in these flipped waveforms
MAX_CUT_DC = 10.
NBINS_DC = 100
REL_CUT_DC = 0.5
wvfs_bsl_DC = vec(flatview(flipped_wf.signal))
cuts_bsl_DC = cut_single_peak(wvfs_bsl_DC, MIN_CUT_DC, MAX_CUT_DC, NBINS_DC, REL_CUT_DC)
result_DC, report_DC = fit_single_trunc_gauss(wvfs_bsl_DC, cuts_bsl_DC)
SIGMA_DC_OUT = result_DC.σ
FRACTION_SIGMA_DC_OUT = 3.
threshold_DC = SIGMA_DC_OUT*FRACTION_SIGMA_DC_OUT


out_table = TypedTables.Table(trig_pos = Vector{Vector{Float32}}[]*u"µs", trig_max = Vector{Float64}[])
out_table_NO_DC = TypedTables.Table(trig_pos = Vector{Vector{Float32}}[]*u"µs", trig_max = Vector{Float64}[])


MINTOT_INTERSECT = 40u"ns"
MAXTOT_INTERSECT = 100u"ns"


out_table3 = TypedTables.Table(trig_pos = Vector{Vector{Float32}}[]*u"µs", trig_max = Vector{Float64}[])

for (i, fn) in enumerate(filekeys)
    filename = l200.tier[:raw, filekeys[i]]
    data_ch = LHDataStore(filename, "r")["$ch/raw"][:]

    wvfs = data.waveform
    wvfs = shift_waveform.(wvfs, 0.0);

    # savitzky golay filter: takes derivative of waveform plus smoothing
    sgflt_savitz = SavitzkyGolayFilter(96u"ns", 2, 1)
    wvfs_sgflt_savitz = sgflt_savitz.(wvfs);

    # maximum finder
    intflt = IntersectMaximum(mintot=40u"ns",maxtot=100u"ns")
    inters = intflt.(wvfs_sgflt_savitz,threshold);

    # remove discharges
    # integrate and flip around x-axis the filtered waveforms
    flt = IntegratorFilter(gain=1)
    wvfs_der_int = flt.(wvfs_sgflt_savitz);
    flipped_wf = copy(wvfs_der_int)
    flipped_wf.signal .= -flipped_wf.signal;
    inters_DC = intflt.(flipped_wf,threshold_DC);
    filtered_inters = [inters[i] for i in 1:length(inters) if inters_DC[i].multiplicity == 0]
    filtered_inters_struct = StructArray(filtered_inters) # has to be a struct array

    append!(out_table3.trig_pos, filtered_inters_struct.x)
    append!(out_table3.trig_max, filtered_inters_struct.max)
end

histogram(reduce(vcat, out_table3.trig_max), bins=0.:.1:80., yscale = :log10, label="thrs 3.0 σ, DC rem", seriestype=:steppost, linealpha=0., 
                xlabel="peak amplitudes (a.u.)", title="p03 r000 - $det")


# make a pe spectrum by just plotting the maxes
hist = histogram(reduce(vcat, out_table.trig_max), bins=0.:.5:100., yscale = :log10, label="raw",
                xlabel="peak amplitudes (a.u.)", title="p03 r000 - $ch")
histogram!(reduce(vcat, out_table_NO_DC.trig_max), bins=0.:.5:100., yscale = :log10, label="NO discharges")
ylims!(hist, 1, 1e4)
extra_info = "_p03_r000"
savefig("./pe_spectra/$det$extra_info.png")
