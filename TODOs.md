# A list of ToDos for the LEGEND julia analysis
-  Implement Oli's Peak fitting with "priors"
   - With single peak fit
   - With combined fits
   - Play with parameters
   - FWHM determination with root search algorithm
   - For skewed Gauss: Maybe also way of combining multiple peaks with shared parameters
- Implement integrator in DSP chain 
- Charge Trapping correction
- Split raw data file in files with FEP of one channel
- A/E implementation 
- Restructure configs to be able to process L200 data
- Apply everyhting to L200
- Why has SGflt negative values? signumn error inm derivative calculation?


- Send Danielle papers about PZ deconvolution


# New stuff to implement till monday presentation
- CT correction with gradient decent
   - CT parameter to optimize: FWHM/peak_height
   - peak_height with optim find min of negative peak
- A/E implementation with fits to compton bands
- Finish energy optimization
- Re-run DSP with Qdrift parameter
- Implement ZAC filter in DSP chain
- Implement p-value in peak fits
- Update loader with better and faster loading from Oli
- Remove plotting from fit_peaks.jl function


