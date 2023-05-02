include("utils.jl")

function saveCuts(cut_folder::String, qc_cuts::Table)
    cut_folder = PosixPath(cut_folder)

    checkFolder(cut_folder, true)
    printfmtln("Using cut folder {}", string(cut_folder))

    # Save cuts
    outfilename = joinpath(cut_folder, "cuts.h5")
    out_data = LHDataStore(string(outfilename), "cw")

    println("Saving")
    
    out_data["QC"] = cuts_out

    close(out_data)

end;

function saveValues(save_dict::Dict{String, Float32}, save_key::String, config_folder::PosixPath; period::Int, run::Int, experiment::String, cal::Bool)
    config_file_rel = ifelse(cal, format("config_{}-p{:02d}-r{:03d}_cal.json", experiment, period, run), format("config_{}-p{:02d}-r{:03d}_phy.json", experiment, period, run))
    config_file = joinpath(config_folder, config_file_rel)
    conf_dict = JSON.parsefile(string(config_file); dicttype=Dict, inttype=Int64, use_mmap=true)

    for (key, vals) in conf_dict
        if key in keys(save_dict)
            conf_dict[key][save_key] = save_dict[key]
        end
    end

    open(config_file, "w") do f
        JSON.print(f, conf_dict, 4)
    end
end

