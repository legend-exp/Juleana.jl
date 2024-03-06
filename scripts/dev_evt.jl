using LegendDataManagement, LegendHDF5IO, LegendEventAnalysis
using ProgressMeter
using HDF5: h5open
using LegendDataTypes: writedata

using Distributed, LegendDataManagement, ThreadPinning
legend_addprocs(ncores())

@everywhere begin
using LegendDataManagement, LegendHDF5IO, LegendEventAnalysis
using ProgressMeter
using HDF5: h5open
using LegendDataTypes: writedata
end # everywhere

l200 = LegendData(:l200)

#period, run = DataPeriod(3), DataRun(0)
#found_filekeys = search_disk(FileKey, data.tier[:dsp, :phy, period, run])

part = DataPartition(1)
partinfo = partitioninfo(l200)[part]
found_filekeys = [filekey for (period, run) in partinfo if is_analysis_run(l200, period, DataRun(run.no +1)) for filekey in search_disk(FileKey, l200.tier[:jldsp, :phy, period, run])]

filekeys = filter(Base.Fix2(!in, bad_filekeys(l200)), found_filekeys)

filekey = first(filekeys)
input_filename = l200.tier[:jldsp, filekey]
output_filename = l200.tier[:jlevt, filekey]


caloutput = lh5open(input_filename)
t = calibrate_all(l200, filekey, caloutput)
    
mkpath(dirname(output_filename))
h5open(output -> writedata(output, "events", caloutput), output_filename, "w")

result = @showprogress pmap(filekeys) do filekey
    data = LegendData(:l200)
    input_filename = data.tier[:jldsp, filekey]
    output_filename = data.tier[:jlevt, filekey]

    try
        sel = ValiditySelection(filekey)
        caloutput = lh5open(input_filename) do datastore
            calibrate_all(data, sel, datastore)
        end
        mkpath(dirname(output_filename))
        h5open(output -> writedata(output, "events", caloutput), output_filename, "w")
        return (filekey = filekey, success = true)
    catch e
        @error "Error processing $filekey: $e"
        return (filekey = filekey, success = false)
    end
end

@info "Successfully proccessed $(count([r.success for r in result])) of $(length(filekeys)) files"