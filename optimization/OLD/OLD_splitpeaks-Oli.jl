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
            ch_name = format("ch{:03d}", vals["daq"]["fcid"])
            channel_dict[key] = ch_name
            label_dict[ch_name] = key
            string_dict[ch_name] = vals["location"]["string"]
            position_dict[ch_name] = vals["location"]["position"]
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

config_folder = p"/home/iwsatlas1/henkes/l200/l200-p02-analysis/configs/"
period = 2
run = 6
experiment = "l200"

cal = true

window_size = 25.0

channel_list, label_dict, label_list_ext, string_dict, folder_dict = loadMeta(config_folder, period=period, run=run, experiment=experiment, cal=cal)
folder_figures = PosixPath(folder_dict["folder_figures"])

function peakSeparation(channel::Array, e_fc_ch::Array, window_size::Float32, folder_figures::PosixPath)
    println("Check figure folder")
    peakSeparation_figure_folder = joinpath(folder_figures, "peakSeparation")
    checkFolder(peakSeparation_figure_folder, true)

    n_bins = 15000
    th228_lines = [2614.50]
    
    h_calsimple, h_uncal, c, fep_guess, peakhists, peakstats = simpleCalibration(Array(e_fc_ch), th228_lines, window_size=window_size, n_bins=n_bins, calib_type="th228")
    
    plot(LinearAlgebra.normalize(h_uncal, mode = :density), st = :stepbins, yscale = :log10, label="DAQ Energy")
    ylims!(0.2, maximum(LinearAlgebra.normalize(h_uncal, mode = :density).weights)*1.1)
    y_vline = ylims()[1]:1:ylims()[2]
    plot!(fill(fep_guess, length(y_vline)), y_vline, label="FEP Guess", legend=:topright, color="red", line_width=3.5)
    xlabel!("Energy (ADC)")
    ylabel!("Counts")
    xticks!((0:3000:1.2*fep_guess, ["$i" for i in 0:3000:1.2*fep_guess]))
    xlims!(0, 1.2*fep_guess)
    plot!(legend = :topright, title="Channel $channel")
    savefig(joinpath(peakSeparation_figure_folder, "daqenergy_channel_$channel.pdf"))

    fep_cuts = (fep_guess - window_size/c, fep_guess + window_size/c)

    println("Found FEP Cuts:")
    println(fep_cuts)
    return fep_cuts
end
