"""
script to develop/test energy calibration processor (processors/process_energy_calibration.jl)
test on 1 run, 1 detector, 1 energy type as example
"""
include("../src/startup.jl")

l200 = LegendData(:l200) 
period = DataPeriod(4)
run = DataRun(2)
reprocess=true
timeout = 300
    
@info "Energy calibration for period $period and run $run"

filekey = start_filekey(l200, (period, run, :cal))
@info "Found filekey $filekey"

chinfo = Table(channelinfo(l200, filekey; system=:geds, only_processable=true))
@info "Loaded channel info with $(length(chinfo)) channels"

energy_config = dataprod_config(l200).energy(filekey)
@debug "Loaded energy config: $(energy_config)"

pars_ctc = get_values(l200.par.rpars.ctc[period, run])
@debug "Loaded CTC parameters"

@debug "Create pars db"
pars_db = ifelse(l200.par.rpars.ecal[period, run] isa LegendDataManagement.NoSuchPropsDBEntry, PropDict(), l200.par.rpars.ecal[period, run])

pars_db = ifelse(reprocess, PropDict(), pars_db)
if reprocess @info "Reprocess all channels" end

# create log line Tuple
log_nt = NamedTuple{(:Channel, :Detector, :Status, Symbol("Filter Type"), Symbol("FWHM Qbb"), Symbol("FWHM FEP"), Symbol("Cal. Constant"), :Error)}

chinfo_ch = chinfo[1]
ch  = chinfo_ch.channel
det = chinfo_ch.detector

@debug "Processing channel $ch ($det)"

hitchfilename = get_hitchfilename(l200, filekey, ch)
# load data file
if !isfile(hitchfilename)
@error "Hit file $hitchfilename not found"
throw(ErrorException("Hit file not found"))
end

result_dict    = Dict{Symbol, NamedTuple}()
log_info_dict  = Dict{Symbol, NamedTuple}()
processed_dict = Dict{Symbol, Bool}()

energy_config_ch = merge(energy_config.default, get(energy_config, det, PropDict()))

energy_types = Symbol.(energy_config_ch.energy_types)
e_type = :e_cusp

if !reprocess && haskey(pars_db, det)
@debug "Channel $(det) already processed, check missing energy types"
for e_type in energy_types
    if haskey(pars_db[det], e_type)
        @debug "Filter $e_type already processed, skip"
        log_info = log_nt((ch, det, ProcessStatus(1), e_type, pars_db[det][e_type].fwhm.qbb, pars_db[det][e_type].fit.Tl208FEP.fwhm, pars_db[det][e_type].m_calib, "Already processed --> skipped."))
        processed_dict[e_type] = false
        log_info_dict[e_type] = log_info
    end
end
end

# load data file
if !isfile(hitchfilename)
@error "Hit file $hitchfilename not found"
throw(ErrorException("Hit file not found"))
end
# get data
data_ch_after_qc = nothing
try
@debug "Load hit file"
data_hit = LHDataStore(hitchfilename, "r");
data_ch_after_qc = data_hit["$(ch)/dataQC"][:];
close(data_hit)
catch e
@error "Error in loading data for channel $ch: $e"
throw(ErrorException("Error data loader"))
end

quantile_perc = if energy_config_ch.quantile_perc isa String parse(Float64, energy_config_ch.quantile_perc) else energy_config_ch.quantile_perc end
th228_names = Symbol.(energy_config_ch.th228_names)
th228_lines = energy_config_ch.th228_lines
th228_lines_dict = Dict(th228_names .=> energy_config_ch.th228_lines)

# @showprogress desc="Detector: $det" for e_type in energy_types
# get data
e_uncal, e_uncal_func = nothing, nothing
try
    @debug "Get $e_type data"
    # open hit data file
    e_type_name = Symbol(split(string(e_type), "_ctc")[1])
    e_uncal = getproperty(data_ch_after_qc, e_type_name)
    e_uncal_func = "$e_type_name"
    if endswith(string(e_type), "_ctc")
        @debug "Apply CT correction for $e_type"
        e_uncal_func = pars_ctc[det][e_type_name].func
        e_uncal = ljl_propfunc(e_uncal_func).(data_ch_after_qc)
    end
catch e
    @error "Error in $e_type data extraction for channel $ch: $e"
    throw(ErrorException("Error in $e_type data extraction"))
end


