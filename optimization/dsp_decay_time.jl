using LegendDataManagement
using Unitful
using LegendHDF5IO

using LegendDSP

test_file = "/remote/ceph/group/legendex/data/l200/peaks/cal/p03/r001/l200-p03-r001-cal-ch1078400-tier_peaks.lh5"
data = LHDataStore(test_file, "r")
data_fep = data["ch1078400/Tl208dFEP"][:]
wvfs = data_fep.waveform

test_dsp_config = DSPConfig{Float64}(32.0u"µs", 
                                    (0.0u"µs", 39.0u"µs"), 
                                    (80.0u"µs", 110.0u"µs"), 
                                    5.0, 
                                    7.0u"µs":0.5u"µs":12.0u"µs", 1.0u"µs":0.2u"µs":4.0u"µs",
                                    7.0u"µs":0.5u"µs":12.0u"µs", 1.0u"µs":0.2u"µs":4.0u"µs", 
                                    7.0u"µs":0.5u"µs":12.0u"µs", 1.0u"µs":0.2u"µs":4.0u"µs")




τ = dsp_decay_times(wvfs, test_dsp_config)



