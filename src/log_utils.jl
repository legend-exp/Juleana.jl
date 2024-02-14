##############################
# Log Folder and File Handling
##############################

function get_logfolder end
get_logfolder(data::LegendData, period::DataPeriodLike, run::DataRunLike, category::DataCategoryLike) = mkpath(joinpath(data.tier[:jllog], "rlog", string(category), string(period), string(run)))
get_logfolder(data::LegendData, filekey::FileKey) = get_logfolder(data, filekey.period, filekey.run, filekey.category)
get_logfolder(data::LegendData, partition::DataPartitionLike, category::DataCategoryLike) = mkpath(joinpath(data.tier[:jllog], "plog", string(partition), string(category)))

function get_logfilename end
get_logfilename(data::LegendData, setup::ExpSetupLike, period::DataPeriodLike, run::DataRunLike, category::DataCategoryLike, process::Symbol) = joinpath(get_logfolder(data, period, run, category), format("{}-{}-{}-{}-{}.md", string(setup), string(period), string(run), string(category), string(process)))
get_logfilename(data::LegendData, filekey::FileKey, process::Symbol) = get_logfilename(data, filekey.setup, filekey.period, filekey.run, filekey.category, process)
get_logfilename(data::LegendData, partition::DataPartitionLike, category::DataCategoryLike, process::Symbol) = joinpath(get_logfolder(data, partition, category), format("{}-{}-{}.md", string(partition), string(category), string(process)))


# create log table from a result fille while adding - for non-exisiting keys in certain loglines
function create_logtbl(result)
    tbl = vcat([collect(values(res.log)) for (itr, res) in result if res.log isa Dict]...)
    append!(tbl, [res.log for (itr, res) in result if !(res.log isa Dict)])
    unique_keys = unique(reduce(vcat, collect.(keys.(tbl))))
    Table([NamedTuple{Tuple(unique_keys)}([get(nt, k, "-") for k in unique_keys]...) for nt in tbl])
end

# log texts that are static in each log report
const decay_time_log_text = """## Decay Time Extraction
This is the log for the decay time extraction. The algorithm loads the FEP data of each channel.
After a mini DSP, the decay times are extracted by fittiing an exponential function to the tail.
Then, the distribution is truncated around the peak to fit a truncated gaussian function.
The centroid of the distribution is extracted as the decay time.
"""

const flt_optimization_log_text = """## Filter Optimization
This is the log for the energy filter optimization. The algorithm loads the FEP data of each channel.
After a mini DSP, the optimal rise time is determined by performing a noise sweep on the baseline and look for minimal ENC with a fixed flat-top time.
Then, the optimal rise time is used for a mini DSP while sweeping through flat-top times and selecting the one which has minimal FWHM at the FEP.
"""

const sg_flt_optimization_log_text = """## SG window length optimization
This is the log for the savitzky-golay filter optimization for the PSD analysis. The processing involves
a small DSP routine on the waveforms in the DEP and SEP, a simple AoE cut for different window lengths
and the calculation of the survival fraction in the SEP after a simple PSD cut on the DEP. Then, the 
window length with the lowest survival fraction is chosen."""