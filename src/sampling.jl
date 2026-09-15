# Selecting a subset of events: the fits downstream need far fewer waveforms than a run holds.

"""
    sample_events(data, n::Integer; select_random::Bool = true)

`n` events of `data`, in their original order.

They are drawn without replacement, or are the first `n` events for `select_random = false`.
`data` is returned unchanged when it holds at most `n` events and for `n <= 0`, which selects
everything. A table is sampled row-wise, so its columns stay aligned.
"""
function sample_events(data, n::Integer; select_random::Bool = true)
    (n <= 0 || length(data) <= n) && return data
    select_random || return data[begin:(begin + n - 1)]
    data[sort!(StatsBase.sample(eachindex(data), n; replace = false))]
end

"""
    read_ldata_sampled(f, data::LegendData, tier, cat, partinfo::Table, det; n_evts, select_random)
    read_ldata_sampled(f, data::LegendData, tier, filekeys::AbstractVector{FileKey}, det; n_evts, select_random)

`read_ldata` over the runs of `partinfo` or over `filekeys`, keeping `n_evts` events of each
of them.

Reading and sampling one run or file at a time keeps the memory needed independent of how
long the selection is, which the whole-selection read followed by a cut does not. `n_evts <= 0`
keeps everything. See [`sample_events`](@ref) for how the events are picked.
"""
function read_ldata_sampled end

read_ldata_sampled(f, data::LegendData, tier::DataTierLike, cat::DataCategoryLike, partinfo::Table, det; n_evts::Int = -1, select_random::Bool = true) =
    fast_flatten([sample_events(read_ldata(f, data, tier, cat, row.period, row.run, det), n_evts; select_random) for row in partinfo])

read_ldata_sampled(f, data::LegendData, tier::DataTierLike, filekeys::AbstractVector{FileKey}, det; n_evts::Int = -1, select_random::Bool = true) =
    fast_flatten([sample_events(read_ldata(f, data, tier, fk, det), n_evts; select_random) for fk in filekeys])
