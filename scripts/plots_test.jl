using LegendDataManagement, SolidStateDetectors, Plots
using TypedTables, Unitful, PropDicts, PropertyFunctions
l200 = LegendData(:l200)

chinfo = Table(channelinfo(l200, (:p03, :r000, :cal); system=:geds)) 
detstring = sort(unique(chinfo.detstring))
max_pos = maximum(chinfo.position)
chinfo = sort(chinfo, lt=(a, b) -> (a.detstring < b.detstring) || (a.detstring == b.detstring) && (a.position < b.position))
dets = chinfo.detector

cgrad_fwhm = cgrad(:magma, 0:0.1:10)
# [if isempty(chinfo |> filterby(@pf $detstring == dstr && $position == pos)) plot() else for dstr in 1:detstring, for pos in 1:max_pos]
array_plot = Plots.Plot[]
pars_ecal = get_values(l200.par.rpars.ecal.p03.r000)
max_fwhm_cgrad = 10u"keV"
e_type = :e_cusp_ctc

for dstr in detstring
    dstr_plots = [plot(SolidStateDetector(l200, det), color=cgrad_fwhm[ifelse(pars_ecal[det][e_type].fwhm.qbb isa PropDicts.MissingProperty, 0.0u"keV", pars_ecal[det][e_type].fwhm.qbb) / max_fwhm_cgrad], linecolor=cgrad_fwhm[ifelse(pars_ecal[det][e_type].fwhm.qbb isa PropDicts.MissingProperty, 0.0u"keV", pars_ecal[det][e_type].fwhm.qbb) / max_fwhm_cgrad]) for det in (chinfo |> filterby(@pf $detstring == dstr)).detector]
    if length(dstr_plots) < max_pos
        append!(dstr_plots, [plot() for i in 1:max_pos-length(dstr_plots)])
    end
    append!(array_plot, dstr_plots)
end

plot(
    array_plot...,
    layout = (length(detstring), max_pos), lw = 0.05, legend = false, grid = false, showaxis = false,
    xlims = (-0.05,0.05), ylims = (-0.05,0.05), zlims = (0,0.1), size = (4000,1500),
    camera = (0,0)
)