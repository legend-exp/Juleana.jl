ch  = chinfo_ch.channel
det = chinfo_ch.detector

if !reprocess && haskey(pars_db, det)
    @debug "Channel $(det) already processed, skip"
    pars_det = pars_db[det]
    log_ch = log_nt(ch, det, "Success", pars_det.n_compton, pars_det.μ_scs[2], pars_det.μ_scs[1], "-")
    return (processed = false, log = log_ch)
end

@info "Processing channel $ch ($det)"

hitchfilename = get_hitchfilename(l200, filekey, ch)
# load data file
if !isfile(hitchfilename)
    @error "Hit file $hitchfilename not found"
    throw(ErrorException("Hit file not found"))
end

psd_config_ch = merge(psd_config.default, get(psd_config, det, PropDict()))

compton_bands  = psd_config_ch.compton_bands
compton_window = psd_config_ch.compton_window
p_value        = psd_config_ch.p_value
e_type         = Symbol(psd_config_ch.energy_type)

if !haskey(pars_energy, det) || !haskey(pars_energy[det], e_type)
    @error "Energy calibration for $(det) not found"
    throw(ErrorException("Energy calibration for $(det) not found"))
end

data_hit = LHDataStore(hitchfilename, "r");
# get a
a = data_hit["$(ch)/dataQC/a"][:];
# get energy for best resolution
e = data_hit["$(ch)/dataQC/$(e_type)"][:];
e  = e .* pars_energy[det][e_type].m_calib .+ pars_energy[det][e_type].n_calib;
# get aoe
aoe = ustrip.(a ./ e);
dcr = data_hit["$(ch)/dataQC/tailslope"][:];
drifttime = data_hit["$(ch)/dataQC/drift_time"][:]; 
close(data_hit)

p = histogram2d(e, dcr, nbins=(0:0.5:3000, -0.005:1e-5:0.005), xlims=(0, 3000), size=(1200, 800), color=cgrad(:magma), colorbar_scale=:log10, legend=:topleft, xlabel="Energy", ylabel="Tail Slope", margin=5mm)
ylims!(-0.005, 0.005)
xticks!(p, 0:250:3000)
title!(p, get_plottitle(filekey, det, "AoE Uncalibrated"))

keV = u"keV"
fep_cut = 2614keV - 5keV .< e .< 2614keV + 5keV

histogram2d(dcr[fep_cut], drifttime[fep_cut], nbins=(2609:0.5:2619, 100:10:3000))