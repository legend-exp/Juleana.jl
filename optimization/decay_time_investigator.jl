### A Pluto.jl notebook ###
# v0.19.26

using Markdown
using InteractiveUtils

# This Pluto notebook uses @bind for interactivity. When running this notebook outside of Pluto, the following 'mock version' of @bind gives bound variables a default value (instead of an error).
macro bind(def, element)
    quote
        local iv = try Base.loaded_modules[Base.PkgId(Base.UUID("6e696c72-6542-2067-7265-42206c756150"), "AbstractPlutoDingetjes")].Bonds.initial_value catch; b -> missing; end
        local el = $(esc(element))
        global $(esc(def)) = Core.applicable(Base.get, el) ? Base.get(el) : iv(el)
        el
    end
end

# ╔═╡ ecc1218c-a408-4de6-8cb5-40d29613b9e7
# ╠═╡ show_logs = false
import Pkg; Pkg.activate("/home/iwsatlas1/henkes/l200/auto/")

# ╔═╡ 2f337776-68cd-4b38-9047-88742bfa1c8a
begin
	using PlutoUI
	import PlutoUI: combine
end

# ╔═╡ 493bdebf-7802-4938-8693-5e0648bd8a2b
# ╠═╡ show_logs = false
begin
	ENV["JULIA_DEBUG"] = Main # enable debug
	ENV["JULIA_CPU_TARGET"] = "generic" # enable AVX2
	# import Pkg; Pkg.instantiate(); Pkg.precompile() # load packages
	
	using LegendDataManagement, PropertyFunctions, TypedTables, PropDicts
	using Unitful, Formatting, LaTeXStrings
	using LegendHDF5IO, LegendDSP, LegendSpecFits
	using Distributed, ProgressMeter

	using LegendDataTypes
	using LegendDataTypes: fast_flatten, flatten_by_key, map_chunked
	
	l200 = LegendData(:l200)
	@info "Loading Legend MetaData"
end

# ╔═╡ cf295ad2-13ca-4508-bf51-5cfc52229fbd
# ╠═╡ show_logs = false
begin
	using Plots
	plotlyjs()
end;

# ╔═╡ 98a808df-40ff-4eda-89ee-772147f7e42f
html"""<style>
main {
	max-width: 80%;
	margin-right: 0;
}
"""

# ╔═╡ f2cf0e3f-d544-4a0b-bcdf-d02bf9beb9d6
html"""
<style>
input[type*="range"] {
	width: 30%;
}
</style>
"""

# ╔═╡ d35a8320-ae1e-485d-8751-1a2b36f2b809
legend_logo = "https://legend-exp.org/typo3conf/ext/sitepackage/Resources/Public/Images/Logo/logo_legend_tag_next.svg";

# ╔═╡ 4933bfe7-2d34-4283-bd4f-2cb0006c5158
md"""$(Resource(legend_logo))
## Julia Analysis Software - Inspector
This tool lets you investigate a certain set of waveforms for a specififc detector and how certain parameters impact the DSP.
"""

# ╔═╡ 24b387ff-5df5-45f9-8857-830bc6580857
md""" ### Parameter settings
"""

# ╔═╡ 39b468d4-673c-4834-b042-d80cd9e0dfe7
md"Select Period"

# ╔═╡ 2c4dd859-0aa6-4cd2-94b3-7a171368065b
begin
	periods = search_disk(DataPeriod, l200.tier[:raw, :cal])
	@bind period Select(periods, default=DataPeriod(3))
end

# ╔═╡ 63b6be12-3b55-450a-8a2a-3d410f0dcb6c
md"Select Run"

# ╔═╡ 36232152-9811-4520-ba65-0f855e4ebbe4
begin
	runs = search_disk(DataRun, l200.tier[:raw, :cal, period])
	@bind run Select(runs, default=DataRun(1))
end

