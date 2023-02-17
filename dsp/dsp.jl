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
include("../utils/utils.jl")

# global variables
enc_pickoff = 32u"µs"
bl_mean_min, bl_mean_max = 0u"µs", 39u"µs"
pz_fit_min, pz_fit_max = 80u"µs", 110u"µs"
t0_threshold = 5.0

e_grid_rt = 1u"µs":0.5u"µs":12u"µs"
e_grid_ft = 1u"µs":0.2u"µs":4u"µs"

# function processChannel(wvfs_ch::RDWaveform, bl_fc::Vector, ts_ch::Array, evID_ch::Array, ch_ch::Array, efc_ch::Array, out_t::TypedTables.Table, τ::Float32)
function processChannel(wvfs_ch, bl_fc, ts_ch, evID_ch, ch_ch, efc_ch, out_t::TypedTables.Table, τ)
    # get baseline mean, std and slope
    bl_stats = signalstats.(wvfs_ch, bl_mean_min, bl_mean_max)

    # pretrace difference 
    pretrace_diff = flatview(wvfs_ch.signal)[1, :] - bl_stats.mean

    # substract baseline from waveforms
    wvfs_ch = shift_waveform.(wvfs_ch, -bl_stats.mean)

    # deconvolute waveform
    deconv_flt = InvCRFilter(τ)
    wvfs_ch_pz = deconv_flt.(wvfs_ch)

    # extract decay times
    decay_times_extracted = tailstats.(wvfs_ch, pz_fit_min, pz_fit_max)

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
    # flt_trunc_qdrift_A1 = IntegrateFilter(t0, t0 .+ 2.5u"µs")
    # flt_trunc_qdrift_A2 = TruncateFilter(0u"µs"..60u"µs")

    # extract energy and ENC noise param from maximum of filtered wvfs
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


    # get energy grid for efficient optimization
    e_grid   = zeros(Float32, length(e_grid_ft), length(e_grid_rt), length(wvfs_ch_pz))
    enc_grid = zeros(Float32, length(e_grid_ft), length(e_grid_rt), length(wvfs_ch_pz))
    for (f, ft) in enumerate(e_grid_ft)
        for (r, rt) in enumerate(e_grid_rt)
            if rt < ft
                continue
            end
            uflt_rtft      = TrapezoidalChargeFilter(rt, ft)
            
            wvfs_flt_rtft  = uflt_rtft.(wvfs_ch_pz)

            e_rtft         = SignalEstimator(PolynomialDNI(4, 80u"ns")).(wvfs_flt_rtft, t0 .+ (rt + ft/2))
            enc_rtft       = SignalEstimator(PolynomialDNI(4, 80u"ns")).(wvfs_flt_rtft, enc_pickoff)

            e_grid[f, r, :]     = e_rtft
            enc_grid[f, r, :]   = enc_rtft
        end
    end

    # extract current with filter length of 180ns with second order polynominal and first derivative
    sgflt_deriv = SavitzkyGolayFilter(180u"ns", 2, 1)
    wvfs_sgflt_deriv = sgflt_deriv.(wvfs_ch_pz)
    current_max = maximum.(wvfs_sgflt_deriv.signal)

    # save all data
    append!(out_t.channel, ch_ch)


    append!(out_t.blmean, bl_stats.mean)
    append!(out_t.blsigma, bl_stats.sigma)
    append!(out_t.blslope, bl_stats.slope)
    append!(out_t.bloffset, bl_stats.offset)
    
    append!(out_t.τ_extracted, decay_times_extracted)
    append!(out_t.τ, zeros(length(ch_ch))u"µs" .+ τ)
    append!(out_t.t0, t0)
    
    append!(out_t.e_10410, e_10410)
    append!(out_t.enc_10410, enc_10410)
    append!(out_t.e_10210, e_10210)
    append!(out_t.enc_10210, enc_10210)
    append!(out_t.e_848, e_848)
    append!(out_t.enc_848, e_848)
    append!(out_t.e_434, e_434)
    append!(out_t.enc_434, enc_434)

    for arr in VectorOfSimilarArrays(e_grid)
        push!(out_t.e_grid, arr)
    end

    for arr in VectorOfSimilarArrays(enc_grid)
        push!(out_t.enc_grid, arr)
    end


    append!(out_t.a, current_max)

    append!(out_t.blfc, bl_fc)
    append!(out_t.timestamp, ts_ch)
    append!(out_t.eventID_fadc, evID_ch)
    append!(out_t.e_fc, efc_ch)

    append!(out_t.pretrace_diff, pretrace_diff)

    append!(out_t.rt1090, rt1090)
    append!(out_t.rt1099, rt1099)
    append!(out_t.rt9099, rt9099)
    append!(out_t.drift_time, drift_time)

    return 1
end

