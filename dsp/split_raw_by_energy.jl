#!/usr/bin/env julia

data_period = ARGS[1]
#data_period = "p03"

data_run = ARGS[2]
#data_run = "r001"

# import Pkg; Pkg.activate("/user/.julia/environments/legend-prod")

using Distributed,LegendDataManagement, Hwloc
legend_addprocs(
    div(Hwloc.num_physical_cores(), Base.Threads.nthreads())
)

@everywhere begin

using LegendDataTypes

using LegendSpecFits
using HDF5, LegendHDF5IO
using LegendDataManagement, LegendSpecFits
using PropertyFunctions
using IntervalSets, Unitful
using Printf
using Plots

using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked

end # everywhere

# Needs to be in a separare @everywhere from package loading for some reason:
@everywhere begin

data_period = $data_period
data_run = $data_run

l200 = LegendData(:l200)
input_datadir = l200.tier[:raw, :cal, data_period, data_run]
output_datadir = l200.tier[:peaks, :cal, data_period, data_run]


function get_daqenergy_for_ch(filelist::AbstractVector{<:AbstractString}, ch::Integer)
    fast_flatten([
        LHDataStore(
            ds -> begin
                @info "Reading DAQ energy for channel $ch from \"$(ds.data_store.filename)\""
                get_daqenergy(ds, ch)
            end,
            filename
        ) for filename in filelist
    ])
end


function channels_in_file(filename)
    LHDataStore(filename) do ds
        sort(chname2int.(filter(startswith("ch"), keys(ds))))
    end
end    


energy_windows = IdDict(
    :Tl208b => 558u"keV"..608u"keV",
    :BI212a => 702u"keV"..752u"keV",
    :Tl208dFEP => 836u"keV"..886u"keV",
    :Tl208aDEP_Bi212b => 1568u"keV"..1646u"keV",
    :Tl208aSEP => 2079u"keV"..2129u"keV",
    :Tl208a => 2590u"keV"..2640u"keV"
)

end # everywhere


@time begin

mkpath(output_datadir)
@assert isdir(input_datadir) && isdir(output_datadir)

keylist_filename = joinpath(output_datadir, "filekeys.txt")
broken_keylist_filename = joinpath(output_datadir, "broken_filekeys.txt")

if isfile(keylist_filename)
    filekeys = read_filekeys(keylist_filename)
    files_checked = true
else
    filekeys = search_disk(FileKey, l200.tier[:raw, :cal, data_period, data_run])
    files_checked = false
end
isempty(filekeys) && error("No files found in \"$input_datadir\"")

chinfo = channel_info(l200, first(filekeys))
channels = sort(filterby(@pf $processable && $usability && $system == :geds)(chinfo).channel)
@info "Expecting $(length(channels)) channels each file in \"$input_datadir\"."

if !files_checked
    @info "Checking files in \"$input_datadir\"."

    filecheck_result = pmap(filekeys) do filekey
        filename = l200.tier[:raw, filekey]
        @info "Checking file \"$filename\""
        is_ok::Bool = true
        LHDataStore(filename) do ds
            #ch = first(channels)
            for ch in channels
                try
                    #@info "Checking channel $ch in file \"$(filename)\""
                    haskey(ds, int2chname(ch)) || throw(ErrorException("Channel $ch not found in \"$(filename)\""))
                    #ds[int2chname(ch)]
                    #get_daqenergy(ds, ch)
                catch err
                    @error "Error while checking channel $ch in \"$(filename)\": $(err)"
                    is_ok = false
                end
            end
        end
        return is_ok
    end

    good_filekeys = filekeys[filecheck_result]
    write_filekeys(keylist_filename, good_filekeys)

    broken_filekeys = filekeys[.!(filecheck_result)]
    if !isempty(broken_filekeys)
        @error "Detected broken files for filekeys" broken_filekeys
        write_filekeys(broken_keylist_filename, broken_filekeys)
    end

    filekeys = good_filekeys
end

end #@time


@time begin

pmap(channels) do ch
    @info "Processing channel $ch"

    filelist = [l200.tier[:raw, key] for key in filekeys]
    filekey_parts = split(basename(first(filelist)), "-")
    output_basename = join([filekey_parts[1:4]..., int2chname(ch), filekey_parts[6]], "-")
    output_filename = replace(joinpath(output_datadir, output_basename), "tier_raw" => "tier_peaks")

    if isfile(output_filename)
        @info "Output file \"$output_filename\" already exists, skipping"
    else
        @info "Generating output file \"$output_filename\""

        E_raw = get_daqenergy_for_ch(filelist, ch)
        f_calib, diagnostics = autocal_energy(E_raw)

        # plot(diagnostics)

        slim_data = flatten_by_key([LHDataStore(filename) do ds
            @info "Filtering $(filename), channel $ch"
            filter_raw_data_by_energy(get_raw_ch_data(ds, ch), f_calib, energy_windows)
        end for filename in filelist])


        # stephist(f_calib.(slim_data[:Tl208a].daqenergy), nbins = 100)
        # stephist(f_calib.(slim_data[:Tl208aDEP_Bi212b].daqenergy), nbins = 100)

        # Don't use LHDataStore for writing here, results in huge files HDF5 block size set too large?),
        # so use  LegendDataTypes.writedata instead until fixed.

        @info "Writing $output_filename"

        h5open(output_filename, "w") do output
            for label in sort(collect(keys(slim_data)))
                LegendDataTypes.writedata(output, "$(int2chname(ch))/$label", slim_data[label])
            end
        end
    end

    nothing
end


end #time