# ╔═╡ dd962859-e7a8-419e-87df-3c2499f013e5
begin
	@info "Investigate DSP for period $period and run $run"
	
	filekeys = sort(search_disk(FileKey, l200.tier[:raw, :cal, period, run]), by = x-> x.time)
	filekey = filekeys[1]
	@info "Found filekey $filekey"
	chinfo = channel_info(l200, filekey) |> filterby(@pf $system == :geds && $processable)
	
	sel = LegendDataManagement.ValiditySelection(filekey.time, :cal)
	dsp_meta = l200.metadata.dataprod.config.cal.dsp(sel).default
	dsp_config = create_dsp_config(dsp_meta)
	@debug "Loaded DSP config: $(dsp_config)"
	
	pars_tau_folder     = joinpath(l200.tier[:par, :cal, period, run], "decay_time")
	pars_filename       = format("{}-{}-{}-{}-decay_time.json", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category))
	pars_tau            = readprops(joinpath(pars_tau_folder, pars_filename))
	@debug "Loaded decay times"
	
	pars_optimization_folder = joinpath(l200.tier[:par, :cal, period, run], "optimization")
	pars_filename           = format("{}-{}-{}-{}-filter_optimization.json", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category))
	pars_optimization       = readprops(joinpath(pars_optimization_folder, pars_filename))
	@debug "Loaded optimization parameters"
end

# ╔═╡ 0e685d5c-2cfd-4f02-90a7-846b62a6426b
md"Select detector"

# ╔═╡ 6f67faca-1065-43f6-94a2-345ac74a6a6f
@bind det Select(sort(chinfo.detector), default=:V09372A)

# ╔═╡ f5140e3a-2601-489a-9098-dc78b24ec0c3
begin
	i = findfirst(x -> x == det, chinfo.detector)
	ch_short = chinfo.channel[i]
	ch = format("ch{}", ch_short)
	string_number = chinfo.string[i]
	pos_number = chinfo.position[i]
	cc4_name = chinfo.cc4[i] * "$(chinfo.cc4ch[i])"
	# check if channel can be processed
	if !haskey(pars_tau, det)
    	@warn "No decay time for detector $det, skip channel $ch"
	else
		@info "Selected detector: $det at string $string_number position $pos_number" 
	end
	τ = 400u"µs"
	try
		τ = pars_tau[det].tau.val*u"µs"
	catch e
		@warn "No decay time available for $det"
	end
	trap_rt = 10u"µs"
	trap_ft = 4u"µs"
	try
		pars_filter = pars_optimization[det]
		# get optimal filter parameters
    	trap_rt = pars_filter.trap_rt.val*u"µs"
    	trap_ft = pars_filter.trap_ft.val*u"µs"
	catch e
		@warn "No filter optimization parameter available for $det"
		trap_rt = 10u"µs"
		trap_ft = 4u"µs"
	end
	if haskey(l200.metadata.dataprod.config.cal.dsp.decay_time(sel), det)
		decay_time_config = l200.metadata.dataprod.config.cal.dsp.decay_time(sel)[det]
		@debug "Use config for detector $det"
	else
		decay_time_config = l200.metadata.dataprod.config.cal.dsp.decay_time(sel).default
		@debug "Use default config"
	end
end;

# ╔═╡ de7861dc-5665-4e88-ac00-af15ad1ada5c
md"Select Filekeys (*Multi-Select possible*)"

# ╔═╡ d8fef6df-d831-4248-aeae-84869714f76d
begin
	@bind selected_peaks confirm(MultiSelect([:Tl208a, :Bi212a, :Tl208b, :Tl208DEP_Bi212FEP, :Tl208SEP, :Tl208FEP]))
end

# ╔═╡ 73d945de-e5c7-427e-a75a-b0df28f86bd4
if !isempty(selected_peaks)
	data_ch = fast_flatten([
    LHDataStore(
        ds -> begin
            @debug "Reading from \"$(ds.data_store.filename)\""
            ds[ch][peak][:]
        end,
        joinpath(l200.tier[DataTier(:peaks), :cal, period, run], format("{}-{}-{}-{}-{}-tier_peaks.lh5", string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category), ch))
	) for peak in selected_peaks
	])
end;

# ╔═╡ 81bfbd6e-e5fa-491b-84e7-c4e62644b4e8
begin
	using Dates
	# get waveform data 
	wvfs = data_ch.waveform
	blfc = data_ch.baseline
	ts   = unix2datetime.(ustrip.(data_ch.timestamp))
	evID = data_ch.eventnumber
	efc  = data_ch.daqenergy
end;

# ╔═╡ 4b7b64ec-9689-4a0a-acc1-8f90061e5498
md""" # Decay Time investigator
"""

# ╔═╡ f7211685-e046-47cc-8261-b0c54b466469
@bind n_wvfs_plot confirm(Slider(1:50, default=10))

# ╔═╡ 7ff8481d-4658-4a3f-a671-858edcf389cf
md"Number of plotted waveforms: $(n_wvfs_plot)"

