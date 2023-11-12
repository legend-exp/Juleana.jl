#get the necessary parameters for the f_loglike function
i = 1
h = peakhists[i]
ps = peakstats[i]

pseudo_prior = NamedTupleDist(
μ = Uniform(ps.peak_pos-10, ps.peak_pos+10),
σ = weibull_from_mx(ps.peak_sigma, 2*ps.peak_sigma),
n = weibull_from_mx(ps.peak_counts, 2*ps.peak_counts),
step_amplitude = weibull_from_mx(ps.mean_background, 2*ps.mean_background),
skew_fraction = Uniform(0.01, 0.25),
skew_width = LogUniform(0.001, 0.1),
background = weibull_from_mx(ps.mean_background, 2*ps.mean_background),
)

f_trafo = BAT.DistributionTransform(Normal, pseudo_prior)
av_init = mean(pseudo_prior)

#f_loglike to get the parameters needed later
f_loglike = let f_fit=LegendSpecFits.f_fit, h=h
v -> hist_loglike(Base.Fix2(f_fit, v), h)
end

f_trafo = BAT.DistributionTransform(Normal, pseudo_prior)

v_init = mean(pseudo_prior)

opt_r = optimize((-) ∘ f_loglike ∘ inverse(f_trafo), f_trafo(v_init))
v_ml = inverse(f_trafo)(Optim.minimizer(opt_r))

#define the loglikelihood function with the given parameters
f_loglike = let f_fit=LegendSpecFits.f_fit, v = v_ml
h -> hist_loglike(Base.Fix2(f_fit, v), h)
end

f_loglike(peakhists[1])


#create the "dummy histograms" to evaluate the p-parameter
loglike_list = Float64[]
for j in 1:100000
new_weight = Float64[]
for i in 1:length(peakhists[1].weights)
append!(new_weight, rand(Poisson(peakhists[1].weights[i])))
end

histogram = Histogram(2589.5:0.5:2640.0, new_weight)
loglike_erg = f_loglike(histogram)

push!(loglike_list, loglike_erg)
end

histogram(loglike_list, nbin=200)

vline!([f_loglike(peakhists[1])])

#evaluate the p-parameter
p = 0
for i in 1:length(loglike_list)
if loglike_list[i] < f_loglike(peakhists[1])
p = p + 1
end
end

p = p/length(loglike_list)