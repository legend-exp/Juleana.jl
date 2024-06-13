using Plots
using TypedTables
using LegendDataManagement
using LegendDataTypes: fast_flatten
using LegendHDF5IO
using LegendDataTypes
using LegendDSP
using LegendSpecFits
using LegendDataManagement.LDMUtils
using Unitful
using PropertyFunctions
using LinearAlgebra

using StatsBase

using Measurements
using Measurements: value as mvalue
using Measurements: uncertainty as muncert

using JSON
using JSONTables, DataFrames

l200 = LegendData(:l200)

chinfo_ppcs = channelinfo(l200, (:p03, :r000, :cal); system=:geds, only_processable=true) #|> filterby(@pf $is_bb_like == "low_aoe && lq")

#checl which detectors are from Ortec
list_of_ORTEC_ICPC = []
for detector in l200.metadata.hardware.detectors.germanium.diodes
    type = detector.type
    manufacturer = detector.production.manufacturer
    if type == "icpc"
        println("Type: $type, manufacturer: $manufacturer, Name: $(detector.name)")
        if manufacturer == "Ortec"
            push!(list_of_ORTEC_ICPC, detector.name)
        end
    end
end

list_of_ORTEC_ICPC

#lq_status valid
#dets = chinfo_ppcs.detector[chinfo_ppcs.lq_status .==:valid]
#channels = chinfo_ppcs.channel[chinfo_ppcs.lq_status .==:valid]
#detectortype = chinfo_ppcs.det_type[chinfo_ppcs.lq_status .==:valid]

#only PPC
#dets = chinfo_ppcs.detector[chinfo_ppcs.det_type .== :ppc .&& chinfo_ppcs.lq_status .==:valid]
#channels = chinfo_ppcs.channel[chinfo_ppcs.det_type .== :ppc .&& chinfo_ppcs.lq_status .==:valid]
#detectortype = chinfo_ppcs.det_type[chinfo_ppcs.det_type .== :ppc .&& chinfo_ppcs.lq_status .==:valid]

#only ICPC
dets = chinfo_ppcs.detector[chinfo_ppcs.det_type .== :icpc]
channels = chinfo_ppcs.channel[chinfo_ppcs.det_type .== :icpc]
detectortype = chinfo_ppcs.det_type[chinfo_ppcs.det_type .== :icpc]

#only BEGE
#dets = chinfo_ppcs.detector[chinfo_ppcs.det_type .== :bege .&& chinfo_ppcs.lq_status .==:valid]
#channels = chinfo_ppcs.channel[chinfo_ppcs.det_type .== :bege .&& chinfo_ppcs.lq_status .==:valid]
#detectortype = chinfo_ppcs.det_type[chinfo_ppcs.det_type .== :bege .&& chinfo_ppcs.lq_status .==:valid]


filekey = start_filekey(l200, (:p03, :r000, :cal))
#pd = l200.par.rpars.ecal(filekey)


i = 12 #1
ch = channels[i]
det = dets[i]
type = detectortype[i]

readdir(l200.tier[:jlhitch, :cal, :p03])

filekeys = []
for file in readdir(l200.tier[:jlhitch, :cal, :p03])
    k = start_filekey(l200, (:p03, Symbol.(file), :cal)) 
    #k = first(search_disk(FileKey, l200.tier[:jlhitch, :cal, :p03, Symbol.(file)]))
    println(k)
    push!(filekeys, k)
end

println("Detector: $(dets[i])")
#datapath = get_hitchfilename(l200, filekey, ch)

lq_mean = []
e_cal = Vector{typeof(0.0u"keV")}()
LQ = Vector{Float64}()
tdrift = Vector{typeof(0.0u"keV^-1")}()