function processFile(filename::PosixPath, outfilename::PosixPath, decay_times::Dict{Int, Float32})
    data = LHDataStore(string(filename))["ORFlashCamADCWaveform"][:]
    out_data = LHDataStore(string(outfilename), "cw")

    if "DSP" in keys(out_data)
        println(format("Output file {} already exists, will skip", outfile))
        close(out_data)
        return 0
    end

    channels     = 6* data.card + data.ch_orca
    wvfs         = data.waveform
    baselines_fc = data.baseline
    timestamps   = data.timestamp
    eventID_fadc = data.eventnumber
    energy_fadc  = data.daqenergy

    println("Loaded data")
    println("Number of events: ", length(wvfs))

    # split waveforms channelwise
    sortindices      = sortperm(channels, alg=ThreadsX.QuickSort)

    channels_sorted     = channels[sortindices]
    wvfs_sorted         = wvfs[sortindices]
    baselines_fc_sorted = baselines_fc[sortindices]
    timestamps_sorted   = timestamps[sortindices]
    eventID_fadc_sorted = eventID_fadc[sortindices]
    energy_fadc_sorted  = energy_fadc[sortindices]
    
    con_ch_view    = consgroupedview(channels_sorted, channels_sorted)
    con_wvf_view   = consgroupedview(channels_sorted, wvfs_sorted)
    con_bl_fc_view = consgroupedview(channels_sorted, baselines_fc_sorted)
    con_ts_view    = consgroupedview(channels_sorted, timestamps_sorted)
    con_evID_view  = consgroupedview(channels_sorted, eventID_fadc_sorted)
    con_e_fc_view  = consgroupedview(channels_sorted, energy_fadc_sorted)

    # output Table 
    out_t = TypedTables.Table(channel=Int[], blmean = Float64[], blsigma = Float64[], blslope = Float64[]u"ns^-1", bloffset = Float64[], 
    τ_extracted = Float64[]u"µs", τ = Float64[]u"µs", t0 = Float64[]u"µs",
    e_10410 = Float64[], enc_10410 = Float64[], e_10210 = Float64[], enc_10210 = Float64[], e_848 = Float64[], enc_848 = Float64[], e_434 = Float64[], enc_434 = Float64[],
    e_grid = VectorOfSimilarArrays(ElasticArray{Float32}(undef, length(e_grid_ft), length(e_grid_rt), 0)), enc_grid = VectorOfSimilarArrays(ElasticArray{Float32}(undef, length(e_grid_ft), length(e_grid_rt), 0)),
    a = Float64[],
    blfc = Float64[], timestamp = Float64[]u"s", eventID_fadc = Int[], e_fc = Float64[],
    pretrace_diff = Float64[], 
    rt1090 = Float64[]u"ns", rt1099 = Float64[]u"ns", rt9099 = Float64[]u"ns", drift_time = Float64[]u"ns"
    )

    for (i, wvfs_ch) in enumerate(con_wvf_view)
        blfc_ch = con_bl_fc_view[i]
        ts_ch   = con_ts_view[i]
        evID_ch = con_evID_view[i]
        ch_ch   = con_ch_view[i]
        efc_ch  = con_e_fc_view[i]

        ch = ch_ch[1]

        # println("\nChannel: ", ch)
        # println("Number of events: ", length(wvfs_ch))
        if length(wvfs_ch) < 2
            # println("Skip channel")
            continue
        end
        if !haskey(decay_times, ch)
            # println("Skip channel")
            continue
        end

        processChannel(wvfs_ch, blfc_ch, ts_ch, evID_ch, ch_ch, efc_ch, out_t, decay_times[ch]u"µs")

    end
    

    # write data to HDF5
    out_data["DSP"] = out_t
    close(out_data)

    printfmtln("Finished processing file: {}", FilePathsBase.filename(filename))

    return 1
end


function dsp(config_folder::String, period::Int, run::Int, preName::String, cal::Bool)
    println("Starting DSP\n\n")
    printfmtln("Using {} threads\n\n", Threads.nthreads())

    data_folder, out_data_folder, string_numbers, decay_times = prepareDSP(config_folder, period=period, run=run, preName=preName, cal=cal)

    println()
    println()

    for (root, dirs, files) in walkdir(data_folder)
        iter = ProgressBar(files)
        for data_file in iter
            
            if splitext(data_file)[2] != ".lh5"
                println(iter, format("File {} is not a HDF5 file, will Skip", data_file))
                continue
            end

            filename = joinpath(data_folder, data_file)
            
            outfile = string("dsp_", split(data_file, "_")[2])
            outfilename = joinpath(out_data_folder, outfile)

            processFile(filename, outfilename, decay_times)
            break
        end
    end
    return 1
end

# test DSP
# conf_folder = "/home/iwsatlas1/henkes/legend/julia/julia-dsp/configs/"
# dsp(conf_folder, 1, 25, "l60", true)