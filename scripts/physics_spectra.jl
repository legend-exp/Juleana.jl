using LegendDataManagement, LegendHDF5IO, HDF5
using PropDicts, PropertyFunctions, StructArrays, TypedTables, ArraysOfArrays
using Plots, StatsBase
using LegendEventAnalysis, PropertyFunctions
using Unitful
using ProgressMeter
using IntervalSets
using LegendDataTypes: fast_flatten, readdata, writedata
using Distributed, LegendDataManagement, ThreadPinning
using Measurements

legend_addprocs(ncores())

@everywhere begin
    using LegendDataManagement, LegendHDF5IO, HDF5
    using PropDicts, PropertyFunctions, StructArrays, TypedTables, ArraysOfArrays
    using Plots, StatsBase
    using LegendEventAnalysis, PropertyFunctions
    using Unitful
    using ProgressMeter
    using IntervalSets
    using LegendDataTypes: fast_flatten, readdata
end

ENV["LEGEND_DATA_CONFIG"] = "/home/iwsatlas1/henkes/l200/config.json:/remote/ceph2/group/legendex/data/l200/julia/current/config.json"
l200 = LegendData(:l200)

part = DataPartition(1)
partinfo = partitioninfo(l200)[part]
found_filekeys = [filekey for (period, run) in partinfo if is_analysis_run(l200, period, DataRun(run.no +1)) for filekey in search_disk(FileKey, l200.tier[:jldsp, :phy, period, run])]

chinfo = Table(channelinfo(l200, first(found_filekeys); only_processable=true))
sel_geds_channels = filterby(@pf $system == :geds && $det_type in [:icpc, :bege] && $usability == :on)(chinfo).channel
sel_spms_channels = filterby(@pf $system == :spms && $usability == :on)(chinfo).channel
sel_geds_channels_int = Int.(sel_geds_channels)

@everywhere function read_events(l200, filekey)
    filename = l200.tier[:jlevt, filekey]
    tbl = h5open(input -> readdata(input, "events"), filename)
    # tbl = lh5open(l200.tier[:jlevt, filekey])["events"][:]
    Table(merge((filekey = fill(filekey, length(tbl)),), columns(tbl)))
end

r = read_events(l200, found_filekeys[begin])
@everywhere begin
    r = $r
    l200 = $l200
end

# r = read_events(l200, found_filekeys[begin])
# @showprogress for filekey in found_filekeys[begin+1:end]
#     try
#         # read_events(l200, filekey)
#         append!(r, read_events(l200, filekey))
#     catch err
#         @warn "Failed to read $filekey" err
#     end
# end


r_vec = @showprogress pmap(found_filekeys) do filekey
    try
        return read_events(l200, filekey)
        # append!(r, read_events(l200, filekey))
    catch err
        @warn "Failed to read $filekey" err
        return similar(r, 0)
    end
end

r = fast_flatten(r_vec[.!(isempty.(r_vec))])
# r = copy(r_vec[1])
# @showprogress for r_ in r_vec[begin+1:end]
#     if !isnothing(r_)
#         append!(r, r_)
#     end
# end

# Workaround for incorrect r.geds.emax_ch
# emax_chno = @pf($channel[findfirst(isequal($emax_trap_cal), $e_trap_cal)]).(r.geds)
# r = Table(merge(
#     columns(r),
#     (geds = Table(merge(columns(r.geds), (emax_chno = emax_chno,))),)
# ))

nopls = .!(r.puls.puls_trig)
nolar = .!(r.ged_spm.lar_cut)
nomult = r.geds.multiplicity .= 1
selchcut = @pf(all(in.($channel[$trig_e_ch], Ref(sel_geds_channels_int)))).(r.geds)
# qctrigch = @pf(all($is_physical[$trig_e_ch])).(r.geds)
# qcblch = @pf(all($is_baseline[setdiff(eachindex($is_baseline), $trig_e_ch)])).(r.geds)

# emaxqc = @pf($is_valid_baseline[$emax_ch] && !$is_upgoing_baseline[$emax_ch]).(r.geds)
# gooddet = (ch -> ch in sel_geds_channels).(emax_chno)
goodaoe = @pf(all($aoe_ds_cut[$trig_e_ch])).(r.geds)
larcuts = nolar
psdcuts = goodaoe

basiccuts = nopls .* nomult  .* selchcut
qualitycuts = basiccuts
allcuts = qualitycuts .* larcuts .* psdcuts


lar_nopls_pe = fast_flatten(flatview(r.spms.trig_pe[findall(nopls)]))
lar_smps_win_pe_sum = r.ged_spm.smps_win_pe_sum[findall(nopls)]

lar_pe_plot = plot(size=(800, 500))
stephist!(lar_smps_win_pe_sum, bins = 0.:.01:100, yscale = :log10, label = "SiMP sum(PE) in Ge-trig-window", dpi = 600)
plot!(xticks=0:1:10, xlims = (0.0,10), ylims=(1e2, 1e4), ylabel = "Counts / 0.01 PE", xlabel = "PE")

bins = 10:1:3000
bigbins = 10:10:3000
kbins = 1440:1:1550
roibins = 1930:2:2190


stephist(r.geds.max_e_cusp_ctc_cal .* qualitycuts, bins = bins, yscale = :log10)


#=
detector = DetectorId(:B00000B)
# detector = DetectorId(:C000RG1)
channel = channelinfo(l200, filekey, detector).channel
chidx = findfirst(isequal(Int(channel)), first(r).geds.channel)

lar_pe_plot = stephist(flatview(flatview(r.spms.trig_pe)), bins = 0.5:.025:4.5, yscale = :log10, xlabel = "All SiPMs, PE in Ge-trig-window")

