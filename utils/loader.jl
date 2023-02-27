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

function OLD_runLoader(channel_list::Array{Int}, dsp_folder::String)
    return_dict = Dict{Int, Any}()

    data_folder = PosixPath(dsp_folder)
    if !exists(data_folder)
        println("Input directory does not exist, exit script")
        return return_dict
    end

    println("Loading channels $channel_list")

    e_grid_rt = 1u"µs":0.5u"µs":12u"µs"
    e_grid_ft = 1u"µs":0.2u"µs":4u"µs"

    for ch in channel_list
        return_dict[ch] = TypedTables.Table(channel=Int[], blmean = Float64[], blsigma = Float64[], blslope = Float64[]u"ns^-1", bloffset = Float64[], 
        τ_extracted = Float64[]u"µs", t0 = Float64[]u"µs",
        e_10410 = Float64[], enc_10410 = Float64[], e_10210 = Float64[], enc_10210 = Float64[], e_848 = Float64[], enc_848 = Float64[], e_434 = Float64[], enc_434 = Float64[],
        # e_grid = VectorOfSimilarArrays(ElasticArray{Float32}(undef, length(e_grid_ft), length(e_grid_rt), 0)), enc_grid = VectorOfSimilarArrays(ElasticArray{Float32}(undef, length(e_grid_ft), length(e_grid_rt), 0)),
        a = Float64[],
        blfc = Float64[], timestamp = Float64[]u"s", eventID_fadc = Int[],
        pretrace_diff = Float64[], 
        rt1090 = Float64[]u"ns", rt1099 = Float64[]u"ns", rt9099 = Float64[]u"ns", drift_time = Float64[]u"ns"
        )
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

            data = h5open(string(filename), "r")["DSP"]
            data_legend = LHDataStore(data)

            channels = data["channel"][:]
            printfmtln("Found {} events", length(channels))

            for ch in channel_list
                if !(ch in channels)
                    printfmtln("Channel {} is not in the list of channels to load, will skip", ch)
                    continue
                end
                printfmtln("Loading channel {}", ch)
                
                ch_range = searchsortedfirst(channels, ch):searchsortedlast(channels, ch)

                # println(ch_range)

                # ch_tab = TypedTables.Table(channel=channels[ch_range], blmean = data["blmean"][ch_range], blsigma = data["blsigma"][ch_range], blslope = data["blslope"][ch_range]u"ns^-1", bloffset = data["bloffset"][ch_range], 
                # τ_extracted = data["τ_extracted"][ch_range]u"µs", t0 = data["t0"][ch_range]u"µs",
                # e_10410 = data["e_10410"][ch_range], enc_10410 = data["enc_10410"][ch_range], e_10210 = data["e_10210"][ch_range], enc_10210 = data["enc_10210"][ch_range], e_848 = data["e_848"][ch_range], enc_848 = data["enc_848"][ch_range], e_434 = data["e_434"][ch_range], enc_434 = data["enc_434"][ch_range],
                # # e_grid = VectorOfSimilarArrays(ElasticArray{Float32}(undef, length(e_grid_ft), length(e_grid_rt), 0)), enc_grid = VectorOfSimilarArrays(ElasticArray{Float32}(undef, length(e_grid_ft), length(e_grid_rt), 0)),
                # a = data["a"][ch_range],
                # blfc = data["blfc"][ch_range], timestamp = data["timestamp"][ch_range]u"s", eventID_fadc = data["eventID_fadc"][ch_range],
                # pretrace_diff = data["pretrace_diff"][ch_range], 
                # rt1090 = data["rt1090"][ch_range]u"ns", rt1099 = data["rt1099"][ch_range]u"ns", rt9099 = data["rt9099"][ch_range]u"ns", drift_time = data["drift_time"][ch_range]u"ns"
                # )

                # append!(return_dict[ch].channel, channels[ch_range])


                # append!(return_dict[ch].blmean,   data["blmean"][ch_range])
                # append!(return_dict[ch].blsigma,  data["blsigma"][ch_range])
                # append!(return_dict[ch].blslope,  data["blslope"][ch_range]u"ns^-1")
                # append!(return_dict[ch].bloffset, data["bloffset"][ch_range])
                
                # append!(return_dict[ch].τ_extracted, data["τ_extracted"][ch_range]u"µs")
                # append!(return_dict[ch].t0, data["t0"][ch_range]u"µs")
                
                # append!(return_dict[ch].e_10410,   data["e_10410"][ch_range])
                # append!(return_dict[ch].enc_10410, data["enc_10410"][ch_range])
                # append!(return_dict[ch].e_10210,   data["e_10210"][ch_range])
                # append!(return_dict[ch].enc_10210, data["enc_10210"][ch_range])
                # append!(return_dict[ch].e_848,     data["e_848"][ch_range])
                # append!(return_dict[ch].enc_848,   data["enc_848"][ch_range])
                # append!(return_dict[ch].e_434,     data["e_434"][ch_range])
                # append!(return_dict[ch].enc_434,   data["enc_434"][ch_range])

                # # for arr in VectorOfSimilarArrays(e_grid)
                # #     push!(out_t.e_grid, arr)
                # # end

                # # for arr in VectorOfSimilarArrays(enc_grid)
                # #     push!(out_t.enc_grid, arr)
                # # end


                # append!(return_dict[ch].a, data["a"][ch_range])

                # append!(return_dict[ch].blfc, data["blfc"][ch_range])
                # append!(return_dict[ch].timestamp, data["timestamp"][ch_range]u"s")
                # append!(return_dict[ch].eventID_fadc, data["eventID_fadc"][ch_range])

                # append!(return_dict[ch].pretrace_diff, data["pretrace_diff"][ch_range])

                # append!(return_dict[ch].rt1090, data["rt1090"][ch_range]u"ns")
                # append!(return_dict[ch].rt1099, data["rt1099"][ch_range]u"ns")
                # append!(return_dict[ch].rt9099, data["rt9099"][ch_range]u"ns")
                # append!(return_dict[ch].drift_time, data["drift_time"][ch_range]u"ns")

                append!(return_dict[ch], TypedTables.Table(channel=channels[ch_range], blmean = data["blmean"][ch_range], blsigma = data["blsigma"][ch_range], blslope = data["blslope"][ch_range]u"ns^-1", bloffset = data["bloffset"][ch_range], 
                τ_extracted = data["τ_extracted"][ch_range]u"µs", t0 = data["t0"][ch_range]u"µs",
                e_10410 = data["e_10410"][ch_range], enc_10410 = data["enc_10410"][ch_range], e_10210 = data["e_10210"][ch_range], enc_10210 = data["enc_10210"][ch_range], e_848 = data["e_848"][ch_range], enc_848 = data["enc_848"][ch_range], e_434 = data["e_434"][ch_range], enc_434 = data["enc_434"][ch_range],
                # e_grid = VectorOfSimilarArrays(ElasticArray{Float32}(undef, length(e_grid_ft), length(e_grid_rt), 0)), enc_grid = VectorOfSimilarArrays(ElasticArray{Float32}(undef, length(e_grid_ft), length(e_grid_rt), 0)),
                a = data["a"][ch_range],
                blfc = data["blfc"][ch_range], timestamp = data["timestamp"][ch_range]u"s", eventID_fadc = data["eventID_fadc"][ch_range],
                pretrace_diff = data["pretrace_diff"][ch_range], 
                rt1090 = data["rt1090"][ch_range]u"ns", rt1099 = data["rt1099"][ch_range]u"ns", rt9099 = data["rt9099"][ch_range]u"ns", drift_time = data["drift_time"][ch_range]u"ns"
                ))
                # break
            end

            # break
        end
    end

    return return_dict
end

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

function INIconfigLoader_string(det_string::Int, config_file::String)

    conf = ConfParse(config_file)
    parse_conf!(conf)
    decay_times = Dict{Int, Float32}()

    det_string_name = format("String {}", det_string)

    channel_list = Int[]
    label_list = Dict{Int, String}()
    label_listExt = Dict{Int, String}()

    for (key, vals) in conf._data
        if startswith(key, "tier3/g")
            println(vals["label_ext"])
            if det_string_name in vals["label_ext"]
                channel = parse(Int, key[end-2:end])
                append!(channel_list, channel)
                label_list[channel] = vals["label"]
                label_listExt[channel] = ["label_ext"]
                printfmtln("Found detector {} at channel {}", label_listExt[channel], channel)
                # decay_times[parse(Int, key[end-2:end])] = parse(Float32, vals["tau"][1])    
            end
        end
    end

    return Dict("channel_list"=>channel_list, "label_list"=>label_list, "label_listExt"=>label_listExt)

end

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



