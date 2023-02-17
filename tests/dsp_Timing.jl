using RadiationDetectorDSP
using Plots
using LegendHDF5IO
using Unitful
using RadiationDetectorSignals
using Statistics
using GLM
using LinearRegression
using InverseFunctions
using ArraysOfArrays
using TypedTables
using BenchmarkTools
using LaTeXStrings
using Measures
using HDF5
using ProgressBars
using FilePathsBase
using Formatting
using Base
using ConfParser
using IntervalSets
using ThreadsX
using DataFrames
using ElasticArrays

include("../utils/loader.jl")

data_folder = p"/remote/ceph2/group/legend/henkes/l60/r025/cal/tier1/"
if !exists(data_folder)
    println("Input directory does not exist, exist script")
    exit(86)
end
printfmtln("Using input folder {}", data_folder)

out_data_folder = p"/remote/ceph2/group/legend/henkes/l60/r025/julia/cal/tier2_test/"
if !exists(out_data_folder)
    println("Output directory does not exist, create it")
    mkpath(out_data_folder)
end
printfmtln("Using output folder {}", out_data_folder)

# Load config and decay times
config_file = "/home/iwsatlas1/henkes/legend/julia/julia-dsp/configs/config_l60-p01-r025_cal.json"
string_numbers = [1, 2, 7, 8]

printfmtln("Using strings {}", string_numbers)
decay_times = Dict{Int, Float32}()

for string_n in string_numbers
    conf_string = configLoader_string(string_n, config_file, Dict("tau"=>"tier2"))
    merge!(decay_times, Dict{Int, Float32}(conf_string["channel_list"] .=> conf_string["additionalKeys"]["tau"]))
end

# gloabl variables
enc_pickoff = 32u"µs"
bl_mean_min, bl_mean_max = 0u"µs", 39u"µs"
pz_fit_min, pz_fit_max = 80u"µs", 110u"µs"
t0_threshold = 5.0

e_grid_rt = 1u"µs":0.5u"µs":12u"µs"
e_grid_ft = 1u"µs":0.2u"µs":4u"µs"

data_file = "tier1_l60-p01-r025-cal-20220909T210409Z.lh5"

using TimerOutputs

timerout = TimerOutput()

filename = joinpath(data_folder, data_file)

# outfile = string("tier2_", split(data_file, "_")[2])
# outfilename = joinpath(out_data_folder, outfile)

@timeit timerout "Load data" data = LHDataStore(string(filename))["ORFlashCamADCWaveform"][:]
# out_data = LHDataStore(string(outfilename), "cw")


wvfs         = data.waveform
baselines_fc = data.baseline
timestamps   = data.timestamp
eventID_fadc = data.eventnumber
channels     = 6* data.card + data.ch_orca

println("Loaded data")
println("Number of events: ", length(wvfs))
# println(wvfs)

# split waveforms channelwise
@timeit timerout "Sort data" begin
    sortindices      = sortperm(channels, alg=ThreadsX.QuickSort)
    wvfs_sorted      = wvfs[sortindices]
    channels_sorted  = channels[sortindices]
    baselines_fc_sorted = baselines_fc[sortindices]
    
    con_ch_view = consgroupedview(channels_sorted, channels_sorted)
    con_wvf_view = consgroupedview(channels_sorted, wvfs_sorted)
    con_bl_fc_view = consgroupedview(channels_sorted, baselines_fc_sorted)
end