stephist(@pf($e_trap_ctc_cal[chidx]).(r.geds) .* nopls, bins = bigbins, yscale = :log10)
stephist!(@pf($e_trap_ctc_cal[chidx] * $is_valid_baseline[chidx]).(r.geds) .* nopls .* nolar, bins = bigbins, yscale = :log10)
=#


histogram2d(r.geds.max_e_trap_cal, r.geds.aoe_classifier, nbins = (0:5:3000, -10:0.1:10), colorbar_scale=:log10, fmt=:png)

histogram2d(
    r.geds.emax_cusp_cal .* qualitycuts .* larcuts,
    @pf($aoe_classifier[$emax_ch]).(r.geds),
    nbins = (1000:5:3000, -10:0.1:10), colorbar_scale=:log10, fmt=:png
)



# Final plots:

lar_pe_hist = fit(Histogram, fast_flatten(flatview(lar_nopls_pe)), 0:.01:40)
lar_pe_plot = plot(size=(1200, 800))
plot!(lar_pe_hist, xlims = (0.4,7.5), st = :stepbins, yscale = :log10, xlabel = "PE", label = "SiMP sum(PE) in Ge-trig-window", ylims = (10^4,10^7), ylabel = "Counts / 0.01 PE", dpi = 600)
# savefig(lar_pe_plot, "plots/lar_pe_plot.png")
# savefig(lar_pe_plot, "plots/lar_pe_plot.pdf")

multiplicity_plot = stephist(r.geds.multiplicity .* nopls, bins = 0:0.1:10, dpi = 600)

physpec_plot = stephist(r.geds.emax_cusp_cal .* qualitycuts, bins = bigbins, ylabel = "Counts / $(step(bigbins)) keV", yscale = :log10, label ="QC", xlabel = "Energy", dpi = 600)
# savefig(physpec_plot, "plots/physpec_plot.png")
# savefig(physpec_plot, "plots/physpec_plot.pdf")

physpec_cuts_plot = plot()
stephist!(r.geds.emax_cusp_cal .* qualitycuts, bins = bigbins, yscale = :log10, ylabel = "Counts / $(step(bigbins)) keV", label = "QC", xlabel = "Energy", dpi = 600)
stephist!(r.geds.emax_cusp_cal .* qualitycuts .* psdcuts, bins = bigbins, yscale = :log10, label = "PSD")
stephist!(r.geds.emax_cusp_cal .* qualitycuts .* larcuts .* psdcuts, bins = bigbins, yscale = :log10, label = "PSD + LAr")
# savefig(physpec_cuts_plot, "plots/physpec_cuts_plot.png")
# savefig(physpec_cuts_plot, "plots/physpec_cuts_plot.pdf")

klines_plot = plot()
stephist!(r.geds.max_e_cusp_ctc_cal .* qualitycuts, bins = kbins, ylabel = "Counts / $(step(kbins)) keV", label = "QC", xlabel = "Energy", dpi = 600)
stephist!(r.geds.max_e_cusp_ctc_cal .* qualitycuts .* larcuts, bins = kbins, label = "LAr")

n_k42_before = count(1522u"keV" .< r.geds.max_e_cusp_ctc_cal .* qualitycuts .< 1528u"keV")
n_k42_before = measurement(n_k42_before, sqrt(n_k42_before))
n_k42_after = count(1522u"keV" .< r.geds.max_e_cusp_ctc_cal .* qualitycuts .* larcuts .< 1528u"keV")
n_k42_after = measurement(n_k42_after, sqrt(n_k42_after))
suppression_k42 = n_k42_after / n_k42_before *100u"percent"

n_k40_before = count(1456u"keV" .< r.geds.max_e_cusp_ctc_cal .* qualitycuts .< 1466u"keV")
n_k40_before = measurement(n_k40_before, sqrt(n_k40_before))
n_k40_after = count(1456u"keV" .< r.geds.max_e_cusp_ctc_cal .* qualitycuts .* larcuts .< 1466u"keV")
n_k40_after = measurement(n_k40_after, sqrt(n_k40_after))
suppression_k40 = n_k40_after / n_k40_before *100u"percent"

n_tl208_before = count(2610u"keV" .< r.geds.max_e_cusp_ctc_cal .* qualitycuts .< 2620u"keV")
n_tl208_before = measurement(n_tl208_before, sqrt(n_tl208_before))
n_tl208_after = count(2610u"keV" .< r.geds.max_e_cusp_ctc_cal .* qualitycuts .* larcuts .< 2620u"keV")
n_tl208_after = measurement(n_tl208_after, sqrt(n_tl208_after))
suppression_tl208 = n_tl208_after / n_tl208_before *100u"percent"
# savefig(klines_plot, "plots/klines_plot.png")
# savefig(klines_plot, "plots/klines_plot.pdf")

roi_plot = plot(size=(2000, 800))
barhist!(r.geds.max_e_cusp_ctc_cal .* qualitycuts .* psdcuts, bins = roibins, ylabel = "Counts / $(step(roibins)) keV", ylims = (0,4), label = "PSD", xlabel = "Energy", linewidth = 0, dpi = 600, alpha=0.4)
barhist!(r.geds.max_e_cusp_ctc_cal .* qualitycuts .* larcuts .* psdcuts, bins = roibins, ylabel = "Counts / $(step(roibins)) keV", ylims = (0,4), label = "PSD + LAr", linewidth = 0)
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




# scratch
r_afterall = r[findall(Bool.(allcuts))]

r_afterall_roi = r_afterall[findall(roibins[1]*u"keV" .< r_afterall.geds.max_e_cusp_ctc_cal .< roibins[end]*u"keV")]
