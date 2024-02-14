#################################
# Figure Folder and File Handling
#################################

function get_pltfolder end
get_pltfolder(data::LegendData, period::DataPeriodLike, run::DataRunLike, category::DataCategoryLike, process::Symbol) = mkpath(joinpath(data.tier[:jlplt], "rplt", string(category), string(period), string(run), string(process)))
get_pltfolder(data::LegendData, filekey::FileKey, process::Symbol) = get_pltfolder(data, filekey.period, filekey.run, filekey.category, process)
get_pltfolder(data::LegendData, partition::DataPartitionLike, category::DataCategoryLike, process::Symbol) = mkpath(joinpath(data.tier[:jlplt], "pplt", string(partition), string(category), string(process)))

function get_pltfilename end
get_pltfilename(data::LegendData, setup::ExpSetupLike, period::DataPeriodLike, run::DataRunLike, category::DataCategoryLike, ch::ChannelIdLike, process::Symbol) = joinpath(get_pltfolder(data, period, run, category, process), format("{}-{}-{}-{}-{}-{}.png", string(setup), string(period), string(run), string(category), string(ch), string(process)))
get_pltfilename(data::LegendData, filekey::FileKey, ch::ChannelIdLike, process::Symbol) = get_pltfilename(data, filekey.setup, filekey.period, filekey.run, filekey.category, ch, process)
get_pltfilename(data::LegendData, partition::DataPartitionLike, setup::ExpSetupLike, category::DataCategoryLike, ch::ChannelIdLike, process::Symbol) = joinpath(get_pltfolder(data, partition, category, process), format("{}-{}-{}-{}-{}.png", string(setup), string(partition), string(category), string(ch), string(process)))

function savelfig end
savelfig(p::Plots.Plot, data::LegendData, setup::ExpSetupLike, period::DataPeriodLike, run::DataRunLike, category::DataCategoryLike, ch::ChannelIdLike, process::Symbol; kwargs...) = savefig(p, get_pltfilename(data, setup, period, run, category, ch, process); kwargs...)
savelfig(p::Plots.Plot, data::LegendData, filekey::FileKey, ch::ChannelIdLike, process::Symbol; kwargs...) = savefig(p, get_pltfilename(data, filekey, ch, process); kwargs...)
savelfig(p::Plots.Plot, data::LegendData, partition::DataPartitionLike, setup::ExpSetupLike, category::DataCategoryLike, ch::ChannelIdLike, process::Symbol; kwargs...) = savefig(p, get_pltfilename(data, partition, setup, category, ch, process); kwargs...)


function get_plottitle end
get_plottitle(setup::ExpSetupLike, period::DataPeriodLike, run::DataRunLike, category::DataCategoryLike, det::DetectorIdLike, process::String; additiional_type::String="") = "$(string(det)) $additiional_type $process  ($(string(setup))-$(string(period))-$(string(run))-$(string(category)))"
get_plottitle(filekey::FileKey, det::DetectorIdLike, process::String; kwargs...) = get_plottitle(filekey.setup, filekey.period, filekey.run, filekey.category, det, process; kwargs...)