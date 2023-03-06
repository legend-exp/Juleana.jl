include("../utils/packages.jl")
include("../utils/loader.jl")
include("../utils/utils.jl")

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

function dsp_FEP(config_folder::String, period::Int, run::Int, preName::String, cal::Bool)
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



println("Starting DSP\n\n")
printfmtln("Using {} threads\n\n", Threads.nthreads())

data_folder, out_data_folder, string_numbers, decay_times = prepareDSP_FEP(config_folder, period=period, run=run, preName=preName, cal=cal)

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