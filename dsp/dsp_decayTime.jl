using RadiationDetectorDSP
using Plots
using LegendHDF5IO
using Unitful
using RadiationDetectorSignals
using Statistics
using GLM
using LinearRegression
using InverseFunctions
using ArraysOfArrays
using TypedTables
using BenchmarkTools
using LaTeXStrings
using Measures
using HDF5
using ProgressBars
using FilePathsBase
using Formatting
using Base

data_folder = p"/mnt/atlas01/users/henkes/l60_r025/cal/tier1/"
if !exists(data_folder)
    println("Input directory does not exist, exist script")
    exit(86)
end

printfmtln("Using input folder {}", data_folder)
out_data_folder = p"/mnt/atlas01/users/henkes/l60_r025/julia/cal/tier2_tau/"
if !exists(out_data_folder)
    println("Output directory does not exist, create it")
    mkpath(out_data_folder)
end
printfmtln("Using output folder {}", out_data_folder)

for (root, dirs, files) in walkdir(data_folder)
    iter = ProgressBar(files)
    # Threads.@threads for data_file in iter
    for data_file in iter
        
        if splitext(data_file)[2] != ".lh5"
            println(iter, format("File {} is not a HDF5 file, will Skip", data_file))
            continue
        end
        # println(iter, "Accepted")
        # continue
        # data_file = "tier1_l60-p01-r027-cal-20220923T165106Z.h5"

        filename = joinpath(data_folder, data_file)

        outfile = string("tier2-tau_", split(data_file, "_")[2])
        outfilename = joinpath(out_data_folder, outfile)

        data = LHDataStore(string(filename))["ORFlashCamADCWaveform"][:]
        out_data = LHDataStore(string(outfilename), "cw")

        if "channel" in keys(out_data)
            println(iter, format("Output file {} already exists, will skip", outfile))
            close(out_data)
            continue
        end
        # println(iter, columnnames(out_data))
        println(iter, "File: ", data_file)
        println(iter, "Filesize: ", Base.format_bytes(filesize(filename)))
        # println(iter, "Found data file keys:")
        # println(iter, columnnames(data))

        wvfs         = data.waveform
        # baselines_fc = data.baseline
        # times        = data.timestamp
        # eventID_fadc = data.eventnumber
        # fc_card      = data.card
        # fc_channel   = data.ch_orca
        channels     = 6*fc_card + fc_channel

        println(iter, "Loaded data")
        println(iter, "Number of events: ", length(wvfs))

        baselines_mean = mean(flatview(wvfs.signal)[1:2500, :], dims=1)
        baselines_std = std(flatview(wvfs.signal)[1:2500, :], dims=1)

        wvfs_bl = shift_waveform.(wvfs, -baselines_mean[:])
        # break
        # println("Extract decay time constant")
        # # get decay time from linear fit to logarhitmic tail
        # pz_fit_start , pz_fit_end = 4000, 8000
        # y_fit = flatview(wvfs_bl.signal)[pz_fit_start:pz_fit_end, :]

        # # cut out negative values to avoid errors with logarhitmic
        # y_fit_cut = vec(mapslices(col -> all(col .> 0), y_fit, dims = 1))
        # y_fit = log.(y_fit[:, y_fit_cut])
        # x_fit = repeat(reduce(vcat, pz_fit_start:pz_fit_end), 1, size(y_fit, 2))

        # lr = linregress(x_fit, y_fit)
        # b = coef(lr)
        # τ = vec(uconvert.(u"µs", -1/b[1, :] * step(smplinfo(wvfs_bl[1]).axis)))
        # append!(τ, repeat([0u"µs"], sum(.!y_fit_cut)))

        println("Extract baseline slope")
        # get baseline slope by linear fit
        bl_avg_end = 2500
        y_fit = flatview(wvfs_bl.signal)[1:bl_avg_end, :]
        x_fit = repeat(reduce(vcat, 1:bl_avg_end), 1, size(y_fit, 2))

        lr = linregress(x_fit, y_fit)
        b = coef(lr)
        baselines_slope = b[1, :]

        # sort all values according to decay time fit
        channels        = append!(channels[y_fit_cut], channels[.!y_fit_cut])
        baselines_mean  = append!(baselines_mean[y_fit_cut], baselines_mean[.!y_fit_cut])
        baselines_std   = append!(baselines_std[y_fit_cut], baselines_std[.!y_fit_cut])
        baselines_slope = append!(baselines_slope[y_fit_cut], baselines_slope[.!y_fit_cut])
        baselines_fc    = append!(baselines_fc[y_fit_cut], baselines_fc[.!y_fit_cut])
        times           = append!(times[y_fit_cut], times[.!y_fit_cut])
        eventID_fadc    = append!(eventID_fadc[y_fit_cut], eventID_fadc[.!y_fit_cut])
        
        break
        # save all data to LH5 file 
        println(iter, format("Save data in {}", outfile))
        out_data["channel"]         = channels
        out_data["baselines_mean"]  = baselines_mean 
        out_data["baselines_std"]   = baselines_std
        out_data["baselines_slope"] = baselines_slope
        out_data["baselines_fc"]    = baselines_fc
        out_data["times"]           = times
        out_data["eventID_fadc"]    = eventID_fadc

        # close files
        close(out_data)
        break
    end
end