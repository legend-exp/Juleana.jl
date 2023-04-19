include("packages.jl")
include("utils.jl")

function cutLoader(channel_list::Array{Int}, cut_folder::String)
    in_data_folder = PosixPath(cut_folder)
    cutfile = joinpath(in_data_folder, "cuts.h5")

    printfmtln("Loading cut file {}", cutfile)
    return_dict = Dict{Int, Table}()

    if !exists(cutfile)
        println("No QC cuts found")
        return return_dict
    end
    cuts_table = LHDataStore(string(cutfile), "r")["QC"]
    channels = cuts_table.channel[:]
    for ch in channel_list
        ch_range = findfirst(channels .== ch):findlast(channels .== ch)
        printfmtln("Loading cuts for channel {} with {} events", ch, length(ch_range))
        return_dict[ch] = cuts_table[ch_range]
    end
    # close(cuts_table)
    return return_dict
end

# cut_folder = "/remote/ceph2/group/legendex/data/l60/r025/julia/cal/cut/"
# channel_list = [34, 6]
# cuts_table = LHDataStore(cut_folder*"cuts.h5", "r")["QC"]

# cuts = cutLoader(channel_list, cut_folder)

function runLoader(channel_list::Array{Int}, dsp_folder::String, load_grid::Bool = false)
    return_dict = Dict{Int, Any}()

    data_folder = PosixPath(dsp_folder)
    if !exists(data_folder)
        println("Input directory does not exist, exit script")
        return return_dict
    end

    println("Loading channels $channel_list")

    e_grid_rt = 1u"µs":0.5u"µs":12u"µs"
    e_grid_ft = 1u"µs":0.2u"µs":4u"µs"

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
            data = LHDataStore(string(filename), "r")["DSP"]

            channels = data.channel[:]
            printfmtln("Found {} events", length(channels))

            for ch in channel_list
                if !(ch in channels)
                    printfmtln("Channel {} is not in the list of channels to load, will skip", ch)
                    continue
                end
                
                # ch_range = searchsortedfirst(channels, ch):searchsortedlast(channels, ch)
                ch_range = findfirst(channels .== ch):findlast(channels .== ch)

                printfmtln("Loading channel {} with {} events.", ch, length(ch_range))

                if !load_grid
                    append!(return_dict[ch], deleteproperties(data[ch_range], (:e_grid, :enc_grid)))
                    continue
                end
                append!(return_dict[ch], data[ch_range])
                
            end

            # break
        end
    end

    return return_dict
end

# out_data_folder = "/remote/ceph2/group/legendex/data/l60/r025/julia/cal/dsp/"

# channel_list = [6]

# testData = runLoader(channel_list, out_data_folder, false)


function prepareDSP(configFolder::String; period::Int, run::Int, preName::String, cal::Bool)
    config_file_rel = ifelse(cal, format("config_{}-p{:02d}-r{:03d}_cal.json", preName, period, run), format("config_{}-p{:02d}-r{:03d}_phy.json", preName, period, run))
    config_file = joinpath(configFolder, config_file_rel)
    conf_dict = JSON.parsefile(config_file; dicttype=Dict, inttype=Int64, use_mmap=true)

    data_folder = PosixPath(conf_dict["folder"]["folder_raw"])
    out_data_folder = PosixPath(conf_dict["folder"]["folder_dsp"])

    checkFolder(data_folder)
    printfmtln("Using input folder {}", data_folder)

    checkFolder(out_data_folder, true)
    printfmtln("Using output folder {}", out_data_folder)

    # load config file
    string_numbers = conf_dict["default"]["strings"]

    printfmtln("Using strings {}", string_numbers)

    decay_times = Dict{Int, Float32}()
    for string_n in string_numbers
        conf_string = configLoader_string(string_n, config_file, Dict("tau"=>"tier2"))
        merge!(decay_times, Dict{Int, Float32}(conf_string["channel_list"] .=> conf_string["additionalKeys"]["tau"]))
    end
    return (data_folder, out_data_folder, string_numbers, decay_times)
end

function prepareDSP_FEP(configFolder::String; period::Int, run::Int, preName::String, cal::Bool)
    config_file_rel = ifelse(cal, format("config_{}-p{:02d}-r{:03d}_cal.json", preName, period, run), format("config_{}-p{:02d}-r{:03d}_phy.json", preName, period, run))
    config_file = joinpath(configFolder, config_file_rel)
    conf_dict = JSON.parsefile(config_file; dicttype=Dict, inttype=Int64, use_mmap=true)

    data_folder = PosixPath(conf_dict["folder"]["folder_raw"])
    out_data_folder = PosixPath(conf_dict["folder"]["folder_fep"])

    checkFolder(data_folder)
    printfmtln("Using input folder {}", data_folder)

    checkFolder(out_data_folder, true)
    printfmtln("Using output folder {}", out_data_folder)

    # load config file
    string_numbers = conf_dict["default"]["strings"]

    printfmtln("Using strings {}", string_numbers)

    decay_times = Dict{Int, Float32}()
    for string_n in string_numbers
        conf_string = configLoader_string(string_n, config_file, Dict("tau"=>"tier2"))
        merge!(decay_times, Dict{Int, Float32}(conf_string["channel_list"] .=> conf_string["additionalKeys"]["tau"]))
    end
    return (data_folder, out_data_folder, string_numbers, decay_times)
