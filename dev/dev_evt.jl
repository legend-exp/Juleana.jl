using LegendDataManagement, LegendDataManagement.LDMUtils, LegendHDF5IO, LegendEventAnalysis
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
good_filekeys = get_partitionfilekeys(l200, part, :raw, :phy)

filekey = first(good_filekeys)
input_filename = l200.tier[:jldsp, filekey]
output_filename = l200.tier[:jlevt, filekey]


caloutput = lh5open(input_filename)
t = calibrate_all(l200, filekey, caloutput)
using TypedTables
Table(t)

# ljl_propfunc(PropDict(
#     "e_trap_cal" => cf_trap,
#     "e_cusp_cal" => cf_cusp

# )).(chdata)
# mkpath(dirname(output_filename))
# h5open(output -> writedata(output, "events", caloutput), output_filename, "w")

# @showprogress pmap(filekeys) do filekey
#     input_filename = l200.tier[:jldsp, filekey]
#     output_filename = l200.tier[:jlevt, filekey]

#     try
#         caloutput = lh5open(input_filename) do datastore
#             calibrate_all(l200, filekey, datastore)
#         end
#         append!(t, Table(caloutput))
#     catch e
#         @error "Error processing $filekey: $(truncate_string(string(e)))"
        
#     end
# end

result = @showprogress pmap(filekeys) do filekey
    input_filename = l200.tier[:jldsp, filekey]
    output_filename = l200.tier[:jlevt, filekey]

    try
        caloutput = lh5open(input_filename) do datastore
            calibrate_all(l200, filekey, datastore)
        end
        mkpath(dirname(output_filename))
        rm(output_filename, force = true)
        atomic_fcreate(output_filename) do tmp_filename
            h5open(output -> writedata(output, "events", caloutput), tmp_filename, "w")
        end
        return (filekey = filekey, success = true)
    catch e
        @error "Error processing $filekey: $(truncate_string(string(e)))"
        return (filekey = filekey, success = false)
    end
end

@info "Successfully proccessed $(count([r.success for r in result])) of $(length(filekeys)) files"
