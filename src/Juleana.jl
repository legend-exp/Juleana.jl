# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

"""
    module Juleana

The Julia LEGEND Analysis dataflow.

The module provides the helpers that processors share: distributing work over the
worker pool with per-item failure logging (`parallel`), combining per-item log rows into
a processor status (`master_status`), report text and formatting helpers, and the
Markdown-safe logger used on the head and all workers. It also defines the validated
processing configuration (`ProcessingConfig`, `ProcessorSpec`) that drives the dataflow.
"""
module Juleana

using HDF5: h5open
using LegendDataManagement: LegendData, FileKey, ProcessStatus, DataPeriod, DataRun,
    get_mltrainfilename, process_failed, process_succeeded, process_warning, readlprops
using LegendDSP: get_qc_ml_func
using ParallelProcessingTools: ParallelProcessingTools, @userfriendly_exceptions, onworker
using ProgressMeter: Progress, next!, update!

include("markdown_logging.jl")
include("log_texts.jl")
include("parallel.jl")
include("qc.jl")
include("processing_config.jl")

export UnderscoreSafeLogger
export parallel, failure_log
export master_status, detector_status, truncate_string, truncate_error
export load_qc_evaluator
export ProcessingConfig, ProcessorSpec, run_steps, partition_steps, check_processor_kwargs
export peak_splitting_log_text, decay_time_log_text, flt_optimization_log_text,
    sg_flt_optimization_log_text, dsp_cal_log_text, qcs_cal_log_text, qcs_phy_log_text,
    energy_ctc_log_text, energy_log_text, aoe_log_text, energy_part_log_text,
    aoe_part_log_text, sipm_opt_log_text, lq_log_text, sipm_cal_log_text, evt_log_text,
    skm_log_text

public escape_log_underscores

end # module
