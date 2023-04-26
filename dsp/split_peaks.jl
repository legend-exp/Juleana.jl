include("../utils/packages.jl")
include("../utils/loader.jl")
include("../utils/utils.jl")

function peakSeparation(configFolder::String; period::Int, run::Int, preName::String, cal::Bool)
    println("Starting DSP Peak Separation\n\n")
    printfmtln("Using {} threads\n\n", Threads.nthreads())

    data_folder, out_data_folder, figure_folder, string_numbers, decay_times, energy_fadc = prepareDSP_peakSeparation(config_folder, period=period, run=run, preName=preName, cal=cal)

    println()
    println()

    println("Check figure folder")
    peakSeparation_figure_folder = joinpath(figure_folder, "peakSeparation")
    checkFolder(peakSeparation_figure_folder, true)

    channels = energy_fadc.channel
    e_fc     = energy_fadc.e_fc
    sortindices      = sortperm(channels, alg=ThreadsX.QuickSort)

    channels_sorted     = channels[sortindices]
    e_fc_sorted         = e_fc[sortindices]

    con_ch_view    = consgroupedview(channels_sorted, channels_sorted)
    con_e_fc_view  = consgroupedview(channels_sorted, e_fc_sorted)

    fep_cuts = Dict{Int, Tuple{Float64, Float64}}()

    for (i, e_fc_ch) in enumerate(con_e_fc_view)
        e_fc_ch = con_e_fc_view[i]
        ch_ch   = con_ch_view[i]
        ch = ch_ch[1]

        if length(e_fc_ch) < 2
            # println("Skip channel")
            continue
        end
        if !haskey(decay_times, ch)
            # println("Skip channel")
            continue
        end

        n_bins = 15000
        th228_lines = [583.191, 727.330, 860.564, 1592.53, 1620.50, 2103.53, 2614.50]
        window_size = 20.0
        
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
ch = 34

for ch in keys(fep_cuts)
    outfilename = joinpath(out_data_folder, "peaks_channel_$ch.lh5")
    out_data = LHDataStore(string(outfilename), "cw")

    out_data["ORFlashCamADCWaveform"] = TypedTables.Table(
        channel      = Int[],
        daqenergy    = Float64[],
        waveform     = Array{RDWaveform}[],
        baseline     = Float64[],
        timestamp    = Float64[],
        eventnumber  = Int[]
    )
    close(out_data)
    # break
end
for (root, dirs, files) in walkdir(data_folder)
    iter = ProgressBar(files)
    for data_file in iter
        
        if splitext(data_file)[2] != ".lh5"
            println(iter, format("File {} is not a HDF5 file, will Skip", data_file))
            continue
        end

        filename = joinpath(data_folder, data_file)
        
        data = LHDataStore(string(filename))
        
        channels     = 6* data["ORFlashCamADCWaveform"].card[:] + data["ORFlashCamADCWaveform"].ch_orca[:]
        for ch in keys(fep_cuts)
            fep_cut_ch = channels .== ch .&& energy_fadc .> fep_cuts[ch][1] .&& energy_fadc .< fep_cuts[ch][2]

        end
        append!(out_t.channel, channels)

        energy_fadc  = data["ORFlashCamADCWaveform"].daqenergy[:]
        append!(out_t.e_fc, energy_fadc)

        close(data)
    end
end

data = LHDataStore(string(filename))["ORFlashCamADCWaveform"][:]

channels     = 6* data.card + data.ch_orca
wvfs         = data.waveform
baselines_fc = data.baseline
timestamps   = data.timestamp
eventID_fadc = data.eventnumber
energy_fadc  = data.daqenergy

println("Loaded data")
println("Number of events: ", length(wvfs))

# split waveforms channelwise
sortindices      = sortperm(channels, alg=ThreadsX.QuickSort)

channels_sorted     = channels[sortindices]
wvfs_sorted         = wvfs[sortindices]
baselines_fc_sorted = baselines_fc[sortindices]
timestamps_sorted   = timestamps[sortindices]
eventID_fadc_sorted = eventID_fadc[sortindices]
energy_fadc_sorted  = energy_fadc[sortindices]

con_ch_view    = consgroupedview(channels_sorted, channels_sorted)
con_wvf_view   = consgroupedview(channels_sorted, wvfs_sorted)
con_bl_fc_view = consgroupedview(channels_sorted, baselines_fc_sorted)
con_ts_view    = consgroupedview(channels_sorted, timestamps_sorted)
con_evID_view  = consgroupedview(channels_sorted, eventID_fadc_sorted)
con_e_fc_view  = consgroupedview(channels_sorted, energy_fadc_sorted)

for (i, wvfs_ch) in enumerate(con_wvf_view)
    blfc_ch = con_bl_fc_view[i]
    ts_ch   = con_ts_view[i]
    evID_ch = con_evID_view[i]
    ch_ch   = con_ch_view[i]
    efc_ch  = con_e_fc_view[i]

    ch = ch_ch[1]

    if length(wvfs_ch) < 2
        # println("Skip channel")
        continue
    end
    if !haskey(fep_cuts, ch)
        # println("Skip channel")
        continue
    end



# i = 3
# e_fc_ch = con_e_fc_view[i]
# ch_ch   = con_ch_view[i]
# ch = ch_ch[1]

# plotlyjs()
# n_bins = 15000
# th228_lines = [583.191, 727.330, 860.564, 1592.53, 1620.50, 2103.53, 2614.50]
# window_size = 20.0

# h_calsimple, h_uncal, c, fep_guess, peakhists, peakstats = simpleCalibration(Array(e_fc_ch), th228_lines, window_size=window_size, n_bins=n_bins, calib_type="th228")

# plot(LinearAlgebra.normalize(h_uncal, mode = :density), st = :stepbins, yscale = :log10, label="Energy")
# ylims!(0.2, maximum(LinearAlgebra.normalize(h_uncal, mode = :density).weights)*1.1)
# y_vline = ylims()[1]:1:ylims()[2]
# plot!(fill(fep_guess, length(y_vline)), y_vline, label="FEP Guess", legend=:topright, color="red", line_width=3.5)
# xlabel!("Energy (ADC)")
# ylabel!("Counts")
# xticks!((0:3000:1.2*fep_guess, ["$i" for i in 0:3000:1.2*fep_guess]))
# xlims!(0, 1.2*fep_guess)
# plot!(legend = :topright, title="Channel $ch")

# fep_cut = (fep_guess - window_size/c, fep_guess + window_size/c)