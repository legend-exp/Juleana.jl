using LegendDataManagement, LegendHDF5IO, HDF5
using PropDicts, PropertyFunctions, StructArrays, TypedTables, ArraysOfArrays
using Plots, StatsBase
using LegendEventAnalysis, PropertyFunctions
using Unitful
using ProgressMeter
using IntervalSets
using LegendDataTypes: fast_flatten, readdata

data = LegendData(:l200)

selected_periods = [DataPeriod(3), DataPeriod(4)]
filekeys = [filekey for period in selected_periods for run in search_disk(DataRun, data.tier[:jlevt, :phy, period]) for filekey in search_disk(FileKey, data.tier[:jlevt, :phy, period, run])]

sel = ValiditySelection(first(filekeys))
chinfo = channelinfo(data, sel)
sel_geds_channels = Set(Int.(ChannelId.(filterby(@pf $system == :geds && $aoe_status == :valid)(chinfo).channel)))


function read_events(data, filekey)
    filename = data.tier[:jlevt, filekey]
    h5open(input -> readdata(input, "events"), filename)
end

r = read_events(data, filekeys[begin])
@showprogress for filekey in filekeys[begin+1:end]
    try
        append!(r, read_events(data, filekey))
    catch err
        @warn "Failed to read $filekey" err
    end
end

# Workaround for incorrect r.geds.emax_ch
emax_chno = @pf($channel[findfirst(isequal($emax_trap_cal), $e_trap_cal)]).(r.geds)
r = Table(merge(
    columns(r),
    (geds = Table(merge(columns(r.geds), (emax_chno = emax_chno,))),)
))

nopls = .!(r.puls.puls_trig)
nolar = .!(r.ged_spm.lar_cut)
nomult = r.geds.multiplicity .= 1
emaxqc = @pf($is_valid_baseline[$emax_ch] && !$is_upgoing_baseline[$emax_ch]).(r.geds)
gooddet = (ch -> ch in sel_geds_channels).(emax_chno)
goodaoe = @pf($aoe_ds_cut[$emax_ch]).(r.geds)
larcuts = nolar
psdcuts = goodaoe

basiccuts = nopls .* gooddet .* nomult
qualitycuts = basiccuts .* emaxqc
allcuts = qualitycuts .* larcuts .* psdcuts


lar_nopls_pe = r.spms.trig_pe[findall(nopls)]


bins = 10:1:3000
bigbins = 10:10:3000
kbins = 1440:1:1550
roibins = 1930:2:2190


stephist(r.geds.emax_trap_ctc_cal .* qualitycuts, bins = bins, yscale = :log10)


#=
detector = DetectorId(:B00000B)
# detector = DetectorId(:C000RG1)
channel = channelinfo(data, filekey, detector).channel
chidx = findfirst(isequal(Int(channel)), first(r).geds.channel)

lar_pe_plot = stephist(flatview(flatview(r.spms.trig_pe)), bins = 0.5:.025:4.5, yscale = :log10, xlabel = "All SiPMs, PE in Ge-trig-window")

stephist(@pf($e_trap_ctc_cal[chidx]).(r.geds) .* nopls, bins = bigbins, yscale = :log10)
stephist!(@pf($e_trap_ctc_cal[chidx] * $is_valid_baseline[chidx]).(r.geds) .* nopls .* nolar, bins = bigbins, yscale = :log10)
=#


histogram2d(r.e_trap_cal, r.aoe_classifier, nbins = (0:5:3000, -10:0.1:10), colorbar_scale=:log10, fmt=:png)

histogram2d(
    r.geds.emax_trap_cal .* qualitycuts .* larcuts,
    @pf($aoe_classifier[$emax_ch]).(r.geds),
    nbins = (1000:5:5000, -10:0.1:10), colorbar_scale=:log10, fmt=:png
)



# Final plots:

lar_pe_hist = fit(Histogram, fast_flatten(flatview(lar_nopls_pe)), 0:.01:40)
lar_pe_plot = plot(lar_pe_hist, xlims = (0.4,7.5), st = :stepbins, yscale = :log10, xlabel = "PE", label = "SiMP sum(PE) in Ge-trig-window", ylims = (10^4,10^7), ylabel = "Counts / 0.01 PE", dpi = 600)
savefig(lar_pe_plot, "plots/lar_pe_plot.png")
savefig(lar_pe_plot, "plots/lar_pe_plot.pdf")