function DSPTest(decay_times::Dict{Int, Float32}, timer::TimerOutput)

    # # output Table 
    # out_t = TypedTables.Table(channel=Int[], blmean = Float64[], blsigma = Float64[], blslope = Float64[]u"ns^-1", bloffset = Float64[], 
    # τ_extracted = Float64[]u"µs", t0 = Float64[]u"µs",
    # e_10410 = Float64[], enc_10410 = Float64[], e_10210 = Float64[], enc_10210 = Float64[], e_848 = Float64[], enc_848 = Float64[], e_434 = Float64[], enc_434 = Float64[],
    # e_grid = VectorOfSimilarArrays(ElasticArray{Float32}(undef, length(e_grid_ft), length(e_grid_rt), 0)), enc_grid = VectorOfSimilarArrays(ElasticArray{Float32}(undef, length(e_grid_ft), length(e_grid_rt), 0)),
    # a = Float64[],
    # blfc = Float64[], timestamp = Float64[]u"s", eventID_fadc = Int[],
    # pretrace_diff = Float64[], 
    # rt1090 = Float64[]u"ns", rt1099 = Float64[]u"ns", rt9099 = Float64[]u"ns", drift_time = Float64[]u"ns"
    # )

    for (i, wvfs_ch) in enumerate(con_wvf_view)
        ch = con_ch_view[i][1]
        if ch != 7
            continue
        end
        # bl_fc = con_bl_fc_view[i][1:1000]
        bl_fc = con_bl_fc_view[i]
        # wvfs_ch = wvfs_ch[1:1000]
        # wvfs_ch = wvfs_ch[i]
        println("\nChannel: ", ch)
        println("Number of events: ", length(wvfs_ch))
        if length(wvfs_ch) < 2
            println("Skip channel")
            continue
        end
        if !haskey(decay_times, ch)
            println("Skip channel")
            continue
        end

        printfmtln("WVF length: {}", length(wvfs_ch.signal[1]))

        # get baseline mean, std and slope
        @timeit timer format("CH{} BL stats", ch) bl_stats = signalstats.(wvfs_ch, bl_mean_min, bl_mean_max)

        # pretrace difference 
        @timeit timer format("CH{} Pretrace diff", ch) pretrace_diff = flatview(wvfs_ch.signal)[1, :] - bl_stats.mean

        # substract baseline from waveforms
        @timeit timer format("CH{} Shift wvf", ch) wvfs_ch = shift_waveform.(wvfs_ch, -bl_stats.mean)
        # @timeit timer format("CH{} Shift wvf", ch) wvfs_ch = shift_waveform.(wvfs_ch, -bl_fc)
        global wvfs_ch_test = wvfs_ch
        # deconvolute waveform
        τ = decay_times[ch]u"µs"
        deconv_flt = InvCRFilter(τ)
        @timeit timer format("CH{} Deconvolution", ch) wvfs_ch_pz = deconv_flt.(wvfs_ch)

        # extract decay times
        @timeit timer format("CH{} Tail stats", ch) decay_times_extracted = tailstats.(wvfs_ch, pz_fit_min, pz_fit_max)
        # println(tail_stats[1:10])


        # t0 determination
        # filter with fast asymetric trapezoidal filter and truncate waveform
        uflt_asy_t0 = TrapezoidalChargeFilter(40u"ns", 100u"ns", 2000u"ns")
        uflt_trunc_t0 = TruncateFilter(0u"µs"..60u"µs")


        # eventuell zwei schritte!!!
        @timeit format("CH{} t0 filter", ch) wvfs_flt_asy_t0 = uflt_asy_t0.(uflt_trunc_t0.(wvfs_ch_pz))

        # get intersect at t0 threshold (fixed as in MJD analysis)
        flt_intersec_t0 = Intersect(mintot = 600u"ns")

        # get t0 for every waveform as pick-off at fixed threshold
        @timeit timer format("CH{} t0 extract", ch) t0 = uconvert.(u"µs", flt_intersec_t0.(wvfs_flt_asy_t0, t0_threshold).x)

        # get risetimes and drift times by intersection
        flt_intersec_90RT = Intersect(mintot = 100u"ns")
        flt_intersec_99RT = Intersect(mintot = 20u"ns")
        flt_intersec_lowRT = Intersect(mintot = 600u"ns")
        
        @timeit timer format("CH{} Risetimes", ch) begin
            wvf_max = maximum.(wvfs_ch.signal)

            rt1090     = uconvert.(u"ns", flt_intersec_90RT.(wvfs_ch_pz, wvf_max .* 0.9).x - flt_intersec_lowRT.(wvfs_ch_pz, wvf_max .* 0.1).x)
            rt1099     = uconvert.(u"ns", flt_intersec_99RT.(wvfs_ch_pz, wvf_max .* 0.99).x - flt_intersec_lowRT.(wvfs_ch_pz, wvf_max .* 0.1).x)
            rt9099     = uconvert.(u"ns", flt_intersec_99RT.(wvfs_ch_pz, wvf_max .* 0.99).x - flt_intersec_90RT.(wvfs_ch_pz, wvf_max .* 0.90).x)
            drift_time = uconvert.(u"ns", flt_intersec_90RT.(wvfs_ch_pz, wvf_max .* 0.90).x - t0)
        end

        # get Q-drift parameter
        # flt_trunc_qdrift_A1 = IntegrateFilter(t0, t0 .+ 2.5u"µs")
        # flt_trunc_qdrift_A2 = TruncateFilter(0u"µs"..60u"µs")

        # extract energy and ENC noise param from maximum of filtered wvfs
        @timeit timer format("CH{} Energy", ch) begin
            uflt_10410 = TrapezoidalChargeFilter(10u"µs", 4u"µs")
            uflt_10210 = TrapezoidalChargeFilter(10u"µs", 2u"µs")
            uflt_848   = TrapezoidalChargeFilter(8u"µs", 4u"µs")
            uflt_434   = TrapezoidalChargeFilter(4u"µs", 3u"µs")

            wvfs_flt_10410 = uflt_10410.(wvfs_ch_pz)
            e_10410        = SignalEstimator(PolynomialDNI(3, 100u"ns")).(wvfs_flt_10410, t0 .+ 12u"µs")
            enc_10410      = SignalEstimator(PolynomialDNI(2, 150u"ns")).(wvfs_flt_10410, enc_pickoff)

            wvfs_flt_848   = uflt_848.(wvfs_ch_pz)
            e_848          = SignalEstimator(PolynomialDNI(4, 80u"ns")).(wvfs_flt_848, t0 .+ 10u"µs")
            enc_848        = SignalEstimator(PolynomialDNI(4, 80u"ns")).(wvfs_flt_848, enc_pickoff)

            wvfs_flt_434   = uflt_434.(wvfs_ch_pz)
            e_434          = SignalEstimator(PolynomialDNI(4, 80u"ns")).(wvfs_flt_434, t0 .+ 5.5u"µs")
            enc_434        = SignalEstimator(PolynomialDNI(4, 80u"ns")).(wvfs_flt_434, enc_pickoff)

            wvfs_flt_10210 = uflt_10210.(wvfs_ch_pz)
            e_10210        = SignalEstimator(PolynomialDNI(4, 80u"ns")).(wvfs_flt_10210, t0 .+ 11u"µs")
            enc_10210      = SignalEstimator(PolynomialDNI(4, 80u"ns")).(wvfs_flt_10210, enc_pickoff)
        end

        # get energy grid for efficient optimization
        global wvfs_ch_pz_ch7 =  wvfs_ch_pz
        global t0_ch7 = t0
        # return timer
        # @timeit timer format("CH{} Energy grid", ch) begin
        e_grid   = zeros(Float32, length(e_grid_ft), length(e_grid_rt), length(wvfs_ch_pz))
        enc_grid = zeros(Float32, length(e_grid_ft), length(e_grid_rt), length(wvfs_ch_pz))
        for (f, ft) in enumerate(e_grid_ft)
            
            for (r, rt) in enumerate(e_grid_rt)
                if rt < ft
                    continue
                end
                    
                uflt_rtft      = TrapezoidalChargeFilter(rt, ft)
                
                wvfs_flt_rtft  = @timeit timer "Trap filter" uflt_rtft.(wvfs_ch_pz)

                e_rtft         = @timeit timer "Sig Esti energy" SignalEstimator(PolynomialDNI(4, 80u"ns")).(wvfs_flt_rtft, t0 .+ (rt + ft/2))
                enc_rtft       = @timeit timer "Sig Esti ENC" SignalEstimator(PolynomialDNI(4, 80u"ns")).(wvfs_flt_rtft, enc_pickoff)

                e_grid[f, r, :]     = e_rtft
                enc_grid[f, r, :]   = enc_rtft

            end
        end
        # end
        # extract current with filter length of 180ns with second order polynominal and first derivative
        @timeit timer format("CH{} Current", ch) begin
            sgflt_deriv = SavitzkyGolayFilter(180u"ns", 2, 1)
            wvfs_sgflt_deriv = sgflt_deriv.(wvfs_ch_pz)
            current_max = maximum.(wvfs_sgflt_deriv.signal)
        end
        
    end

    return timer
