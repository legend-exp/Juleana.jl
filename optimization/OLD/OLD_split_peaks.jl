include("../utils/packages.jl")
include("../utils/loader.jl")
include("../utils/utils.jl")

config_folder = p"/home/iwsatlas1/henkes/l200/l200-p02-analysis/configs/"
period = 2
run = 6
experiment = "l200"

cal = true

channel_list, label_dict, label_list_ext, string_dict, folder_dict = loadMeta(config_folder, period=period, run=run, experiment=experiment, cal=cal)


function peakSeparation(channel_list::Array, folder_raw::PosixPath, folder_figures::PosixPath)
    println("Starting DSP Peak Separation\n\n")
    printfmtln("Using {} threads\n\n", Threads.nthreads())

    println()
    println()

    println("Check figure folder")
    peakSeparation_figure_folder = joinpath(folder_figures, "peakSeparation")
    checkFolder(peakSeparation_figure_folder, true)

    n_bins = 15000
    th228_lines = [583.191, 727.330, 860.564, 1592.53, 1620.50, 2103.53, 2614.50]
    window_size = 20.0

    fep_cuts = Dict{Int, Tuple{Float64, Float64}}()

    for (i, ch) in enumerate(channel_list)
        
        e_fc_ch = Array{Float64, 1}()

        for (root, dirs, files) in walkdir(folder_raw)
            iter = ProgressBar(files)
            for data_file in iter
                
                if splitext(data_file)[2] != ".lh5"
                    println(iter, format("File {} is not a HDF5 file, will Skip", data_file))
                    continue
                end

                filename = joinpath(folder_raw, data_file)
                
                data = LHDataStore(string(filename))

                append!(e_fc_ch, data["$ch/raw/daqenergy"])
            end
        end
        
        h_calsimple, h_uncal, c, fep_guess, peakhists, peakstats = simpleCalibration(Array(e_fc_ch), th228_lines, window_size=window_size, n_bins=n_bins, calib_type="th228")
        
        plot(LinearAlgebra.normalize(h_uncal, mode = :density), st = :stepbins, yscale = :log10, label="DAQ Energy")
        ylims!(0.2, maximum(LinearAlgebra.normalize(h_uncal, mode = :density).weights)*1.1)
        y_vline = ylims()[1]:1:ylims()[2]
        plot!(fill(fep_guess, length(y_vline)), y_vline, label="FEP Guess", legend=:topright, color="red", line_width=3.5)
        xlabel!("Energy (ADC)")
        ylabel!("Counts")
        xticks!((0:3000:1.2*fep_guess, ["$i" for i in 0:3000:1.2*fep_guess]))
        xlims!(0, 1.2*fep_guess)
        plot!(legend = :topright, title="Channel $ch")
        savefig(joinpath(peakSeparation_figure_folder, "daqenergy_channel_$ch.pdf"))

        fep_cuts[ch] = (fep_guess - window_size/c, fep_guess + window_size/c)
    end

    println("Found FEP Cuts:")
    println(fep_cuts)
end


data_folder = p"/remote/ceph2/group/legendex/data/l200/cal/p02/r006"
test_file = "l200-p02-r006-cal-20221226T222457Z-tier_raw.lh5"

fep_cuts = Dict{String, Tuple{Float64, Float64}}()

folder_raw, folder_figures = folder_dict["folder_raw"], folder_dict["folder_figures"]

println("Check figure folder")
peakSeparation_figure_folder = PosixPath(joinpath(folder_figures, "peakSeparation"))
checkFolder(peakSeparation_figure_folder, true)

ch = channel_list[1]

e_fc = Dict{String, Array}(ch => Float64[] for ch in channel_list)

for (root, dirs, files) in walkdir(folder_raw)
    iter = ProgressBar(files)
    for data_file in iter
        
        if splitext(data_file)[2] != ".lh5"
            println(iter, format("File {} is not a HDF5 file, will Skip", data_file))
            continue
        end

        filename = joinpath(folder_raw, data_file)
        
        data = LHDataStore(string(filename))
        data_channels = keys(data)

        if !(ch in data_channels)
            continue
        end
        append!(e_fc[ch], data["$ch/raw/daqenergy"][:])
        close(data)
    end
end

n_bins = 15000
th228_lines = [583.191, 727.330, 860.564, 1592.53, 1620.50, 2103.53, 2614.50]
window_size = 30.0

e_fc_ch = e_fc[ch]
h_calsimple, h_uncal, c, fep_guess, peakhists, peakstats = simpleCalibration(Array(e_fc_ch), th228_lines, window_size=window_size, n_bins=n_bins, calib_type="th228")

plot(LinearAlgebra.normalize(h_uncal, mode = :density), st = :stepbins, yscale = :log10, label="DAQ Energy")
ylims!(0.2, maximum(LinearAlgebra.normalize(h_uncal, mode = :density).weights)*1.1)
y_vline = ylims()[1]:1:ylims()[2]
plot!(fill(fep_guess, length(y_vline)), y_vline, label="FEP Guess", legend=:topright, color="red", line_width=3.5)
xlabel!("Energy (ADC)")
ylabel!("Counts")
xticks!((0:3000:1.2*fep_guess, ["$i" for i in 0:3000:1.2*fep_guess]))
xlims!(0, 1.2*fep_guess)
plot!(legend = :topright, title="Channel $ch")
savefig(joinpath(peakSeparation_figure_folder, "daqenergy_channel_$ch.pdf"))

fep_cuts[ch] = (fep_guess - window_size/c, fep_guess + window_size/c)