lar_pe_plot_2 = stephist(r.ged_spm.smps_win_pe_sum, bins = 0.5:0.01:8.5)

multiplicity_plot = stephist(r.geds.multiplicity .* nopls, bins = 0:0.1:10, dpi = 600)

physpec_plot = stephist(r.geds.emax_cusp_ctc_cal .* qualitycuts, bins = bigbins, ylabel = "Counts / $(step(bigbins)) keV", yscale = :log10, label ="QC", xlabel = "Energy", dpi = 600)
savefig(physpec_plot, "plots/physpec_plot.png")
savefig(physpec_plot, "plots/physpec_plot.pdf")

physpec_cuts_plot = plot()
stephist!(r.geds.emax_cusp_ctc_cal .* qualitycuts, bins = bigbins, yscale = :log10, ylabel = "Counts / $(step(bigbins)) keV", label = "QC", xlabel = "Energy", dpi = 600)
stephist!(r.geds.emax_cusp_ctc_cal .* qualitycuts .* psdcuts, bins = bigbins, yscale = :log10, label = "PSD")
stephist!(r.geds.emax_cusp_ctc_cal .* qualitycuts .* larcuts .* psdcuts, bins = bigbins, yscale = :log10, label = "PSD + LAr")
savefig(physpec_cuts_plot, "plots/physpec_cuts_plot.png")
savefig(physpec_cuts_plot, "plots/physpec_cuts_plot.pdf")

klines_plot = plot()
stephist!(r.geds.emax_cusp_ctc_cal .* qualitycuts, bins = kbins, ylabel = "Counts / $(step(kbins)) keV", label = "QC", xlabel = "Energy", dpi = 600)
stephist!(r.geds.emax_cusp_ctc_cal .* qualitycuts .* larcuts, bins = kbins, label = "LAr")
savefig(klines_plot, "plots/klines_plot.png")
savefig(klines_plot, "plots/klines_plot.pdf")

roi_plot = plot()
barhist!(r.geds.emax_cusp_ctc_cal .* qualitycuts .* psdcuts, bins = roibins, ylabel = "Counts / $(step(roibins)) keV", ylims = (0,4), label = "PSD", xlabel = "Energy", linewidth = 0, dpi = 600)
barhist!(r.geds.emax_cusp_ctc_cal .* qualitycuts .* larcuts .* psdcuts, bins = roibins, ylabel = "Counts / $(step(roibins)) keV", ylims = (0,4), label = "PSD + LAr", linewidth = 0)
vspan!([2099, 2109], color = :black, fillalpha = 0.2, label = "")
vspan!([2114, 2124], color = :black, fillalpha = 0.2, label = "")
vspan!([2039-2, 2039+2], color = :orange, fillalpha = 0.4, label = "")
savefig(roi_plot, "plots/roi_plot.png")
savefig(roi_plot, "plots/roi_plot.pdf")


lar_cut_idxs = findall(x -> x > 0, qualitycuts .* larcuts)
larpsd_cut_idxs = findall(x -> x > 0, qualitycuts .* larcuts .* psdcuts)
aoe_plot = scatter(
    r.geds.emax_trap_cal[lar_cut_idxs],
    @pf($aoe_classifier[$emax_ch]).(r.geds)[lar_cut_idxs],
    markersize = 2, markercolor = :grey, markerstrokewidth = 0, label = "After LAr",
    xlims = (1000, 5000), ylims = (-60, 80), fmt=:png, dpi = 600
)
scatter!(
    r.geds.emax_trap_cal[larpsd_cut_idxs],
    @pf($aoe_classifier[$emax_ch]).(r.geds)[larpsd_cut_idxs],
    markersize = 2, markercolor = :blue, markerstrokewidth = 0, label = "After LAr+PSD"
)
savefig(aoe_plot, "plots/aoe_plot.png")
savefig(aoe_plot, "plots/aoe_plot.pdf")


# ==========================================

roi = (minimum(roibins)* u"keV" .. maximum(roibins)* u"keV")

idxs = findall(x -> x in roi, r.geds.emax_cusp_ctc_cal .* qualitycuts .* larcuts .* psdcuts)
sum.(filter(!iszero, r.spms.trig_pe[idxs[2]]))