#load data of one detector for all in one period
for (nr, key) in enumerate(filekeys)
    #nr = 1
    #key = filekeys[nr]
    println("File nr $(nr), which is $(key)")
    data_path = l200.tier[:jlhitch, key, ch]
    data = LHDataStore(data_path)
    table = data[ch].dataQC[:]
    #load data from one run
    
    pd = l200.par.rpars.ecal(key) ##Das Laden hier dauert ewig
    f_cal = ljl_propfunc(pd[dets[i]].e_cusp_ctc.cal.func)
    e_cal_temp = Vector(f_cal.(table))
    lq_temp = table.lq

    tdrift_temp = table.qdrift ./ (e_cal_temp)

    lq_over_e = lq_temp ./ e_cal_temp

    #stability of lq
    lq_mean_single = mean(lq_over_e[1589u"keV" .< e_cal_temp .< 1596u"keV"]) #mean of lq in DEP

    append!(e_cal, e_cal_temp)
    append!(LQ, ustrip.(lq_over_e))
    append!(tdrift, tdrift_temp)
    append!(lq_mean, lq_mean_single)
end

scatter(ustrip.(lq_mean), xlabel="Run", ylabel="Mean LQ in DEP", title="Mean LQ in DEP of $(dets[i])", framestyle=:box, fontfamily="Computer Modern", formatter=:plain, dpi=300, thickness_scaling=1.6, size=(1200,900))
histogram2d(e_cal, LQ, xlabel="Energy", ylabel="LQ over Energy (A.U.)", title="Energy vs LQ over Energy of $(dets[i])", colorbar_scale=:log10,
c=:viridis, framestyle=:box, fontfamily="Computer Modern", formatter=:plain, dpi=300, thickness_scaling=1.6, size=(1200,900), 
nbins=(0:1:3500, -5:0.1:35)
)
#savefig("/mnt/artemis02/users/gieb/MPP_Code/Documents/Plots/CM_Data/Poster/$(dets[i])_Energy_vs_LQ_over_Energy.png")

histogram(e_cal, xlabel="Energy", ylabel="Counts", title="Energy Spectrum of Detector $(dets[i])", nbins=0:1:3500, framestyle=:box, fontfamily="Computer Modern", formatter=:plain, dpi=300, thickness_scaling=1.6, size=(1200,900), yscale=:log10)

#A/E energy correction method
#=
compton_bands  = [520, 555, 590, 610, 630, 650, 670, 690, 735, 790, 810, 830, 865, 900, 930, 955, 1000, 1020, 1040, 1130, 1150, 1170, 1190, 1210, 1250, 
1270, 1290, 1310, 1330, 1420, 1520, 1540, 1700, 1780, 1810, 1850, 1870, 1890, 1910, 1930, 1950, 1970, 1990, 2010, 2030, 2050, 2150] *u"keV"
compton_window = 20u"keV"
p_value        = 0.0000000

