# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

"""
    Juleana

Meta-package for the Julia software stack of the
[LEGEND experiment](https://legend-exp.org/).
"""
module Juleana

import BAT
import LegendDSP
import LegendDataManagement
import LegendDataTypes
import LegendEventAnalysis
import LegendHDF5IO
import LegendSpecFits
import LegendTestData
import LegendTextIO
import RadiationDetectorDSP
import RadiationDetectorSignals
import RadiationSpectra
import SolidStateDetectors

export BAT
export LegendDSP
export LegendDataManagement
export LegendDataTypes
export LegendEventAnalysis
export LegendHDF5IO
export LegendSpecFits
export LegendTestData
export LegendTextIO
export RadiationDetectorDSP
export RadiationDetectorSignals
export RadiationSpectra
export SolidStateDetectors

end # module
