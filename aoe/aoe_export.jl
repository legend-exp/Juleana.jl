include("../utils/packages.jl")
include("../utils/loader.jl")
include("../utils/saver.jl")

data_folder = "/remote/ceph2/group/legendex/data/l60/r025/julia/cal/dsp_aoe"
aoe_dict = Dict{Int, TypedTables.Table}()

data_folder = PosixPath(dsp_folder)
if !exists(data_folder)
    println("Input directory does not exist, exit script")
    return Dict{Int, Any}()
end

println("Loading data from $data_folder")

first_file = true

for (root, dirs, files) in walkdir(data_folder)

    iter = ProgressBar(files)

    for data_file in iter
        
        if splitext(data_file)[2] != ".lh5"
            printfmtln("File {} is not a HDF5 file, will Skip", data_file)
            continue
        end

        filename = joinpath(data_folder, data_file)
        println(iter, "Loading file $data_file")

        try
            data = LHDataStore(string(filename), "r")["DSP"][:]
        catch e
            println(iter, "File $data_file is empty, will delete: $e")
            # rm(joinpath(data_folder, data_file))
            continue
        end
        data = LHDataStore(string(filename), "r")["DSP"][:]

        printfmtln("Found {} events", length(data.channel))
        
        data_perCH = consgroupedview(data.channel, data)

        if first_file
            for ch in map(x->first(x.channel), data_perCH)
                aoe_dict[ch] = TypedTables.Table(channel=Int[], 
                a = Float64[],
                qdrift = Float64[],
                blfc = Float64[], timestamp = Float64[]u"s", eventID_fadc = Int[], e_fc = Float64[],
                )
            end
            first_file = false
        end
        mergewith!(append!, aoe_dict, Dict(map(x->first(x.channel), data_perCH) .=> data_perCH))
    end
end