end


# data_folder, out_data_folder, string_numbers, decay_times = prepareDSP("/home/iwsatlas1/henkes/legend/julia/julia-dsp/configs/", period=1, run=25, preName="l60", cal=true)

function configLoader_string(det_string::Int, config_file::String, additionalKeys::Dict{String, String}=Dict{String, String}())

    det_string_name = format("String {}", det_string)

    conf_dict = JSON.parsefile(config_file; dicttype=Dict, inttype=Int64, use_mmap=true)

    channel_list = Int[]
    label_list = String[]
    label_listExt = String[]

    additionalKeys_dict = Dict{String, Array}()
    for key in keys(additionalKeys)
        additionalKeys_dict[key] = []
    end

    for (key, vals) in conf_dict
        if startswith(key, "g")
            # println(vals["label_ext"])
            if occursin(det_string_name, vals["label_ext"])
                channel = parse(Int, key[end-2:end])
                push!(channel_list, channel)
                push!(label_list, vals["label"])
                push!(label_listExt, vals["label_ext"])
                for key in keys(additionalKeys)
                    # println(vals["tier2"])
                    push!(additionalKeys_dict[key], parse(Float32, vals[additionalKeys[key]][key]))
                end
                printfmtln("Found detector {} at channel {}", vals["label_ext"], channel)
            end
        end
    end
    # println(typeof(label_list[1]))
    string_sort = sortperm(label_listExt, by=x->parse(Int, x[end-2:end-1]))
    # if isempty(additionalKeys)
    #     return Dict("channel_list"=>channel_list[string_sort], "label_list"=>label_list[string_sort], "label_listExt"=>label_listExt[string_sort])
    # end
    for key in keys(additionalKeys)
        additionalKeys_dict[key] = additionalKeys_dict[key][string_sort]
    end
    return Dict("channel_list"=>channel_list[string_sort], "label_list"=>label_list[string_sort], "label_listExt"=>label_listExt[string_sort], "additionalKeys"=>additionalKeys_dict)

end

# config_file = "/home/iwsatlas1/henkes/legend/julia/julia-dsp/configs/config_l60_r025.json" # configs/config_l60_r025.json"

# additionalKeys = Dict("tau"=>"tier2")
# a = configLoader_string(1, config_file, Dict("tau"=>"tier2", "n_bins"=>"tier2"))
# a = configLoader_string(1, config_file)


function prepareHit(configFolder::String; period::Int, run::Int, preName::String, cal::Bool, stringsToLoad::Array{Int}, additionalKeys::Dict{String, String}=Dict{String, String}(), load_grid::Bool=false)
    config_file_rel = ifelse(cal, format("config_{}-p{:02d}-r{:03d}_cal.json", preName, period, run), format("config_{}-p{:02d}-r{:03d}_phy.json", preName, period, run))
    config_file = joinpath(configFolder, config_file_rel)
    conf_dict = JSON.parsefile(config_file; dicttype=Dict, inttype=Int64, use_mmap=true)


    dsp_folder = PosixPath(conf_dict["folder"]["folder_dsp"])
    hit_folder = PosixPath(conf_dict["folder"]["folder_hit"])
    cut_folder = PosixPath(conf_dict["folder"]["folder_cut"])
    figure_folder = PosixPath(conf_dict["folder"]["folder_figures"])

    checkFolder(dsp_folder)
    printfmtln("Using DSP folder {}", dsp_folder)

    checkFolder(hit_folder, true)
    printfmtln("Using hit folder {}", hit_folder)

    checkFolder(cut_folder)
    printfmtln("Using cut folder {}", cut_folder)

    if !exists(figure_folder)
        println("Figure directory does not exist, create it")
        mkpath(figure_folder)
    end
    
    printfmtln("Using figure folder {}", figure_folder)

    # load config file
    string_numbers = conf_dict["default"]["strings"]

    printfmtln("Using strings {}", stringsToLoad)
    
    data_strings, qc_cuts = Dict{Int, Any}(), Dict{Int, Any}()
    for string_number in string_numbers
        if !(string_number in stringsToLoad)
            continue
        end
        printfmtln("Loading string: {}", string_number)
        println()
        println()
    
        # Load config file
    
        channel_dict = configLoader_string(string_number, config_file, additionalKeys)
        channel_list, label_listExt, label_list, additionalKeys_dict = channel_dict["channel_list"], channel_dict["label_listExt"], channel_dict["label_list"], channel_dict["additionalKeys"]
    
        dsp_data = runLoader(channel_list, string(dsp_folder), load_grid)
        data_strings[string_number] = [dsp_data, channel_list, label_listExt, label_list, additionalKeys_dict]
        
        qc_cuts[string_number] = cutLoader(channel_list, string(cut_folder))
    end

    return (dsp_folder, hit_folder, cut_folder, figure_folder, string_numbers, data_strings, qc_cuts)
end

# config_folder = "/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts/configs/"

# period, run, preName, cal = 1, 25, "l60", true
# dsp_folder, hit_folder, cut_folder, figure_folder, string_numbers, data_strings, qc_cuts = prepareHit(config_folder, period=period, run=run, preName=preName, cal=cal, stringsToLoad=[1])



