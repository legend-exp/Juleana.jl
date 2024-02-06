# include all exported functions

# Load packages and modules
include("startup.jl")

# startup functions with command line utilities
include("config.jl")

# Utilities and functionalities for parallel processing
include("parallel.jl")

# Utilities and functionalities for logging
include("logging.jl")
using .LegendLogging

# Utilities and functionalities for data processing
include("utils.jl")