include("../utils/packages.jl")
include("../utils/loader.jl")
include("../utils/utils.jl")

# global variables
bl_mean_min, bl_mean_max = 0u"µs", 39u"µs"
pz_fit_min, pz_fit_max = 80u"µs", 110u"µs"
t0_threshold = 5.0


# function processChannel(wvfs_ch::RDWaveform, bl_fc::Vector, ts_ch::Array, evID_ch::Array, ch_ch::Array, efc_ch::Array, out_t::TypedTables.Table, τ::Float32)
function processChannel(wvfs_ch, bl_fc, ts_ch, evID_ch, efc_ch, τ, rt, ft)
    # get baseline mean, std and slope
    bl_stats = signalstats.(wvfs_ch, bl_mean_min, bl_mean_max)

    # pretrace difference 
    pretrace_diff = flatview(wvfs_ch.signal)[1, :] - bl_stats.mean

    # substract baseline from waveforms
    wvfs_ch = shift_waveform.(wvfs_ch, -bl_stats.mean)

    # extract decay times
    decay_times_extracted = tailstats.(wvfs_ch, pz_fit_min, pz_fit_max)

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

    # output Table 
    return TypedTables.Table(blmean = bl_stats.mean, blsigma = bl_stats.sigma, blslope = bl_stats.slope, bloffset = bl_stats.offset, 
    t0 = t0, τ = decay_times_extracted,
    e_10410 = e_10410, e_zac_10410 = e_zac_10410,
    e_trap = e_rtft,
    qdrift = qdrift,
    a = current_max,
    blfc = bl_fc, timestamp = ts_ch, eventID_fadc = evID_ch, e_fc = efc_ch,
    pretrace_diff = pretrace_diff, 
    rt1090 = rt1090, rt1099 = rt1099, rt9099 = rt9099, drift_time = drift_time
    )
end

function processFile(filename::String, outfilename::String, channel_list::Array{String}, decay_times::Dict{String, Any}, trap_rt::Dict{String, Any}, trap_ft::Dict{String, Any})
    data = LHDataStore(filename)
    out_data = LHDataStore(outfilename, "cw")

    for ch in channel_list
        if ch in keys(out_data)
            println(format("Channel {} already processed, will skip", ch))
            continue
        end
        println("Processing channel $ch")
        data_ch = data[format("{}/raw", ch)][:]
        
        wvfs_ch      = data_ch.waveform
        blfc_ch      = data_ch.baseline
        ts_ch        = data_ch.timestamp
        evID_ch      = data_ch.eventnumber
        efc_ch       = data_ch.daqenergy

        println("Loaded data")
        println("Number of events: ", length(wvfs_ch))

        if length(wvfs_ch) < 2
            continue
        end
        if !haskey(decay_times, ch)
            continue
        end

        out_data[ch] = processChannel(wvfs_ch, blfc_ch, ts_ch, evID_ch, efc_ch, decay_times[ch], trap_rt[ch], trap_ft[ch])

    end
    

    # close data file
    close(out_data)

    printfmtln("Finished processing file: {}", FilePathsBase.filename(PosixPath(filename)))

    return 1
end


function dsp(config_folder::PosixPath, period::Int, calrun::Int, experiment::String, is_cal::Bool)
    println("Starting DSP\n\n")
    printfmtln("Using {} threads\n\n", Threads.nthreads())

    channel_list, label_dict, label_list_ext, string_dict, folder_dict = loadMeta(config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)

    channel_label_dict = Dict{String, String}(values(label_dict) .=> keys(label_dict))

    decay_times = loadValues(collect(values(label_dict)), "tau", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
    decay_times = Dict{String, Any}([channel_label_dict[k] for k in keys(decay_times)] .=> values(decay_times).*1u"µs")

    trap_rt     = loadValues(collect(values(label_dict)), "trap_rt", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
    trap_rt     = Dict{String, Any}([channel_label_dict[k] for k in keys(trap_rt)] .=> values(trap_rt).*1u"µs")

    trap_ft     = loadValues(collect(values(label_dict)), "trap_ft", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
    trap_ft     = Dict{String, Any}([channel_label_dict[k] for k in keys(trap_ft)] .=> values(trap_ft).*1u"µs")

    folder_raw, folder_dsp = folder_dict["folder_raw"], folder_dict["folder_dsp"]
    checkFolder(PosixPath(folder_dsp), true)

    for (root, dirs, files) in walkdir(folder_raw)
        iter = ProgressBar(files)
        for data_file in iter
            
            if splitext(data_file)[2] != ".lh5"
                println(iter, format("File {} is not a HDF5 file, will Skip", data_file))
                continue
            end

            filename = joinpath(folder_raw, data_file)
            
            outfile = string(split(data_file, "_")[1], "_dsp.lh5")
            outfilename = joinpath(folder_dsp, outfile)

            processFile(filename, outfilename, channel_list, decay_times, trap_rt, trap_ft)
            break
        end
    end
    return 1
end

# test DSP
# is_cal = true
# period = 2
# calrun = 6
# config_folder = p"/home/iwsatlas1/henkes/l200/l200-p02-analysis/configs/"
# experiment = "l200"
# dsp(config_folder, period, calrun, experiment, is_cal)