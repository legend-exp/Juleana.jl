#!/usr/bin/env julia
function process_peak_split(l200::LegendData, data_period::DataPeriod, data_run::DataRun,; reprocess::Bool=false)
    # # Needs to be in a separare @everywhere from package loading for some reason:
    @everywhere begin
    
    l200 = $l200
    data_period = $data_period
    data_run = $data_run


    input_datadir = l200.tier[:raw, :cal, data_period, data_run]
    output_datadir = l200.tier[:peaks, :cal, data_period, data_run]

    @debug "Create figures folder"
    figures_folder = joinpath(l200.tier[:plt, :cal, data_period, data_run], "dsp")
    if isdir(figures_folder)
        @debug("Figure folder $figures_folder already exists")
    else
        mkpath(figures_folder)
    end


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

    chinfo = channel_info(l200, first(filekeys))
    channels = sort(filterby(@pf $processable && $usability != :off && $system == :geds)(chinfo).channel)
    @info "Expecting $(length(channels)) channels each file in \"$input_datadir\"."
    sel = LegendDataManagement.ValiditySelection(first(filekeys).time, :cal)
    if reprocess
        @info "Reprocessing all channels."
    else
        @info "Reprocessing only channels with missing peaks file."
    end

    if !files_checked
        @info "Checking files in \"$input_datadir\"."

        filecheck_result = pmap(filekeys) do filekey
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
                            haskey(ds, int2chname(ch)) || throw(ErrorException("Channel $ch not found in \"$(filename)\""))
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

    pmap(channels) do ch
        @info "Processing channel $ch"

        filelist = [l200.tier[:raw, key] for key in filekeys]
        filekey_parts = split(basename(first(filelist)), "-")
        output_basename = join([filekey_parts[1:4]..., int2chname(ch), filekey_parts[6]], "-")
        output_filename = replace(joinpath(output_datadir, output_basename), "tier_raw" => "tier_peaks")

        if isfile(output_filename) && !reprocess
            @info "Output file \"$output_filename\" already exists, skipping"
        else
            @info "Generating output file \"$output_filename\""
            # get detector name for channel
            det = chinfo.detector[chinfo.channel .== ch][1]
            # get config for channel
            if haskey(l200.metadata.dataprod.config.cal.energy(sel), det)
                energy_config = merge(l200.metadata.dataprod.config.cal.energy(sel).default, l200.metadata.dataprod.config.cal.energy(sel)[det])
                @debug "Use config for detector $det"
            else
                energy_config = l200.metadata.dataprod.config.cal.energy(sel).default
                @debug "Use default config"
            end
            quantile_perc = nothing
            if !(energy_config.quantile_perc isa Number)
                quantile_perc = parse(Float64, energy_config.quantile_perc)
            else
                quantile_perc = energy_config.quantile_perc
            end
            # get raw daqenergy
            E_raw = get_daqenergy_for_ch(filelist, ch)
            f_calib, diagnostics = autocal_energy(E_raw,; quantile_perc=quantile_perc)

            plot(diagnostics.cal_hist, xlabel="Energy (keV)", ylabel="Counts", title="Calibrated DAQ Online Energy", legend=:none, yscale=:log10, st=:stepbins)
            savefig(joinpath(figures_folder, format("{}-{}-{}-{}-{}-daq_energy.png", string(first(filekeys).setup), string(first(filekeys).period), string(first(filekeys).run), string(first(filekeys).category), ch)))


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
    @info "Finished Peak Splitting"
    @info "Remove all workers"
    rmprocs(workers()...)

end # function
