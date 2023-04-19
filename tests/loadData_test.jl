include("../utils/packages.jl")
include("../utils/utils.jl")

dsp_folder = "/remote/ceph2/group/legendex/data/l60/r025/julia/cal/dsp/"

channel_list = [34, 35]
load_grid = false

using TimerOutputs

timerout = TimerOutput()

return_dict = Dict{Int, Any}()

data_folder = PosixPath(dsp_folder)
if !exists(data_folder)
    println("Input directory does not exist, exit script")
    return return_dict
end

println("Loading channels $channel_list")

e_grid_rt = 1u"µs":0.5u"µs":12u"µs"
e_grid_ft = 1u"µs":0.2u"µs":4u"µs"

@timeit timerout "create dict" begin
    
    if load_grid
        for ch in channel_list
            return_dict[ch] = TypedTables.Table(channel=Int[], blmean = Float64[], blsigma = Float64[], blslope = Float64[]u"ns^-1", bloffset = Float64[], 
            τ_extracted = Float64[]u"µs", τ = Float64[]u"µs", t0 = Float64[]u"µs",
            e_10410 = Float64[], enc_10410 = Float64[], e_10210 = Float64[], enc_10210 = Float64[], e_848 = Float64[], enc_848 = Float64[], e_434 = Float64[], enc_434 = Float64[],
            e_grid = VectorOfSimilarArrays(ElasticArray{Float32}(undef, length(e_grid_ft), length(e_grid_rt), 0)), enc_grid = VectorOfSimilarArrays(ElasticArray{Float32}(undef, length(e_grid_ft), length(e_grid_rt), 0)),
            a = Float64[],
            blfc = Float64[], timestamp = Float64[]u"s", eventID_fadc = Int[], e_fc = Float64[],
            pretrace_diff = Float64[], 
            rt1090 = Float64[]u"ns", rt1099 = Float64[]u"ns", rt9099 = Float64[]u"ns", drift_time = Float64[]u"ns"
            )
        end
    else
        for ch in channel_list
            return_dict[ch] = TypedTables.Table(channel=Int[], blmean = Float64[], blsigma = Float64[], blslope = Float64[]u"ns^-1", bloffset = Float64[], 
            τ_extracted = Float64[]u"µs", τ = Float64[]u"µs", t0 = Float64[]u"µs",
            e_10410 = Float64[], enc_10410 = Float64[], e_10210 = Float64[], enc_10210 = Float64[], e_848 = Float64[], enc_848 = Float64[], e_434 = Float64[], enc_434 = Float64[],
            a = Float64[],
            blfc = Float64[], timestamp = Float64[]u"s", eventID_fadc = Int[], e_fc = Float64[],
            pretrace_diff = Float64[], 
            rt1090 = Float64[]u"ns", rt1099 = Float64[]u"ns", rt9099 = Float64[]u"ns", drift_time = Float64[]u"ns"
            )
        end
    end
end


for (root, dirs, files) in walkdir(data_folder)

    iter = ProgressBar(files)

    for data_file in iter
        
        if splitext(data_file)[2] != ".lh5"
            printfmtln("File {} is not a HDF5 file, will Skip", data_file)
            continue
        end

        filename = joinpath(data_folder, data_file)
        println(iter, "Loading file $data_file")

        # data = h5open(string(filename), "r")["DSP"]
        @timeit timerout "access HDF5" data = LHDataStore(string(filename), "r")

        @timeit timerout "Load channel" channels = data["DSP"].channel[:]
        printfmtln("Found {} events", length(channels))

        for ch in channel_list
            if !(ch in channels)
                printfmtln("Channel {} is not in the list of channels to load, will skip", ch)
                continue
            end
            
            # ch_range = searchsortedfirst(channels, ch):searchsortedlast(channels, ch)
            @timeit timerout "search channel" ch_range = findfirst(channels .== ch):findlast(channels .== ch)

            printfmtln("Loading channel {} with {} events.", ch, length(ch_range))

            if !load_grid
                @timeit timerout "append data" append!(return_dict[ch], deleteproperties(data["DSP"][ch_range], (:e_grid, :enc_grid)))
                continue
            end
            append!(return_dict[ch], data[ch_range])
            
        end

        # break
    end
end

