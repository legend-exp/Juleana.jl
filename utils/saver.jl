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