# ╔═╡ 71f6a835-ebac-49e6-aac1-bbcc4d73bfe8
begin
	wvfs_plot_colors  = [p for p in palette(:twelvebitrainbow, n_wvfs_plot)]
	vline_plot_colors = [p for p in palette(:tab10, 6)]
end;

# ╔═╡ 89bfab7a-9f29-49e0-a313-544125367ee8
function dsp_config_input(dsp_pars::Vector)
	
	return combine() do Child
		
		inputs = [
			md""" $(par[1]): $(
				Child(par[1], Slider(par[2], default=par[3], show_value=true))
			)"""
			
			for par in dsp_pars
		]
		
		md"""
		#### DSP Config
		$(inputs)
		"""
	end
end;

# ╔═╡ ee95f35f-4c9c-4323-8f97-4beafab379fe
@bind dsp_config_slider dsp_config_input([["bl_mean_min", (0:1:20)u"µs", dsp_config.bl_mean[1]], ["bl_mean_max", (0:1:60)u"µs", dsp_config.bl_mean[2]], ["pz_fit_min", (40:1:120)u"µs", dsp_config.pz_fit[1]], ["pz_fit_max", (40:1:120)u"µs", dsp_config.pz_fit[2]]])

# ╔═╡ 6aa6b3fa-007a-4e4b-8819-1f2992a83d8f
function fit_config_input(dsp_pars::Vector)
	
	return combine() do Child
		
		inputs = [
			md""" $(par[1]): $(
				Child(par[1], Slider(par[2], default=par[3], show_value=true))
			)"""
			
			for par in dsp_pars
		]
		
		md"""
		#### Fit Config
		$(inputs)
		"""
	end
end;

# ╔═╡ 82c13dd6-9abe-4efa-8cc4-97817db0c62c
@bind fit_config_slider fit_config_input([["min_tau", (0.0:50.0:1000.0)u"µs", decay_time_config.min_tau*u"µs"], ["max_tau", (0.0:50.0:1000.0)u"µs", decay_time_config.max_tau*u"µs"], ["nbins", (100:100:2000), decay_time_config.nbins], ["rel_cut_fit", (0.05:0.01:1.0), decay_time_config.rel_cut_fit]])

# ╔═╡ 35fc04da-4adb-4af6-8f01-452b68577f87
begin
	using RadiationDetectorDSP, ArraysOfArrays, IntervalSets, StatsBase
	# get config parameters
	bl_mean_min, bl_mean_max    = dsp_config_slider.bl_mean_min, dsp_config_slider.bl_mean_max
	pz_fit_min, pz_fit_max      = dsp_config_slider.pz_fit_min, dsp_config_slider.pz_fit_max

    # get baseline mean, std and slope
    bl_stats = signalstats.(wvfs, bl_mean_min, bl_mean_max)

    # substract baseline from waveforms
    wvfs_bl = shift_waveform.(wvfs, -bl_stats.mean)

    # extract decay times
    tail_stats = tailstats.(wvfs_bl, pz_fit_min, pz_fit_max)
    
    # return converted to µs vals
    decay_times = uconvert.(u"µs", tail_stats.τ)
	
	# unpack config
	min_τ, max_τ = fit_config_slider.min_tau, fit_config_slider.max_tau
	rel_cut_fit = fit_config_slider.rel_cut_fit
	
	cuts_τ = cut_single_peak(decay_times, min_τ, max_τ, fit_config_slider.nbins, rel_cut_fit)
	
	result, report = fit_single_trunc_gauss(decay_times, cuts_τ)

	# deconvolute waveform
	deconv_flt = InvCRFilter(result.μ)
	wvfs_pz = deconv_flt.(wvfs_bl)

	# tail stats after pz
	tail_stats_after = signalstats.(wvfs_pz, pz_fit_min, pz_fit_max)

	# extract energy with simple trap filter
    uflt_rtft = TrapezoidalChargeFilter(trap_rt, trap_ft)

    wvfs_flt_rtft  = uflt_rtft.(wvfs_pz)

	e_trap_simple = maximum.(wvfs_flt_rtft.signal)
end;

# ╔═╡ f748de16-b5ab-4e7f-8e35-91ceab5be608
begin
	using Distributions
	e_ft = e_trap_simple[isfinite.(e_trap_simple)]
	# create histogram from it
	h = fit(Histogram, e_ft, median(e_ft) - 100:1:median(e_ft) + 100)
	# create peakstats
	ps = LegendSpecFits.estimate_single_peak_stats_th228(h)
	# fit peak 
	result_e, report_e = fit_single_peak_th228(h, ps; uncertainty=false)
end;

