using Plots
using Unitful
using CSV
using DataFrames

nthreads =     [2,       4,        8,      16,       32,        64]
timerresults = [404u"s", 515u"s", 606u"s", 691u"s", 775u"s", 861u"s"]
plotlyjs()
plot(nthreads, timerresults, label="timer", legend=:topleft, xlabel="nthreads", ylabel="time", title="timer threads")
savefig("timer_threads_plots.png")

timing_file = "/home/iwsatlas1/henkes/legend/julia/julia-dsp/tests/data/timing_filter.csv"
df_timing = CSV.File(timing_file) |> DataFrame
plotlyjs()
scatter(df_timing.threads, df_timing.avg, label="trap filter", legend=:topleft, xlabel="nthreads", ylabel="time", title="filter threads")
ylims!(0, 250)
xlims!(0, 135)