```
similar to main.jl, but not be to in interactive session --> debugging 
```

config  = "./config/processing_config.json"

include("src/startup.jl")

# startup functions with command line utilities
include("src/config.jl")

# evaluate config
l200, processing_config, runs, periods, partitions = get_processingconfig(config)