# ╔═╡ 73cbfa7e-b18c-4e2f-a39f-ae68bbf4a6fb
wvfs_options = Dict(["Wvf", "Wvf Bl", "Wvf PZ"] .=> [wvfs, wvfs_bl, wvfs_pz]);

# ╔═╡ e6a3a08d-9c64-451f-931c-54d8c3e3d6c5
@bind wvfs_type_selector MultiCheckBox(collect(keys(wvfs_options)))

# ╔═╡ cc99755f-be83-4525-8850-a9df59eaca15
function detector_plot_config_input(dsp_pars::Vector)
	
	return combine() do Child
		
		inputs = [
			md""" $(par[1]): $(
				Child(par[1], Slider(par[2], default=par[3], show_value=true))
			)"""
			
			for par in dsp_pars
		]
		
		md"""
		#### Detector Plot Config
		$(inputs)
		"""
	end
end;

# ╔═╡ d4d256f0-45c5-4f2b-bbc2-3f44b2802805
@bind detector_plot_config_slider detector_plot_config_input([["n_bins_efc", (50:50:1000), 500], ["n_bins_decay_times", (500:100:2000), 1000], ["efc_cut_left", (minimum(efc):1:maximum(efc)), minimum(efc)], ["efc_cut_right", (minimum(efc):1:maximum(efc)), maximum(efc)]])

# ╔═╡ 56faaa8d-50e6-4b8e-aa7b-a8afd38e322d
begin
	using Random
	Random.seed!(n_wvfs_plot)
	n_wvfs = length(detector_plot_config_slider.efc_cut_left .< efc .< detector_plot_config_slider.efc_cut_right)
	wvf_index_efc_cut = collect(1:n_wvfs)[detector_plot_config_slider.efc_cut_left .< efc .< detector_plot_config_slider.efc_cut_right]
	n_wvfs = length(wvf_index_efc_cut)
	rand_wvfs_plot = rand(wvf_index_efc_cut, length(wvf_index_efc_cut))
end;

# ╔═╡ d8f70629-7019-48e6-b7cd-da5a0100bcda
begin
	@bind set_n Slider(1:n_wvfs - n_wvfs % n_wvfs_plot, show_value=true)
end

# ╔═╡ 77ddc928-4b62-4241-8001-01ff84969272
md" Selected subset: $set_n"

# ╔═╡ 54860a44-0823-4cb5-8958-474948138a25
begin
	idx_wvfs_plot = rand_wvfs_plot[set_n:set_n+n_wvfs_plot]
end;

# ╔═╡ 97f7da06-a687-4c62-a8d3-bc42430a9ff1
begin
	pe = stephist(efc, bins=detector_plot_config_slider.n_bins_efc, yscale=:log10, label="DAQ online energy", xlabel="Energy (ADC)", ylabel="Counts", size=(800, 500))#, xlims=(median(efc) - 5 * std(efc), median(efc) + 5 * std(efc)))
	ylims!(ylims()[1], ylims()[2])
	plot!(fill(detector_plot_config_slider.efc_cut_left, 2), [0.1, 1e4], label="Energy Cut Window", color=:red, lw=2.5, ls=:dot)
	plot!(fill(detector_plot_config_slider.efc_cut_right, 2), [0.1, 1e4], label="Energy Cut Window", color=:red, lw=2.5, ls=:dot, showlegend=false)
	title!("DAQ energy")
	p = plot(u"µs", NoUnits, size=(1000, 700), legend=:topright, thickness_scaling=1.0)
	# plot!(wvfs_fc[idx_wvfs_plot], label=permutedims(ts[idx_wvfs_plot]))
	for (iw, w) in enumerate(wvfs_type_selector)
		if iw == 1
			plot!(wvfs_options[w][idx_wvfs_plot], label=permutedims(ts[idx_wvfs_plot]), color=permutedims(wvfs_plot_colors), showlegend=true)
		else
			plot!(wvfs_options[w][idx_wvfs_plot], label=permutedims(ts[idx_wvfs_plot]), color=permutedims(wvfs_plot_colors), showlegend=false)
		end
	end
	ylims!(ylims()[1], ylims()[2])
	vline!([dsp_config_slider.pz_fit_min, dsp_config_slider.pz_fit_max], label="PZ Fit Window", lw=2.5, ls=:dot, color=:red, show_legend=false)
	title!("Waveform Browser")
	pt = histogram(decay_times[fit_config_slider.min_tau .< decay_times .< fit_config_slider.max_tau], bins=detector_plot_config_slider.n_bins_decay_times, label="Decay Time", xlabel="Decay TIme", ylabel="Counts")
	title!("Extracted Decay Times")
	ptf = plot(report, decay_times, cuts_τ)
	xlabel!("Decay Time (µs)")
	title!("Decay Times truncated Normal fit")
	p_specfit = plot(report_e, xlabel="Energy (ADC)")
	title!(format("Spectrum Fit with extracted τ, FWHM {:.2f} ADC", result_e.fwhm))
	ptailstats = histogram(tail_stats_after.slope[median(tail_stats_after.slope) - std(tail_stats_after.slope) .< tail_stats_after.slope .< median(tail_stats_after.slope) + std(tail_stats_after.slope)], bins=1000, xlabel="Tail Slope", ylabel="Counts", label="Tail Slope after PZ")
	title!("Tail Slope after PZ")
	plot([p, ptailstats, pt, ptf, pe, p_specfit]..., layout=(3,2), size=(2500, 2200), legend=:outertopright, bottom_margin=50*Plots.mm, plot_title=format("{} Julia Decay Time Investigator ({}-{}-{}-{})", string(det), string(filekey.setup), string(filekey.period), string(filekey.run), string(filekey.category)))
