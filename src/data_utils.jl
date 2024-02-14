###################
# Data Access utils
###################

function get_peaksfilename end
get_peaksfilename(data::LegendData, setup::ExpSetupLike, period::DataPeriodLike, run::DataRunLike, category::DataCategoryLike, ch::ChannelIdLike) = joinpath(data.tier[:peaks, :cal, period, run], format("{}-{}-{}-{}-{}-tier_peaks.lh5", string(setup), string(period), string(run), string(category), string(ch)))
get_peaksfilename(data::LegendData, filekey::FileKey, ch::ChannelIdLike) = get_peaksfilename(data, filekey.setup, filekey.period, filekey.run, filekey.category, ch)