end

# nthreads = [2, 4, 8, 16, 32, 64]
# for nthre in nthreads
#     Threads.nthreads() = nthre
#     println("Threads: ", Threads.nthreads())
#     result_timer = DSPTest(decay_times, timerout)
#     println(result_timer)
#     println()
# end

timerout = TimerOutput()
result_timer = DSPTest(decay_times, timerout)

trap_time = TimerOutputs.time(result_timer["Trap filter"]) *1e-9
trap_ncalls = TimerOutputs.ncalls(result_timer["Trap filter"])
trap_avg = trap_time / trap_ncalls *1e3
nthreads = Threads.nthreads()
test_data_folder = "/home/iwsatlas1/henkes/legend/julia/julia-dsp/tests/data/"
open(test_data_folder*"timing_filter.csv", "a") do io
    write(io, "$nthreads, $trap_time, $trap_ncalls, $trap_avg\n")
end
# e_grid   = zeros(Float32, length(e_grid_ft), length(e_grid_rt), length(wvfs_ch_pz_ch7))
# enc_grid = zeros(Float32, length(e_grid_ft), length(e_grid_rt), length(wvfs_ch_pz_ch7))
# @profview println(5)
# @profview for (f, ft) in enumerate(e_grid_ft)
#     for (r, rt) in enumerate(e_grid_rt)
#         if rt < ft
#             continue
#         end
#         uflt_rtft      = TrapezoidalChargeFilter(rt, ft)
        
#         wvfs_flt_rtft  = uflt_rtft.(wvfs_ch_pz_ch7)

#         e_rtft         = SignalEstimator(PolynomialDNI(4, 80u"ns")).(wvfs_flt_rtft, t0_ch7 .+ (rt + ft/2))
#         enc_rtft       = SignalEstimator(PolynomialDNI(4, 80u"ns")).(wvfs_flt_rtft, enc_pickoff)

#         e_grid[f, r, :]     = e_rtft
#         enc_grid[f, r, :]   = enc_rtft
#     end
# end