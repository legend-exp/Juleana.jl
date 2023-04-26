using Distributed
using ProgressMeter

include("dsp_aoe.jl")
include("../utils/loader.jl")

# Define the server addresses
cslg1, cslg2, cslg3             = ["henkes@cslg-01.mpp.mpg.de"], ["henkes@cslg-02.mpp.mpg.de"], ["henkes@cslg-03.mpp.mpg.de"]
tristanserv01, tristanserv02    = ["henkes@tristanserv01.mpp.mpg.de"], ["henkes@tristanserv02.mpp.mpg.de"]

# CSLG01: 56 threads = 28 cores
# addprocs(cslg1, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 14 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, sshflags=`-i /home/iwsatlas1/henkes/.ssh/id_mpp`, max_parallel=4, topology=:master_worker)
# addprocs(cslg1, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 14 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, sshflags=`-i /home/iwsatlas1/henkes/.ssh/id_mpp`, max_parallel=4, topology=:master_worker)

# CSLG02: 72 threads = 36 cores
# addprocs(cslg2, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 18 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, sshflags=`-i /home/iwsatlas1/henkes/.ssh/id_mpp`, max_parallel=4, topology=:master_worker)
# addprocs(cslg2, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 18 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, sshflags=`-i /home/iwsatlas1/henkes/.ssh/id_mpp`, max_parallel=4, topology=:master_worker)

# CSLG03: 128 threads = 64 cores
# addprocs(cslg3, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 32 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, sshflags=`-i /home/iwsatlas1/henkes/.ssh/id_mpp`, max_parallel=4, topology=:master_worker)
# addprocs(cslg3, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 32 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, sshflags=`-i /home/iwsatlas1/henkes/.ssh/id_mpp`, max_parallel=4, topology=:master_worker)

# CSLG04: 128 threads = 64 cores, create 2 workers on the localhost
addprocs(8, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 16 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, topology=:master_worker)

# # Tristanserv01: 56 threads = 28 cores
# addprocs(tristanserv01, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 14 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, sshflags=`-i /home/iwsatlas1/henkes/.ssh/id_mpp`, max_parallel=4, topology=:master_worker)
# addprocs(tristanserv01, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 14 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, sshflags=`-i /home/iwsatlas1/henkes/.ssh/id_mpp`, max_parallel=4, topology=:master_worker)

# # # Tristanserv02: 72 threads = 36 cores
# addprocs(tristanserv02, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 18 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, sshflags=`-i /home/iwsatlas1/henkes/.ssh/id_mpp`, max_parallel=4, topology=:master_worker)
# addprocs(tristanserv02, exename=`/home/iwsatlas1/henkes/julia-1.8.5/bin/julia`, exeflags=`-t 18 --project=/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts`, sshflags=`-i /home/iwsatlas1/henkes/.ssh/id_mpp`, max_parallel=4, topology=:master_worker)


# Split the execution into two threads, each using 64 cores
@everywhere begin
    using Distributed
    using ProgressMeter
    include(joinpath(@__DIR__,"dsp_aoe.jl"))
    include(joinpath(@__DIR__,"../utils/loader.jl"))

    config_folder = "/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts/configs/"

    period, run, preName, cal = 1, 25, "l60", true
    data_folder, out_data_folder, string_numbers, decay_times = prepareDSP(config_folder, period=period, run=run, preName=preName, cal=cal)
end
println("Starting DSP\n\n")
printfmtln("Using {} threads on PID 1\n\n", Threads.nthreads())


for (root, dirs, files) in walkdir(data_folder)
    hdf5_files = filter(f -> endswith(f, ".lh5"), files)
    status = @showprogress pmap(hdf5_files) do data_file
        try
            filename = joinpath(data_folder, data_file)
            
            outfile = string("dsp_", split(data_file, "_")[2])
            outfilename = joinpath(out_data_folder, outfile)

            processFile(filename, outfilename, decay_times)
            true # success
        catch e
            false # failure
        end
    end
end
