include("utils/packages.jl")
include("utils/loader.jl")
include("utils/saver.jl")

config_folder = "/home/iwsatlas1/henkes/legend/julia/legend-julia-dsp-scripts/configs/"

stringsToLoad = [1,2,7,8]
period, run, preName, cal = 1, 25, "l60", true
dsp_folder, hit_folder, cut_folder, figure_folder, string_numbers, data_strings, qc_cuts = prepareHit(config_folder, period=period, run=run, preName=preName, cal=cal, stringsToLoad=stringsToLoad)
