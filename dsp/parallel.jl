using Distributed
using ProgressMeter

include("../utils/packages.jl")
include("../utils/loader.jl")
include("../utils/utils.jl")

include("dsp.jl")


# Define the server addresses
cslg1, cslg2, cslg3             = ["henkes@cslg-01.mpp.mpg.de"], ["henkes@cslg-02.mpp.mpg.de"], ["henkes@cslg-03.mpp.mpg.de"]
tristanserv01, tristanserv02    = ["henkes@tristanserv01.mpp.mpg.de"], ["henkes@tristanserv02.mpp.mpg.de"]

# CSLG01: 56 threads = 28 cores
# addprocs(cslg1, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 14 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, sshflags=`-i /home/iwsatlas1/henkes/.ssh/id_mpp`, max_parallel=4, topology=:master_worker)
# addprocs(cslg1, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 14 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, sshflags=`-i /home/iwsatlas1/henkes/.ssh/id_mpp`, max_parallel=4, topology=:master_worker)

# CSLG02: 72 threads = 36 cores
addprocs(cslg2, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 18 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, sshflags=`-i /home/iwsatlas1/henkes/.ssh/id_mpp`, max_parallel=4, topology=:master_worker)
addprocs(cslg2, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 18 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, sshflags=`-i /home/iwsatlas1/henkes/.ssh/id_mpp`, max_parallel=4, topology=:master_worker)

# CSLG03: 128 threads = 64 cores
addprocs(cslg3, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 16 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, sshflags=`-i /home/iwsatlas1/henkes/.ssh/id_mpp`, max_parallel=4, topology=:master_worker)
addprocs(cslg3, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 16 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, sshflags=`-i /home/iwsatlas1/henkes/.ssh/id_mpp`, max_parallel=4, topology=:master_worker)
addprocs(cslg3, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 16 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, sshflags=`-i /home/iwsatlas1/henkes/.ssh/id_mpp`, max_parallel=4, topology=:master_worker)
addprocs(cslg3, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 16 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, sshflags=`-i /home/iwsatlas1/henkes/.ssh/id_mpp`, max_parallel=4, topology=:master_worker)

# CSLG04: 128 threads = 64 cores, create 2 workers on the localhost
addprocs(4, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 16 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, topology=:master_worker)

# # Tristanserv01: 56 threads = 28 cores
# addprocs(tristanserv01, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 14 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, sshflags=`-i /home/iwsatlas1/henkes/.ssh/id_mpp`, max_parallel=4, topology=:master_worker)
# addprocs(tristanserv01, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 14 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, sshflags=`-i /home/iwsatlas1/henkes/.ssh/id_mpp`, max_parallel=4, topology=:master_worker)

# # # Tristanserv02: 72 threads = 36 cores
# addprocs(tristanserv02, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 18 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, sshflags=`-i /home/iwsatlas1/henkes/.ssh/id_mpp`, max_parallel=4, topology=:master_worker)
# addprocs(tristanserv02, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 18 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, sshflags=`-i /home/iwsatlas1/henkes/.ssh/id_mpp`, max_parallel=4, topology=:master_worker)


@everywhere begin
    using Distributed
    # using ProgressMeter
    include(joinpath(@__DIR__,"../utils/packages.jl"))
    include(joinpath(@__DIR__,"../utils/loader.jl"))
    include(joinpath(@__DIR__,"../utils/utils.jl"))

    include(joinpath(@__DIR__,"dsp.jl"))
end

@everywhere begin
    is_cal = true
    period = 2
    calrun = 11
    config_folder = p"/home/iwsatlas1/henkes/l200/l200-p02-analysis/configs/"
    experiment = "l200"

    channel_list, label_dict, label_list_ext, string_dict, folder_dict = loadMeta(config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)

    channel_label_dict = Dict{String, String}(values(label_dict) .=> keys(label_dict))

    decay_times = loadValues(collect(values(label_dict)), "tau", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
    decay_times = Dict{String, Any}([channel_label_dict[k] for k in keys(decay_times)] .=> values(decay_times).*1u"µs")

    trap_rt     = loadValues(collect(values(label_dict)), "trap_rt", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
    trap_rt     = Dict{String, Any}([channel_label_dict[k] for k in keys(trap_rt)] .=> values(trap_rt).*1u"µs")

    trap_ft     = loadValues(collect(values(label_dict)), "trap_ft", config_folder, period=period, run=calrun, experiment=experiment, cal=is_cal)
    trap_ft     = Dict{String, Any}([channel_label_dict[k] for k in keys(trap_ft)] .=> values(trap_ft).*1u"µs")

    folder_raw, folder_dsp = folder_dict["folder_raw"], folder_dict["folder_dsp"]
end
println("Starting DSP\n\n")
printfmtln("Using {} threads on PID 1\n\n", Threads.nthreads())
println()
checkFolder(PosixPath(folder_dsp), true)
println("Start DSP for $experiment, period $period, run $calrun")
println("Loading meta data")
println("Using folder $folder_raw for raw data")
println("Using folder $folder_dsp for dsp data")
println()
for (root, dirs, files) in walkdir(folder_raw)
    hdf5_files = filter(f -> endswith(f, ".lh5"), files)
    status = @showprogress pmap(hdf5_files) do data_file
        try
            filename = joinpath(folder_raw, data_file)
            
            outfile = string(split(data_file, "_")[1], "_dsp.lh5")
            outfilename = joinpath(folder_dsp, outfile)

            processFile(filename, outfilename, channel_list, decay_times, trap_rt, trap_ft)
            true # success
        catch e
            false # failure
        end
    end
end