end

# ╔═╡ Cell order:
# ╟─ecc1218c-a408-4de6-8cb5-40d29613b9e7
# ╟─98a808df-40ff-4eda-89ee-772147f7e42f
# ╟─f2cf0e3f-d544-4a0b-bcdf-d02bf9beb9d6
# ╟─2f337776-68cd-4b38-9047-88742bfa1c8a
# ╟─4933bfe7-2d34-4283-bd4f-2cb0006c5158
# ╟─d35a8320-ae1e-485d-8751-1a2b36f2b809
# ╟─24b387ff-5df5-45f9-8857-830bc6580857
# ╟─493bdebf-7802-4938-8693-5e0648bd8a2b
# ╟─39b468d4-673c-4834-b042-d80cd9e0dfe7
# ╟─2c4dd859-0aa6-4cd2-94b3-7a171368065b
# ╟─63b6be12-3b55-450a-8a2a-3d410f0dcb6c
# ╟─36232152-9811-4520-ba65-0f855e4ebbe4
# ╟─dd962859-e7a8-419e-87df-3c2499f013e5
# ╟─0e685d5c-2cfd-4f02-90a7-846b62a6426b
# ╟─6f67faca-1065-43f6-94a2-345ac74a6a6f
# ╟─f5140e3a-2601-489a-9098-dc78b24ec0c3
# ╟─de7861dc-5665-4e88-ac00-af15ad1ada5c
# ╟─d8fef6df-d831-4248-aeae-84869714f76d
# ╟─73d945de-e5c7-427e-a75a-b0df28f86bd4
# ╟─4b7b64ec-9689-4a0a-acc1-8f90061e5498
# ╟─81bfbd6e-e5fa-491b-84e7-c4e62644b4e8
# ╟─35fc04da-4adb-4af6-8f01-452b68577f87
# ╟─f748de16-b5ab-4e7f-8e35-91ceab5be608
# ╟─cf295ad2-13ca-4508-bf51-5cfc52229fbd
# ╟─7ff8481d-4658-4a3f-a671-858edcf389cf
# ╟─f7211685-e046-47cc-8261-b0c54b466469
# ╟─56faaa8d-50e6-4b8e-aa7b-a8afd38e322d
# ╟─77ddc928-4b62-4241-8001-01ff84969272
# ╟─d8f70629-7019-48e6-b7cd-da5a0100bcda
# ╟─54860a44-0823-4cb5-8958-474948138a25
# ╟─97f7da06-a687-4c62-a8d3-bc42430a9ff1
# ╟─71f6a835-ebac-49e6-aac1-bbcc4d73bfe8
# ╟─73cbfa7e-b18c-4e2f-a39f-ae68bbf4a6fb
# ╟─e6a3a08d-9c64-451f-931c-54d8c3e3d6c5
# ╟─89bfab7a-9f29-49e0-a313-544125367ee8
# ╟─ee95f35f-4c9c-4323-8f97-4beafab379fe
# ╟─6aa6b3fa-007a-4e4b-8819-1f2992a83d8f
# ╟─82c13dd6-9abe-4efa-8cc4-97817db0c62c
# ╟─cc99755f-be83-4525-8850-a9df59eaca15
# ╟─d4d256f0-45c5-4f2b-bbc2-3f44b2802805
