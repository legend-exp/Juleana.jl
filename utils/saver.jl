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
using ConfParser
using IntervalSets
using ThreadsX
using DataFrames
using ElasticArrays
using JSON


function saveCuts(tier3_folder::String, qc_cuts::Table)
    out_data_folder = PosixPath(tier3_folder)

    if !exists(out_data_folder)
        println("Output directory does not exist, create it")
        mkpath(out_data_folder)
    end
    printfmtln("Using output folder {}", out_data_folder)

    cuts_out = TypedTables.Table(qc_cuts; qc = ones(Bool, length(qc_cuts.channel)))
    for (col, name) in zip(columns(qc_cuts), columnnames(qc_cuts))
        if name != :channel && name != :qc && name != :timestamp && name != :eventID_fadc
            printfmt("Merge {} cut", name)
            println()
            cuts_out.qc .= cuts_out.qc .& col
        end
    end

    # Save cuts
    outfilename = joinpath(out_data_folder, "cuts.h5")
    out_data = LHDataStore(string(outfilename), "cw")

    println("Saving")
    
    out_data["QC"] = cuts_out

    close(out_data)

end