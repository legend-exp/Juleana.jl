using LegendHDF5IO
using LIBSVM
using HDF5
using Unitful
using PropDicts
using LegendDataManagement
using TypedTables
using RadiationDetectorDSP
using LegendDSP
using ArraysOfArrays
using Plots

plotlyjs(size=(800, 500), thickness_scaling=2);
# module MyUnits; 
# using Unitful; 
# @unit ADC "ADC" analog_to_digital 1u"0.001*V" false; 
# end 

train_data = h5open("/home/iwsatlas1/eleon/legend_analysis/svm_tests/l200-p03-r000-phy-ml_train_dsp_old.lh5")
dwts_norm = Array(train_data["ml_train"]["dsp"]["dwt_norm"])
dc_labels = Array(train_data["ml_train"]["dsp"]["dc_label"])
hyperparams = readprops("/remote/ceph/group/legendex/data/l200/julia/current/generated/jlpar/rpars/ml/p03.json")

# labels should be of shape (n_samples,)
# y_train = rand(0.0:1.0, size(X_train, 2));
# class_weights = Dict(0.0=>1.0, 1.0=>0.1);
w = Dict(hyperparams.weights)
weights = Dict(parse.(Float64, string.(keys(hyperparams.weights))) .=> values(hyperparams.weights))
model = svmtrain(dwts_norm, dc_labels, 
                cost=hyperparams.cost, 
                kernel=LIBSVM.Kernel.RadialBasis, 
                gamma=hyperparams.gamma,
                weights = weights,
                probability=hyperparams.probability,
                cachesize=Float64(hyperparams.cache_size),
                coef0=hyperparams.coef0,
                shrinking=hyperparams.shrinking,
                tolerance=hyperparams.tolerance
                )


l200 = LegendData(:l200)
chinfo = Table(channelinfo(l200, (:p03, :r000, :cal); system=:geds, only_processable=true))
filekeys = search_disk(FileKey, l200.tier[:raw, :phy, :p03, :r000])

fk = filekeys[1]
dets = chinfo.detector
det = dets[2]

chinfo_ch = channelinfo(l200, fk, det)

data_ch = lh5open(l200.tier[:raw, fk])[chinfo_ch.channel].raw[:]

dsp_config = dataprod_config(l200).dsp(fk).default

wvfs = data_ch.waveform
blstats = signalstats.(wvfs, dsp_config.bl_window.min, dsp_config.bl_window.max)
wvfs_bl = shift_waveform.(wvfs, -blstats.mean)

haar_flt = HaarAveragingFilter(2)

wvfs_flt_haar5 = wvfs_bl .|> haar_flt .|> haar_flt .|> haar_flt .|> haar_flt .|> haar_flt;
plot(u"µs", NoUnits, yformatter=:plain)
plot!(wvfs_flt_haar5[1:10])

wvfs_extrema = extrema.(wvfs_flt_haar5.signal)
norm_fact = map(x -> max(abs(first(x)), abs(last(x))), extrema.(wvfs_flt_haar5.signal))

wvfs_flt_haar5_norm = multiply_waveform.(wvfs_flt_haar5, 1 ./ norm_fact)

plot(u"µs", NoUnits, yformatter=:plain)
plot!(wvfs_flt_haar5_norm[1:10])


signals = flatview(VectorOfSimilarArrays(wvfs_flt_haar5_norm.signal))
y_pred, decision_values = svmpredict(model, signals)
f_evaluate = Base.Fix1(svmpredict, model)
f_evaluate(signals)
wvfs_plot_range = 40:80
plot(u"µs", NoUnits, yformatter=:plain)
plot!(wvfs_flt_haar5_norm[wvfs_plot_range], label=permutedims(y_pred[wvfs_plot_range]))

save("svm_p03.jld", "f", f_evaluate)

model = load("svm_p03.jld")["model"]