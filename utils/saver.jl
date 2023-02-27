include("utils.jl")

function saveCuts(cut_folder::String, qc_cuts::Table)
    cut_folder = PosixPath(cut_folder)

    checkFolder(cut_folder, true)
    printfmtln("Using cut folder {}", string(cut_folder))

    cuts_out = TypedTables.Table(qc_cuts; qc = ones(Bool, length(qc_cuts.channel)))
    for (col, name) in zip(columns(qc_cuts), columnnames(qc_cuts))
        if name != :channel && name != :qc && name != :timestamp && name != :eventID_fadc
            printfmt("Merge {} cut", name)
            println()
            cuts_out.qc .= cuts_out.qc .& col
        end
    end

    # Save cuts
    outfilename = joinpath(cut_folder, "cuts.h5")
    out_data = LHDataStore(string(outfilename), "cw")

    println("Saving")
    
    out_data["QC"] = cuts_out

    close(out_data)

end