result_simple, report_simple = simple_calibration(e_uncal, energy_config_ch.th228_lines .* u"keV", energy_config_ch.left_window_sizes .* u"keV", energy_config_ch.right_window_sizes .* u"keV",; calib_type=:th228, n_bins=energy_config_ch.n_bins, quantile_perc=quantile_perc)

# get simple calibration constant
m_cal_simple = result_simple.c
# save plots for simple calibration for control
p = plot(report_simple, margin=5mm, yformatter=:plain, thickness_scaling=1.5, cal=true)

result_fit, report_fit = fit_peaks(result_simple.peakhists, result_simple.peakstats, th228_names; e_unit=result_simple.unit, calib_type=:th228) 
p_peaks = plot(broadcast(k -> plot(report_fit[k], left_margin=20mm,top_margin=-5mm,bottom_margin=-2mm, title=string(k),ms=2),
         keys(report_fit))..., layout=(length(report_fit), 1), size=(1000,710*length(report_fit)) , thickness_scaling=1.8,titlefontsize = 10, legendfontsize = 8, yguidefontsize = 9,xguidefontsize=11) 
plot!(p_peaks, plot_title=get_plottitle(filekey, det, "Peak Fits"; additiional_type=string(e_type)), plot_titlelocation=(0.5,0.2))
# savelfig(savefig, p_peaks, l200, filekey, ch, Symbol("peak_fits_$(e_type)"))
savefig(p_peaks, "test.png")

# do calibration fit 
cal_fit_excluded_peaks = [:Tl208DEP, :Tl208SEP] # tmp fix for cal_fit_excluded_peaks
cal_pol_order = 1 
μ_fit =  [result_fit[p].μ for p in th228_names if !(p in Symbol.(cal_fit_excluded_peaks))] ./ m_cal_simple
pp_fit = [th228_lines_dict[p] for p in th228_names if !(p in Symbol.(cal_fit_excluded_peaks))] .* u"keV"
result_calib, report_calib = fit_calibration(cal_pol_order, μ_fit, pp_fit; e_expression=e_uncal_func)

# plot calibration curve; all peaks 
μ_notfit =  [result_fit[p].μ for p in th228_names if (p in Symbol.(cal_fit_excluded_peaks))] ./ m_cal_simple
pp_notfit = [th228_lines_dict[p] for p in th228_names if (p in Symbol.(cal_fit_excluded_peaks))] .* u"keV"
μ_notfit_cal = ljl_propfunc(result_calib.func).(Table(e_cusp = μ_notfit))
res_norm_nofit = (LegendSpecFits.mvalue.(μ_notfit_cal) .- pp_notfit)./LegendSpecFits.muncert.(μ_notfit_cal)
PltArg = Dict( :ms => 3, :markershape => :circle, :markerstrokecolor => :black, :linewidth => 0.5, :markercolor => :silver)
p = plot(report_calib, xerrscaling=1)
scatter!(p[1], μ_notfit, ustrip(pp_notfit), label="Data not used for fit"; PltArg...)
scatter!(p[2], μ_notfit, res_norm_nofit, label=:none ; PltArg...)
plot!(plot_title=get_plottitle(filekey, det, "Calibration Curve"; additiional_type=string(e_type)), plot_titlelocation=(0.5,-0.3), plot_titlefontsize=12)
# savelfig(savefig, p, l200, filekey, ch, Symbol("calibration_curve_$(e_type)"))

yield()

f_cal(x) = report_calib.f_fit(x) .* report_calib.e_unit .- first(report_calib.par)

result_fwhm, report_fwhm = nothing, nothing
try
    fwhm_fit = f_cal.([result_fit[p].fwhm for p in th228_names if !(p in Symbol.(energy_config_ch.cal_fit_excluded_peaks))] ./ m_cal_simple)
    pp_fit = [th228_lines_dict[p] for p in th228_names if !(p in Symbol.(energy_config_ch.cal_fit_excluded_peaks))]    
    result_fwhm, report_fwhm = fit_fwhm(pp_fit, fwhm_fit; pol_order=energy_config_ch.fwhm_pol_order, e_type_cal=Symbol("$(e_type)_cal"), e_expression=e_uncal_func, uncertainty=true)
    @debug "Found $e_type FWHM: $(round(u"keV", result_fwhm.qbb, digits=2))"
catch e
    @error "Error in $e_type FWHM fitting for channel $ch: $e"
    throw(ErrorException("Error in $e_type FWHM fitting"))
end

p = plot(report_fwhm)
plot!(plot_title=get_plottitle(filekey, det, "FWHM"; additiional_type=string(e_type)), plot_titlelocation=(0.5,-0.3))


