include("../utils/packages.jl")
include("../utils/loader.jl")
include("../utils/utils.jl")

using LegendDataTypes
using HDF5, LegendHDF5IO
using LegendSpecFits
using IntervalSets
using Plots

using LegendDataTypes: fast_flatten, flatten_by_channel, map_chunked



function get_channels(ds::LHDataStore)
    parse.(Int, replace.(filter(startswith("ch"), keys(ds)), Ref("ch" => "")))
end


get_raw_ch_data(ds::LHDataStore, ch::Integer) = ds[format("ch{:03d}", ch)].raw


function get_daqenergy(ds::LHDataStore, ch::Integer)
    # Should be (ToDo - make this faster):
    #   get_raw_ch_data(ds, ch).daqenergy[:]
    # Faster workaround, temporary:
    ds.data_store[format("ch{:03d}", ch)]["raw"]["daqenergy"][:]
end

function get_all_daqenergies(filelist::AbstractVector{<:AbstractString})
    flatten_by_channel([
        LHDataStore(
            ds -> IdDict(ch => get_daqenergy(ds, ch) for ch in channels if format("ch{:03d}", ch) in keys(ds)), filename
        ) for filename in filelist
    ])
end


function auto_calib_func(daq_energy::AbstractArray{<:Real})
    window_size = 25.0
    n_bins = 15000
    th228_lines = [2614.50]
    h_calsimple, h_uncal, calib_constant, fep_guess, peakhists, peakstats = simpleCalibration(daq_energy, th228_lines, window_size=window_size, n_bins=n_bins, calib_type="th228")
    return Base.Fix1(*, calib_constant)
end


function in_any_interval(x::Real, intervals::AbstractVector{<:AbstractInterval{<:Real}})
    any(Base.Fix1(in, x), intervals)
end


function filter_raw_data_by_energy(
    raw_data::AbstractVector,
    calib_func::Function,
    energy_windows::AbstractVector{<:AbstractInterval{<:Real}}
)
    sel_idxs = findall(in_any_interval.(calib_func.(raw_data.daqenergy), Ref(energy_windows)))
    return raw_data[sel_idxs]
end

function filter_raw_data_by_energy_all_ch(
    ds::LHDataStore,
    channels::AbstractVector{<:Integer},
    calib_funcs::IdDict{<:Integer,<:Function},
    energy_windows::AbstractVector{<:AbstractInterval{<:Real}}
)
    chunk_size = 10000

    IdDict((
        ch => map_chunked(get_raw_ch_data(ds, ch), chunk_size) do chunk
            filter_raw_data_by_energy(chunk, calib_funcs[ch], energy_windows)
        end for ch in channels
    ));
end



@time begin
channel_list, label_dict, label_list_ext, string_dict, folder_dict = loadMeta(config_folder, period=period, run=run, experiment=experiment, cal=cal)
folder_figures = PosixPath(folder_dict["folder_figures"])
folder_raw = PosixPath(folder_dict["folder_raw"])
folder_peaks = PosixPath(folder_dict["folder_peaks"])

println("Using peaks")
th228_lines = [2614.50]
println(th228_lines)
energy_windows = ClosedInterval.(th228_lines .- window_size, th228_lines .+ window_size)

filelist = String[]
for (root, dirs, files) in walkdir(folder_raw)
    for data_file in files
        
        if splitext(data_file)[2] != ".lh5"
            println(format("File {} is not a HDF5 file, will Skip", data_file))
            continue
        end

        filename = joinpath(folder_raw, data_file)

        push!(filelist, string(filename))
    end
end

# filelist = ["/data/oli/legend/l200/cal/p03/r000/l200-p03-r000-cal-20230312T000248Z-tier_raw.lh5"]

# th228_lines = [583.191, 727.330, 860.564, 2103.53, 2614.50]
energy_windows = ClosedInterval.(th228_lines .- 30, th228_lines .+ 30)

channels = LHDataStore(get_channels, first(filelist)) 
daq_energies = get_all_daqenergies(filelist)
calib_funcs = IdDict(((k, auto_calib_func(v)) for (k,v) in daq_energies))


slim_data = flatten_by_channel([
    LHDataStore(filename) do ds
        filter_raw_data_by_energy_all_ch(ds, channels, calib_funcs, energy_windows)
    end for filename in filelist
])

end #time


# ch = channels[3]
# stephist(calib_funcs[ch].(slim_data[ch].daqenergy), nbins = 1000)


#=
# Huge output (HDF5 block size set too large?):
LHDataStore("out.lh5", "w") do output
    for ch in channels
        output["ch$(ch)"] = slim_data[ch]
    end
end
=#

# Use LegendDataTypes.writedata instead of LHDataStore for output for now:

@time h5open(joinpath(folder_peaks, "peaks.lh5"), "w") do output
    for ch in channels
        LegendDataTypes.writedata(output, format("ch{:03d}", ch), slim_data[ch])
    end
end
