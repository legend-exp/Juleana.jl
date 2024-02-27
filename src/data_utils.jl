###################
# Data Access utils
###################

function get_peaksfilename end
get_peaksfilename(data::LegendData, setup::ExpSetupLike, period::DataPeriodLike, run::DataRunLike, category::DataCategoryLike, ch::ChannelIdLike) = joinpath(data.tier[:peaks, :cal, period, run], format("{}-{}-{}-{}-{}-tier_peaks.lh5", string(setup), string(period), string(run), string(category), string(ch)))
get_peaksfilename(data::LegendData, filekey::FileKey, ch::ChannelIdLike) = get_peaksfilename(data, filekey.setup, filekey.period, filekey.run, filekey.category, ch)

get_hitchfilename(data::LegendData, setup::ExpSetupLike, period::DataPeriodLike, run::DataRunLike, category::DataCategoryLike, ch::ChannelIdLike) = joinpath(data.tier[:jlhitch, category, period, run], format("{}-{}-{}-{}-{}-tier_jlhit.lh5", string(setup), string(period), string(run), string(category), string(ch)))
get_hitchfilename(data::LegendData, filekey::FileKey, ch::ChannelIdLike) = get_hitchfilename(data, filekey.setup, filekey.period, filekey.run, filekey.category, ch)



function load_runch(data::LegendData, filekeys::Vector{FileKey}, tier::DataTierLike, ch::ChannelIdLike; check_filekeys::Bool=true)
    ch_filekeys = if check_filekeys
        @info "Check Filekeys"
        ch_filekeys = Vector{FileKey}()
        for fk in filekeys
            if !isfile(data.tier[tier, fk])
                @warn "File $(basename(data.tier[tier, fk])) does not exist, skip"
                continue
            end
            if !haskey(lh5open(data.tier[tier, fk], "r"), "$ch")
                @warn "Channel $ch not found in $(basename(data.tier[tier, fk])), skip"
                continue
            end
            push!(ch_filekeys, fk)
        end
        ch_filekeys
    else
        filekeys
    end

    # check if any valid filekeys found
    if isempty(ch_filekeys)
        @error "No valid filekeys found, skip"
        throw(LoadError("FileKeys", 154,"No filekeys found for channel"))
    end

    @info "Read data for channel $ch from $(length(ch_filekeys)) files"
    # return fast-flattened data
    fast_flatten([
            lh5open(
                ds -> begin
                    # @debug "Reading from \"$(basename(data.tier[tier, fk]))\""
                    ds["$ch"][:]
                end,
                data.tier[tier, fk]
            ) for fk in ch_filekeys
        ])
end