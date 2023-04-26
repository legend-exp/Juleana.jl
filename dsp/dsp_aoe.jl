include("../utils/packages.jl")
include("../utils/loader.jl")
include("../utils/utils.jl")

# global variables
enc_pickoff = 32u"µs"
bl_mean_min, bl_mean_max = 0u"µs", 39u"µs"
pz_fit_min, pz_fit_max = 80u"µs", 110u"µs"
t0_threshold = 5.0
# zac_filter_length = 30u"µs"

e_grid_rt = 7u"µs":0.5u"µs":12u"µs"
e_grid_ft = 1u"µs":0.2u"µs":4u"µs"

# function processChannel(wvfs_ch::RDWaveform, bl_fc::Vector, ts_ch::Array, evID_ch::Array, ch_ch::Array, efc_ch::Array, out_t::TypedTables.Table, τ::Float32)
function processChannel(wvfs_ch, bl_fc, ts_ch, evID_ch, ch_ch, efc_ch, out_t::TypedTables.Table, τ)
    # get baseline mean, std and slope
    bl_stats = signalstats.(wvfs_ch, bl_mean_min, bl_mean_max)

    # substract baseline from waveforms
    wvfs_ch = shift_waveform.(wvfs_ch, -bl_stats.mean)

    # deconvolute waveform
    deconv_flt = InvCRFilter(τ)
    wvfs_ch_pz = deconv_flt.(wvfs_ch)

    # get Q-drift parameter
    int_flt = IntegratorFilter(1)
    wvfs_flt_int = int_flt.(wvfs_ch_pz)

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

    area1 = SignalEstimator(PolynomialDNI(3, 100u"ns")).(wvfs_flt_int, t0 .+ 2.5u"µs") .- SignalEstimator(PolynomialDNI(3, 100u"ns")).(wvfs_flt_int, t0)
    area2 = SignalEstimator(PolynomialDNI(3, 100u"ns")).(wvfs_flt_int, t0 .+ 5u"µs")   .- SignalEstimator(PolynomialDNI(3, 100u"ns")).(wvfs_flt_int, t0 .+ 2.5u"µs")
    qdrift = area2 .- area1

    # extract current with filter length of 180ns with second order polynominal and first derivative
    sgflt_deriv = SavitzkyGolayFilter(180u"ns", 2, 1)
    wvfs_sgflt_deriv = sgflt_deriv.(wvfs_ch_pz)
    current_max = maximum.(wvfs_sgflt_deriv.signal)

    # save all data
    append!(out_t.channel, ch_ch)

    append!(out_t.blfc, bl_fc)
    append!(out_t.timestamp, ts_ch)
    append!(out_t.eventID_fadc, evID_ch)
    append!(out_t.e_fc, efc_ch)

    append!(out_t.qdrift, qdrift)
    
    append!(out_t.a, current_max)

    return 1
end

function processFile(filename::PosixPath, outfilename::PosixPath, decay_times::Dict{Int, Float32})
    out_data = LHDataStore(string(outfilename), "cw")
    
    if "DSP" in keys(out_data)
        println(format("Output file {} already exists, will skip", outfilename))
        close(out_data)
        return 0
    end

    data = LHDataStore(string(filename))["ORFlashCamADCWaveform"][:]

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
    out_t = TypedTables.Table(channel=Int[], 
    a = Float64[],
    qdrift = Float64[],
    blfc = Float64[], timestamp = Float64[]u"s", eventID_fadc = Int[], e_fc = Float64[],
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
            try
                filename = joinpath(data_folder, data_file)
            
                outfile = string("dsp_", split(data_file, "_")[2])
                outfilename = joinpath(out_data_folder, outfile)
    
                processFile(filename, outfilename, decay_times)
            catch e
                println(iter, format("Error processing file {}: {}", data_file, e))
            end
            # break
        end
    end
    return 1
end

# test DSP
config_folder = "/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts/configs/"
dsp(config_folder, 1, 25, "l60", true)