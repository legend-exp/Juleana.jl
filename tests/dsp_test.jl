include("../utils/packages.jl")
include("../utils/loader.jl")
include("../utils/utils.jl")
using LegendDSP

# global variables
bl_mean_min, bl_mean_max = 0u"µs", 39u"µs"
pz_fit_min, pz_fit_max = 80u"µs", 110u"µs"
t0_threshold = 5.0

plotlyjs()

is_cal = true
period = 2
calrun = 6
config_folder = p"/home/iwsatlas1/henkes/l200/p02/configs/"
experiment = "l200"

channel_list, label_dict, label_list_ext, string_dict, folder_dict = loadMeta(config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)

channel_label_dict = Dict{String, String}(values(label_dict) .=> keys(label_dict))


decay_times = loadValues(collect(values(label_dict)), "tau", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
decay_times = Dict{String, Any}([channel_label_dict[k] for k in keys(decay_times)] .=> values(decay_times).*1u"µs")

trap_rt     = loadValues(collect(values(label_dict)), "trap_rt", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
trap_rt     = Dict{String, Any}([channel_label_dict[k] for k in keys(trap_rt)] .=> values(trap_rt).*1u"µs")

trap_ft     = loadValues(collect(values(label_dict)), "trap_ft", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
trap_ft     = Dict{String, Any}([channel_label_dict[k] for k in keys(trap_ft)] .=> values(trap_ft).*1u"µs")

ch = "ch008"

τ = decay_times[ch]
rt = trap_rt[ch]
ft = trap_ft[ch]

filename = "/remote/ceph/group/legendex/data/l200/raw/cal/p02/r006/l200-p02-r006-cal-20221226T193732Z-tier_raw.lh5"
data_ch = LHDataStore(filename, "r")["$ch/raw"][:]

wvfs_ch      = data_ch.waveform
blfc_ch      = data_ch.baseline
ts_ch        = data_ch.timestamp
evID_ch      = data_ch.eventnumber
efc_ch       = data_ch.daqenergy

plot(wvfs_ch[1:10])

# get baseline mean, std and slope
bl_stats = signalstats.(wvfs_ch, bl_mean_min, bl_mean_max)

# pretrace difference 
pretrace_diff = flatview(wvfs_ch.signal)[1, :] - bl_stats.mean

# substract baseline from waveforms
wvfs_ch = shift_waveform.(wvfs_ch, -bl_stats.mean)

# extract decay times
decay_times_extracted = tailstats.(wvfs_ch, pz_fit_min, pz_fit_max)
histogram(uconvert.(u"µs", decay_times_extracted), bins=900, xrange=(0, 1000))

# deconvolute waveform
deconv_flt = InvCRFilter(τ)
wvfs_ch_pz = deconv_flt.(wvfs_ch)

# t0 determination
# filter with fast asymetric trapezoidal filter and truncate waveform
uflt_asy_t0 = TrapezoidalChargeFilter(40u"ns", 100u"ns", 2000u"ns")
uflt_trunc_t0 = TruncateFilter(0u"µs"..60u"µs")

# eventuell zwei schritte!!!
wvfs_flt_asy_t0 = uflt_asy_t0.(uflt_trunc_t0.(wvfs_ch_pz))

# get intersect at t0 threshold (fixed as in MJD analysis)
flt_intersec_t0 = Intersect(mintot = 600u"ns")

# get t0 for every waveform as pick-off at fixed threshold
t0 = uconvert.(u"µs", flt_intersec_t0.(wvfs_flt_asy_t0, t0_threshold).x)

# get risetimes and drift times by intersection
flt_intersec_90RT = Intersect(mintot = 100u"ns")
flt_intersec_99RT = Intersect(mintot = 20u"ns")
flt_intersec_lowRT = Intersect(mintot = 600u"ns")

wvf_max = maximum.(wvfs_ch.signal)

rt1090     = uconvert.(u"ns", flt_intersec_90RT.(wvfs_ch_pz, wvf_max .* 0.9).x - flt_intersec_lowRT.(wvfs_ch_pz, wvf_max .* 0.1).x)
rt1099     = uconvert.(u"ns", flt_intersec_99RT.(wvfs_ch_pz, wvf_max .* 0.99).x - flt_intersec_lowRT.(wvfs_ch_pz, wvf_max .* 0.1).x)
rt9099     = uconvert.(u"ns", flt_intersec_99RT.(wvfs_ch_pz, wvf_max .* 0.99).x - flt_intersec_90RT.(wvfs_ch_pz, wvf_max .* 0.90).x)
drift_time = uconvert.(u"ns", flt_intersec_90RT.(wvfs_ch_pz, wvf_max .* 0.90).x - t0)

# get Q-drift parameter
int_flt = IntegratorFilter(1)
wvfs_flt_int = int_flt.(wvfs_ch_pz)

area1 = SignalEstimator(PolynomialDNI(3, 100u"ns")).(wvfs_flt_int, t0 .+ 2.5u"µs") .- SignalEstimator(PolynomialDNI(3, 100u"ns")).(wvfs_flt_int, t0)
area2 = SignalEstimator(PolynomialDNI(3, 100u"ns")).(wvfs_flt_int, t0 .+ 5u"µs")   .- SignalEstimator(PolynomialDNI(3, 100u"ns")).(wvfs_flt_int, t0 .+ 2.5u"µs")
qdrift = area2 .- area1

# extract energy and ENC noise param from maximum of filtered wvfs
uflt_10410 = TrapezoidalChargeFilter(10u"µs", 4u"µs")

wvfs_flt_10410 = uflt_10410.(wvfs_ch_pz)
e_10410        = SignalEstimator(PolynomialDNI(3, 100u"ns")).(wvfs_flt_10410, t0 .+ 12u"µs")

uflt_zac10410 = ZACChargeFilter(10u"µs", 4u"µs", 30u"µs")

wvfs_flt_zac10410 = uflt_zac10410.(wvfs_ch_pz)
e_zac_10410       = SignalEstimator(PolynomialDNI(3, 100u"ns")).(wvfs_flt_zac10410, t0 .+ 12u"µs")


# get energy of optimized rise and flat-top time
uflt_rtft = TrapezoidalChargeFilter(rt, ft)

wvfs_flt_rtft  = uflt_rtft.(wvfs_ch_pz)
e_rtft         = SignalEstimator(PolynomialDNI(3, 100u"ns")).(wvfs_flt_rtft, t0 .+ (rt + ft/2))


# extract current with filter length of 180ns with second order polynominal and first derivative
sgflt_deriv = SavitzkyGolayFilter(180u"ns", 2, 1)
wvfs_sgflt_deriv = sgflt_deriv.(wvfs_ch_pz)
current_max = maximum.(wvfs_sgflt_deriv.signal)
plot(wvfs_sgflt_deriv[1:10], label=permutedims(unix2datetime.(ustrip.(u"s", ts_ch[1:10]))))

deriv_stats = signalstats.(wvfs_sgflt_deriv, bl_mean_min + wvfs_sgflt_deriv.time[1][1], bl_mean_max)
inTraceCut = 10 .* deriv_stats.sigma

# uflt_trunc_inTrace = TruncateFilter(51u"µs"..wvfs_sgflt_deriv.time[1][end])
flt_intersec_inTrace = Intersect(mintot = 100u"ns")
# inTrace_n = flt_intersec_inTrace.(uflt_trunc_inTrace.(wvfs_sgflt_deriv), inTraceCut).multiplicity
inTrace_n = flt_intersec_inTrace.(wvfs_sgflt_deriv, inTraceCut).multiplicity

wvfs_pileUp =  wvfs_ch[inTrace_n .> 1]
wvfs_deriv_pileUp = wvfs_sgflt_deriv[inTrace_n .> 1]
ts_pileUp = ts_ch[inTrace_n .> 1]

p = palette(:tab10)
plot(wvfs_pileUp[2:3], label=permutedims(unix2datetime.(ustrip.(u"s", ts_pileUp[2:3]))), legend=:topleft, color=permutedims(p[1:2]))
plot(wvfs_deriv_pileUp[2:3], label=permutedims(unix2datetime.(ustrip.(u"s", ts_pileUp[2:3]))), legend=:topleft, color=permutedims(p[1:2]), showlegend=false)


hline!([c for c in inTraceCut[inTrace_n .> 1][2:3]], label=permutedims(unix2datetime.(ustrip.(u"s", ts_pileUp[2:3]))), p=permutedims(p[1:2]))
vline!(t0[inTrace_n .> 1][2:3] .+ 3u"µs", label=permutedims(unix2datetime.(ustrip.(u"s", ts_ch[inTrace_n .> 1][2:3]))))

