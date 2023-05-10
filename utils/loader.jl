include("packages.jl")
include("utils.jl")

# cal = true
# period = 2
# lrun = 6
# config_folder = p"/home/iwsatlas1/henkes/l200/l200-p02-analysis/configs/"
# experiment = "l200"
# config_file_rel = ifelse(cal, format("config_{}-p{:02d}-r{:03d}_cal.json", experiment, period, lrun), format("config_{}-p{:02d}-r{:03d}_phy.json", experiment, period, lrun))
# config_file = joinpath(config_folder, config_file_rel)
# conf_dict = JSON.parsefile(string(config_file); dicttype=Dict, inttype=Int64, use_mmap=true)

# process_dict = JSON.parsefile("/home/iwsatlas1/henkes/l200/l200-p02-analysis/configs/processable.json"; dicttype=Dict, inttype=Int64, use_mmap=true)["analysis"]
# for (key, vals) in conf_dict
#     if vals["system"] == "geds"
#         conf_dict[key]["processable"] = process_dict[key]["processable"]
#     end
# end

# open("/home/iwsatlas1/henkes/l200/l200-p02-analysis/configs/config_l200-p02-r006_cal-test.json", "w") do f
#     JSON.print(f, conf_dict, 4)
# end

function loadMeta(config_folder::PosixPath; period::Int, run::Int, experiment::String, cal::Bool)
    config_file_rel = ifelse(cal, format("config_{}-p{:02d}-r{:03d}_cal.json", experiment, period, run), format("config_{}-p{:02d}-r{:03d}_phy.json", experiment, period, run))
    config_file = joinpath(config_folder, config_file_rel)
    conf_dict = JSON.parsefile(string(config_file); dicttype=Dict, inttype=Int64, use_mmap=true)

    channel_dict   = Dict{String, String}()
    label_dict     = Dict{String, String}()
    string_dict    = Dict{String, Int64}()
    position_dict  = Dict{String, Int64}()
    folder_dict    = Dict{String, String}()
    for (key, vals) in conf_dict
        if vals["system"] == "geds"
            if vals["processable"]
                ch_name = format("ch{:03d}", vals["daq"]["fcid"])
                channel_dict[key] = ch_name
                label_dict[ch_name] = key
                string_dict[ch_name] = vals["location"]["string"]
                position_dict[ch_name] = vals["location"]["position"]
            end
        end
        if vals["system"] == "general"
            for (folder_type, folder_name) in vals["folder"]
                folder_dict[folder_type] = folder_name
            end
        end
    end
    string_numbers = sort(unique(values(string_dict)))
    label_list_ext = Dict{String, String}(values(channel_dict) .=> [format("{} at String {} Position {}", label_dict[ch], string_dict[ch], position_dict[ch]) for ch in values(channel_dict)])
    string_dict = Dict{Int64, Array}(string_numbers .=> [[ch for ch in values(channel_dict) if string_dict[ch] == string] for string in string_numbers])
    channel_list = collect(values(channel_dict))


    return channel_list, label_dict, label_list_ext, string_dict, folder_dict
end

function loadValues(keys_list::Array, load_key::String, config_folder::PosixPath; period::Int, run::Int, experiment::String, cal::Bool)
    config_file_rel = ifelse(cal, format("config_{}-p{:02d}-r{:03d}_cal.json", experiment, period, run), format("config_{}-p{:02d}-r{:03d}_phy.json", experiment, period, run))
    config_file = joinpath(config_folder, config_file_rel)
    conf_dict = JSON.parsefile(string(config_file); dicttype=Dict, inttype=Int64, use_mmap=true)

    return_dict = Dict{String, Any}()
    for (key, vals) in conf_dict
        if key in keys_list
            try
                return_dict[key] = vals[load_key]
            catch
                println("No $load_key for $key")
            end
        end
    end

    return return_dict
end



function moveBrokenFiles(dsp_folder::String)
    broken_folder = joinpath(dsp_folder, "broken")
    checkFolder(PosixPath(broken_folder), true)
    hdf5_files = filter(f -> endswith(f, ".lh5"), readdir(dsp_folder))
        status = @showprogress "Move data..." for data_file in hdf5_files
            filename = joinpath(dsp_folder, data_file)
            try
                data = LHDataStore(filename, "r")
                close(data)
            catch e
                @warn "$e : File $filename"
                println("Moving file to broken folder.")
                mv(filename, joinpath(broken_folder, data_file))
                continue
            end
        end
end

function loadDSP(dsp_folder::String, channel_list::Array{String})
    data_dict = Dict{String, TypedTables.Table}()
    first_file = Dict{String, Bool}(ch => true for ch in channel_list)
    hdf5_files = filter(f -> endswith(f, ".lh5"), readdir(dsp_folder))
        status = @showprogress "Load data..." for data_file in hdf5_files
            filename = joinpath(dsp_folder, data_file)
            
            data = LHDataStore(filename, "r")
            for ch in channel_list
                try 
                    if first_file[ch]
                        data_dict[ch] = data[ch][:]
                        first_file[ch] = false
                    else
                        data_dict[ch] = append!(data_dict[ch], data[ch][:])
                    end
                catch e
                    @warn "$e : Channel $ch error in file $filename"
                end
            end
            close(data)
        end
    return data_dict
end

function prepareHit(configFolder::String; period::Int, run::Int, preName::String, cal::Bool, stringsToLoad::Array{Int}, additionalKeys::Dict{String, String}=Dict{String, String}())
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
    
    data_channels = runLoader(string(dsp_folder))
    
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
        
        dsp_data = filter(((k,v),) -> k in channel_list, data_channels)
        data_strings[string_number] = [dsp_data, channel_list, label_listExt, label_list, additionalKeys_dict]
        
        qc_cuts[string_number] = cutLoader(channel_list, string(cut_folder))
    end


    return (dsp_folder, hit_folder, cut_folder, figure_folder, string_numbers, data_strings, qc_cuts)
end