p = histogram2d(e_cal, LQ, nbins=(0:0.5:3000, 25:0.05:35), 
size=(1200, 800), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy", ylabel="A/E (a.u.)")
xticks!(p, 0:250:3000)

# get compton band peak histograms with generated peakstats
compton_band_peakhists = generate_aoe_compton_bands(LQ, e_cal, compton_bands, compton_window)

result_fit, report_fit = fit_lq_compton(compton_band_peakhists.peakhists, compton_band_peakhists.peakstats, compton_bands,; uncertainty=true)
compton_band_peakhists.peakstats[1]
report_fit[compton_bands[1]].v

# generate plots of compton bands as gif
p = @animate for band in compton_bands fps=0.5
     report_band = report_fit[band]
     plot(report_band, title="Compton Band at $(band) keV", xlabel="A/E (a.u.)", ylabel="Counts")
     xlims!(minimum(compton_band_peakhists.min_aoe), maximum(compton_band_peakhists.max_aoe))
 end
gif(p, fps=1)
compton_bands_result = [band for band in keys(result_fit) if result_fit[band].gof.pvalue >= p_value]
μ = [result_fit[band].μ for band in compton_bands_result]
σ = [result_fit[band].σ for band in compton_bands_result]
result_fit[compton_bands_result[5]].gof.pvalue
# fit μ and σ with correction functions
result, report = aoe_corrections = fit_aoe_corrections(compton_bands_result, μ, σ)

# plot μ and σ with correction functions
plot(report.report_µ)
plot(report.report_σ)

#create TypedTable
table = Table(e = e_cal, a = LQ .* ustrip.(e_cal), tdrift = tdrift)

lq_corr = ljl_propfunc(result.func).(table)
histogram2d(ustrip.(u"keV", e_cal), lq_corr, size=(1300, 700), nbins=(0:0.5:3000, -10:0.1:10),
color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy [keV]", ylabel="Corrected A/E [a.u.]")
=#

#energy correction 
lq_corr = LQ


#drift time vs late charge
histogram2d(tdrift, lq_corr, xlabel="Drift Time", ylabel="Late Charge (A.U.)", title="Drift Time vs Late Charge of $(dets[i]) Corrected", framestyle=:box,  
#nbins=(0:0.05:10, -5:0.05:600 ), 
colorbar_scale=:log10, c=:viridis, fontfamily="Computer Modern", formatter=:plain, dpi=300, thickness_scaling=1.6, size=(1200,900))


#Drift time vs late charge in DEP
lq_DEP_dt = lq_corr[1589u"keV" .< e_cal .< 1596u"keV"]
t_tcal = ustrip.(tdrift[1589u"keV" .< e_cal .< 1596u"keV"])
histogram2d(t_tcal, lq_DEP_dt, xlabel="Drift Time", ylabel="Late Charge (A.U.)", title="DEP drift time fit", framestyle=:box,
nbins=(0:1:1000, -0.1:0.05:10 ), 
c=:viridis, fontfamily="Computer Modern", formatter=:plain, dpi=300, thickness_scaling=1.6, size=(1200,900))


#drift time correction

drift_result, drift_report = lq_drift_time_correction(lq_corr, tdrift, e_cal, type)


# lq drift time testing ground

#=
lq_norm::Vector{Float64} = lq_corr
DEP_left=1589u"keV"
det_icpc = false
DEP_right=1596u"keV"
lower_exclusion=0.005
upper_exclusion=0.98
drift_cutoff_sgima=2.0

#Using fixed values for DEP, can be changed to use values from DEP fit from Energy calibration 
lq_DEP_dt = lq_norm[DEP_left .< e_cal .< DEP_right]
t_tcal = ustrip.(tdrift[DEP_left .< e_cal .< DEP_right])


#get bin width for histogram (reomve NaNs before)
lq_DEP_dt_filtered = lq_DEP_dt[.!isnan.(lq_DEP_dt)]
bin_width = LegendSpecFits.get_friedman_diaconis_bin_width(lq_DEP_dt_filtered)
# get energy before cut and create histogram
lq_prehist = fit(Histogram, lq_DEP_dt, minimum(lq_DEP_dt_filtered):bin_width:maximum(lq_DEP_dt_filtered))
lq_prestats = estimate_single_peak_stats(lq_prehist)
lq_result, lq_report = LegendSpecFits.fit_binned_gauss(lq_prehist, lq_prestats;uncertainty=false)

lq_start = lq_prestats.peak_pos - 3*lq_prestats.peak_sigma
lq_stop = lq_prestats.peak_pos + 3*lq_prestats.peak_sigma

lq_edges = range(lq_start, stop=lq_stop, length=51) 
lq_hist_DEP = fit(Histogram, lq_DEP_dt, lq_edges)

lq_DEP_stats = estimate_single_peak_stats(lq_hist_DEP)
lq_result, lq_report = LegendSpecFits.fit_binned_gauss(lq_hist_DEP, lq_DEP_stats)
µ_lq = mvalue(lq_result.μ)
σ_lq = mvalue(lq_result.σ)

#set cutoff in lq dimension for later fit
lq_lower = µ_lq - drift_cutoff_sgima * σ_lq 
lq_upper = µ_lq + drift_cutoff_sgima * σ_lq 
=#















#drift time sanity plots
plot(drift_report.lq_prehist)
plot(normalize(drift_report.lq_report.h; mode=:density))
plot!(drift_report.lq_report.f_fit, linewidth = 3)
plot(drift_report.drift_prehist)
plot(normalize(drift_report.drift_report.h; mode=:density))
plot!(drift_report.drift_report.f_fit, linewidth = 3)
#plot!(drift_report.drift_report.f_gauss_1, linewidth = 3)


box = drift_result.lq_box
histogram2d(t_tcal, lq_DEP_dt, xlabel="Drift Time", ylabel="LQ (A.U.)", title="DEP drift time fit", framestyle=:box,
nbins=(0:1:1000, 0:0.01:6.0), 
left_margin = -12Plots.mm, bottom_margin = -15Plots.mm, top_margin = -8Plots.mm,
c=:viridis, fontfamily="Computer Modern", formatter=:plain, thickness_scaling=3, size=(1200,900))
vline!([box.t_lower, box.t_upper], label = "", linewidth = 1.5, color = :red)
hline!([box.lq_lower, box.lq_upper], label = "", linewidth = 1.5, color = :red)
plot!(drift_result.drift_time_func, label = "Linear Fit", linewidth = 2, color = :blue)
#savefig("/mnt/artemis02/users/gieb/MPP_Code/Documents/Plots/CM_Data/Poster/$(dets[i])_Drift_Box_BIIIG.png")

lq_class = drift_result.lq_classifier

#plot lq_class with margins at the edges
histogram2d(e_cal, lq_class, xlabel="Energy", ylabel="LQ classifier (A.U.)", title="Energy vs LQ classifier of $(dets[i])", framestyle=:box,
nbins=(0:4:3000, -4.5:0.02:19.5), c=:viridis, fontfamily="Computer Modern", formatter=:plain, dpi=300, thickness_scaling=2, size=(1200,900), colorbar_scale=:log10,
left_margin = -5Plots.mm, bottom_margin = -5Plots.mm, top_margin = -3Plots.mm,
)
#savefig("/mnt/artemis02/users/gieb/MPP_Code/Documents/Plots/CM_Data/Poster/$(dets[i])_Energy_vs_LQclass.png")


#pd2 = l200.par.ppars.ecal(filekey)
#DEP_σ = mvalue(pd2[dets[i]].e_cusp_ctc.fit.Tl208DEP.σ)
#DEP_µ = mvalue(pd2[dets[i]].e_cusp_ctc.fit.Tl208DEP.μ)

#ersatzwerte
DEP_σ = 0.77u"keV"
DEP_µ = 1592.5u"keV"

result, report = LQ_cut(DEP_µ, DEP_σ, e_cal, lq_class)

temp_hists = report.temp_hists

#several plots
plot(temp_hists.prehist, label="DEP", c=:blue)
plot(temp_hists.hist_DEP, label="DEP", c=:blue)
plot!(temp_hists.hist_sb1, label="SB1", c=:red)
plot!(temp_hists.hist_sb2, label="SB2", c=:green)
plot(temp_hists.hist_subtracted)
plot(temp_hists.hist_corrected, label="Corrected", c=:blue)


plot(layout = @layout[grid(2, 1, heights=[0.5, 0.5])], link=:x, framestyle=:box, fontfamily="Computer Modern", xlabel="LQ [A.U.]",
ylabel="Counts", thickness_scaling=3, size=(1200,900),
left_margin = -16Plots.mm, bottom_margin = -14Plots.mm, top_margin = 0Plots.mm)
plot!(normalize(report.fit_report.h; mode=:density), label="Data", subplot=1, c=:black, ylabel="", title="DEP LQ fit", top_margin = -9Plots.mm)
plot!(report.fit_report.f_fit, label="Gausian Fit", linewidth = 2)
#vline!([mvalue(result.cut)], label = "3σ exclusion", linewidth = 2, color = :red)
scatter!(report.fit_report.h.edges, result.fit_result.gof.residuals_norm, label="", subplot=2, markercolor=:black, 
ylabel="Norm. Res.", ms=2.5)
#savefig("/mnt/artemis02/users/gieb/MPP_Code/Documents/Plots/CM_Data/Poster/$(dets[i])_LQ_Cut_BIIIG.png")




#Goodness plots
gr()
#3 sigma exclusion in Corrected lq 2d histogram
histogram2d(e_cal, lq_class , xlabel="Energy", ylabel="LQ (A.U.)", title="Energy vs LQ classifier of $(dets[i])", 
nbins=(0:3:3000, -2.5:0.01:10),
colorbar_scale=:log10, c=:viridis, framestyle=:box, fontfamily="Computer Modern", formatter=:plain, thickness_scaling=3, size=(1200,900),
left_margin = -22Plots.mm, bottom_margin = -14Plots.mm, top_margin = -6Plots.mm)
hline!([mvalue(result.cut)], label = "3σ exclusion", linewidth = 2, color = :red, legend=:topright)

#savefig("/mnt/artemis02/users/gieb/MPP_Code/Documents/Plots/ByHand/ICPC/$(dets[i])_3sigma_exclusion_BIIIG.png")


plotlyjs()
gr()
stephist(e_cal, xlabel="Energy", ylabel="Counts", title="Energy Spectrum of Detector $(dets[i])", nbins=(0:1:3500), framestyle=:box, fontfamily="Computer Modern", formatter=:plain,
dpi=300, thickness_scaling=1.6, size=(1200,900), yscale=:log10, label="Data withou LQ Cut")
stephist!(e_cal[lq_class .< result.cut], nbins=0:1:3500, label="Surviving LQ Cut", framestyle=:box, fontfamily="Computer Modern", formatter=:plain, 
dpi=300, thickness_scaling=1.6, size=(1200,900), yscale=:log10)
#savefig("/mnt/artemis02/users/gieb/MPP_Code/Documents/Plots/ByHand/LQ_Quality/$(dets[i])_Energy_diff.png")

stephist(e_cal[lq_class .< result.cut], nbins=0:1:3500, color=:red, label="Cutted", framestyle=:box, fontfamily="Computer Modern", formatter=:plain, dpi=300, thickness_scaling=1.6, size=(1200,900), yscale=:log10)

h1 = fit(Histogram, ustrip.(e_cal), 0:1:3500)
h2 = fit(Histogram, ustrip.(e_cal[lq_class .< result.cut]), 0:1:3500)

h_diff = h2.weights ./ h1.weights

plot(h_diff, xlabel="Energy", ylabel="Counts", title="Energy of $(dets[i])", framestyle=:box, fontfamily="Computer Modern", formatter=:plain, dpi=300, thickness_scaling=1.6, size=(1200,900),
label="Survival Fraction", legend=:bottomleft)




#evaluate and plot survival fractions
peak = 1593.0u"keV"
window = [10.0u"keV", 10.0u"keV"]
sf_result, sf_report = get_peak_surrival_fraction(lq_class, e_cal, peak, window, result.cut; lq_mode=true)


#sf value for cut
peaknames = ["Tl208DEP", "Bi212FEP", "Tl208SEP", "Tl208FEP"]
peak_values = [1592.53, 1620.50, 2103.53, 2614.51] * u"keV"
labelvalues = Dict{String, typeof(sf_result.sf)}()
for (i,name) in enumerate(peaknames)
    sf_result, sf_report = get_peak_surrival_fraction(lq_class, e_cal, peak_values[i], window, result.cut; lq_mode=true)
    labelvalues[name] = sf_result.sf
end
labelvalues["Continuum"] = get_continuum_surrival_fraction(lq_class, e_cal, 2029.0u"keV", 10.0u"keV", result.cut; lq_mode=true).sf

labelvalues

#get other "cut values" to check the stability of the sf
cut_values = range(minimum(0), stop=maximum(4 * mvalue(result.cut)), length=40)
#sf for peaks
peaknames = ["Tl208DEP", "Bi212FEP", "Tl208SEP", "Tl208FEP"]
peak_values = [1592.53, 1620.50, 2103.53, 2614.51] * u"keV"
sf_peak_results = Dict{String, Vector{typeof(sf_result.sf)}}()
for (i, name) in enumerate(peaknames)
    println("Peak: $(name)")
    # Initialize an empty vector to store the results for this peak
    sf_peak_result = Vector{typeof(sf_result.sf)}()

    for j in cut_values
        println("Cut value: $j")
        sf_temp_result, sf_temp_report = get_peak_surrival_fraction(lq_class, e_cal, peak_values[i], window, j; lq_mode=true)
        push!(sf_peak_result, sf_temp_result.sf)
    end

    # Store the results for this peak in the dictionary
    sf_peak_results[name] = sf_peak_result
end

sf_whole = sf_peak_results
# sf for continuum
Qbb = 2029.0u"keV"
window = 10.0u"keV"
continumsf = []
for i in cut_values
    println("Cut value: $i")
    conti = get_continuum_surrival_fraction(lq_class, e_cal, Qbb, window, i; lq_mode=true)
    push!(continumsf, conti.sf)
end
sf_whole["Continuum"] = continumsf

println(sf_whole)

p = scatter(xlabel="Cut Value", ylabel="Survival Fraction", title="Survival Fraction", framestyle=:box, fontfamily="Computer Modern", 
formatter=:plain, dpi=300, thickness_scaling=3, size=(1200,900), label=nothing, 
left_margin = -17Plots.mm, bottom_margin = -13Plots.mm, top_margin = -10Plots.mm
)
# Iterate over the results
for (name, sf_peak_result) in sf_whole
    # Add the results for this peak to the plot
    scatter!(p, cut_values, mvalue.(sf_peak_result), #yerror = muncert.(sf_peak_result), 
    label="$name, SF: $(labelvalues[name])", 
    ylabel="Survival Fraction", framestyle=:box, fontfamily="Computer Modern", ms=3, markerstrokecolor =:auto)
end
vline!(p, [mvalue(result.cut)], label = "cut value: $(result.cut)", linewidth = 1.5, color = :red)
ylims!(30, 105)

savefig("/mnt/artemis02/users/gieb/MPP_Code/Documents/Plots/ByHand/ICPC/$(dets[i])_SurvivalFraction_scatter.png")


p = plot(xlabel="Cut Value", ylabel="Survival Fraction", title="Survival Fraction", framestyle=:box, fontfamily="Computer Modern", 
formatter=:plain, dpi=300, thickness_scaling=3, size=(1200,900), label=nothing, 
left_margin = -17Plots.mm, bottom_margin = -13Plots.mm, top_margin = -10Plots.mm)

# Iterate over the results
for (name, sf_peak_result) in sf_whole
    # Add the results for this peak to the plot
    plot!(p, cut_values, mvalue.(sf_peak_result), yerror = muncert.(sf_peak_result), 
    label="$name, SF: $(labelvalues[name])", 
    ylabel="Survival Fraction", framestyle=:box, fontfamily="Computer Modern", ms=0.0000001, markerstrokecolor =:auto)
end
vline!(p, [mvalue(result.cut)], label = "cut value: $(result.cut)", linewidth = 1.5, color = :red)

savefig("/mnt/artemis02/users/gieb/MPP_Code/Documents/Plots/ByHand/ICPC/$(dets[i])_SurvivalFraction_plot.png")



#plot single waveforms
#=

DEP_uncut = (μ_fit - 3*σ_fit) .< lq_corrected .< (μ_fit + 3*σ_fit) .&& 1589u"keV" .< e_cal .< 1596u"keV"
DEP_cut = (μ_fit - 3*σ_fit .> lq_corrected .|| lq_corrected .> μ_fit + 3*σ_fit) .&& 1589u"keV" .< e_cal .< 1596u"keV" 

Outliers = (μ_fit - 20*σ_fit .> lq_corrected .|| lq_corrected .> μ_fit + 20*σ_fit) .&& 1589u"keV" .< e_cal .< 1596u"keV"



tabledata = load_hitchfile(lh5open, l200, filekey, ch; calibrate_energy=true)
data_DEP_CUT  = tabledata[DEP_cut]
data_DEP_UNCUT = tabledata[DEP_uncut]


wvf_data_cut = load_rawevt(lh5open, l200, ch, data_DEP_CUT, 1:10)
wvfs_cut = wvf_data_cut.waveform[5000 .< wvf_data_cut.daqenergy .< 7500]


wvf_data_uncut = load_rawevt(lh5open, l200, ch, data_DEP_UNCUT, 1:10)
wvfs_uncut = wvf_data_uncut.waveform[5000 .< wvf_data_cut.daqenergy .< 7500]

#pick high sigma wv
#=
wvf_data_uncut = load_rawevt(lh5open, l200, ch, tabledata, 398303)
wvfs_uncut = wvf_data_uncut.waveform
=#

plot(wvfs_cut[1:10], title="Waveform of $(dets[i])", xlabel="Time", ylabel="Amplitude [ADC]", framestyle=:box, fontfamily="Computer Modern", formatter=:plain, dpi=300, thickness_scaling=1.6, size=(1200,900), linecolor=:red, legend=false)
plot!(wvfs_uncut[1:10], title="Waveform of $(dets[i])", xlabel="Time", ylabel="Amplitude [ADC]", framestyle=:box, fontfamily="Computer Modern", formatter=:plain, dpi=300, thickness_scaling=1.6, size=(1200,900), linecolor=:black, legend=false)
xlims!(48000, 49000)



#correct the wvfs
using RadiationDetectorDSP

blstats_cut = signalstats.(wvfs_cut, 0u"µs", 10u"µs")
blstats_uncut = signalstats.(wvfs_uncut, 0u"µs", 10u"µs")

#baseline correction
wvfs_bl_cut = shift_waveform.(wvfs_cut, -blstats_cut.mean)
wvfs_bl_uncut = shift_waveform.(wvfs_uncut, -blstats_uncut.mean)
#plot
plot(wvfs_bl_cut[1], title="Waveform of $(dets[i])", xlabel="Time", ylabel="Amplitude [ADC]", framestyle=:box, fontfamily="Computer Modern", formatter=:plain, dpi=300, thickness_scaling=1.6, size=(1200,900), linecolor=:black, legend=false)
plot!(wvfs_bl_uncut[1], title="Waveform of $(dets[i])", xlabel="Time", ylabel="Amplitude [ADC]", framestyle=:box, fontfamily="Computer Modern", formatter=:plain, dpi=300, thickness_scaling=1.6, size=(1200,900), linecolor=:red, legend=false)
xlims!(45000, 55000)
wvf_data_uncut

offset = data_DEP_CUT[1].t0 - tabledata[398303].t0
#plot with t correct
plot(wvfs_bl_cut[1], title="Waveform of $(dets[i])", xlabel="Time", ylabel="Amplitude [ADC]", framestyle=:box, fontfamily="Computer Modern", formatter=:plain, 
dpi=300, thickness_scaling=2, size=(1200,900),linecolor=:black, label="Normal Waveform")
plot!(wvfs_bl_cut[1].time .+ offset, wvfs_bl_uncut[1].signal , title="Waveform of $(dets[i])", xlabel="Time", ylabel="Amplitude [ADC]", framestyle=:box, fontfamily="Computer Modern", 
formatter=:plain, dpi=300, thickness_scaling=2, size=(1200,900), linecolor=:red, label="LQ cutted Waveform")
xlims!(47500, 52500)
#savefig(joinpath("/home/iwsatlas1/agieb/Documents/Plots/NiceSlidePlots", "Waveform_$(dets[i]).png"))
=#