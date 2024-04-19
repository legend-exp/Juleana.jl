#!/usr/bin/env julia
function process_peak_split(processing_config::PropDict, l200::LegendData, data_period::DataPeriod, data_run::DataRun,; reprocess::Bool=false)
    wpool = get_workerPool(processing_config, nameof(var"#self#"))
    
    # # Needs to be in a separare @everywhere from package loading for some reason:
    @everywhere begin
    
    l200 = $l200
    data_period = $data_period
    data_run = $data_run


    input_datadir = l200.tier[:raw, :cal, data_period, data_run]
    output_datadir = l200.tier[:jlpeaks, :cal, data_period, data_run]



    function get_daqenergy_for_ch(filelist::AbstractVector{<:AbstractString}, ch::ChannelIdLike)
        fast_flatten([
            LHDataStore(
                ds -> begin
                    @info "Reading DAQ energy for channel $ch from \"$(ds.data_store.filename)\""
                    ds[ch].raw.daqenergy[:]
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
        :Tl208a => 558u"keV"..608u"keV",
        :Bi212a => 702u"keV"..752u"keV",
        :Tl208b => 836u"keV"..886u"keV",
        :Tl208DEP_Bi212FEP => 1568u"keV"..1646u"keV",
        :Tl208SEP => 2079u"keV"..2129u"keV",
        :Tl208FEP => 2590u"keV"..2640u"keV"
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

    chinfo = channelinfo(l200, first(filekeys); system=:geds, only_processable=true)
    channels = chinfo.channel
    @info "Expecting $(length(channels)) channels each file in \"$input_datadir\"."
    sel = LegendDataManagement.ValiditySelection(first(filekeys).time, :cal)
    if reprocess
        @info "Reprocessing all channels."
    else
        @info "Reprocessing only channels with missing peaks file."
    end

    e_config = dataprod_config(l200).energy(sel)

    @everywhere begin
        e_config = $e_config
    end

    if !files_checked
        @info "Checking files in \"$input_datadir\"."

        filecheck_result = pmap(wpool, filekeys) do filekey
            filename = l200.tier[:raw, filekey]
            @info "Checking file \"$filename\""
            is_ok::Bool = true
            try
                LHDataStore(filename) 
            catch err
                @error "Error while checking file \"$(filename)\": $(err)"
                is_ok = false
            else
                LHDataStore(filename) do ds
                    #ch = first(channels)
                    for ch in channels
                        try
                            #@info "Checking channel $ch in file \"$(filename)\""
                            haskey(ds, "$ch") || throw(ErrorException("Channel $ch not found in \"$(filename)\""))
                            #ds[int2chname(ch)]
                            #get_daqenergy(ds, ch)
                        catch err
                            @error "Error while checking channel $ch in \"$(filename)\": $(err)"
                            is_ok = false
                        end
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

    @showprogress pmap(wpool, channels, batch_size=1, retry_check=retry_check, retry_delays=ExponentialBackOff(n=3)) do ch
        @info "Processing channel $ch"

        filelist = [l200.tier[:raw, key] for key in filekeys]
        output_filename = l200.tier[:jlpeaks, first(filekeys), ch]

        if isfile(output_filename) && !reprocess
            @info "Output file \"$output_filename\" already exists, skipping"
        else
            @info "Generating output file \"$output_filename\""
            # # get detector name for channel
            # det = channelinfo(l200, first(filekeys), ch).detector
            # # get config for channel
            # energy_config = merge(e_config.default, ifelse(haskey(e_config, det), e_config[det], PropDict()))
            # quantile_perc = if !(energy_config.quantile_perc isa Number)
            #     parse(Float64, energy_config.quantile_perc)
            # else
            #     energy_config.quantile_perc
            # end
            # # get raw daqenergy
            # E_raw = get_daqenergy_for_ch(filelist, ch)
            # f_calib, diagnostics = autocal_energy(E_raw,; quantile_perc=quantile_perc)

            # p = plot(diagnostics.cal_hist, st=:stepbins)
            # plot!(p, xlabel="Energy (keV)", ylabel="Counts", legend=:none, yscale=:log10)
            # title!(p, get_plottitle(first(filekeys), det, "Calibrated DAQ Online Energy"))
            # savelfig(savefig, p, l200, first(filekeys), ch, Symbol("daq_energy"))

            # slim_data = flatten_by_key([LHDataStore(filename) do ds
            #     @info "Filtering $(filename), channel $ch"
            #     filter_raw_data_by_energy(ds[ch].raw, f_calib, energy_windows)
            # end for filename in filelist])


            # # stephist(f_calib.(slim_data[:Tl208a].daqenergy), nbins = 100)
            # # stephist(f_calib.(slim_data[:Tl208aDEP_Bi212b].daqenergy), nbins = 100)

            # # Don't use LHDataStore for writing here, results in huge files HDF5 block size set too large?),
            # so use  LegendDataTypes.writedata instead until fixed.
            
            @info "Writing $output_filename"
            
            # h5open(output_filename, "w") do output
            #     for label in sort(collect(keys(slim_data)))
            #         LegendDataTypes.writedata(output, "$ch/jlpeaks/$label", slim_data[label])
            #     end
            # end

            lh5open(output_filename, "w") do output
                output["$ch/jlpeaks"] = lh5open(l200.tier[:peaks, first(filekeys), ch], "r")[ch]
            end
        end

        nothing
    end


    end #time
    @info "Finished Peak Splitting"

end # function
