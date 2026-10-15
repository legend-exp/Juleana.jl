# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

"""
    module Juleana

The Julia LEGEND Analysis dataflow.

[`Juleana.main`](@ref) is the entry point of the `juleana` app: it opens the terminal
user interface ([`Juleana.run_tui`](@ref)) or, with `--no-tui`, runs the enabled
processors with [`run_processing`](@ref). [`Juleana.setup_session`](@ref) reads the
processing config ([`ProcessingConfig`](@ref)), starts the workers, and returns a
[`DataflowSession`](@ref), which the interactive [`menu`](@ref) also works on. The processors are the functions in `src/processors/`, registered by
name in [`Juleana.PROCESSORS`](@ref). The module also provides the helpers processors
share: distributing work over the worker pool with per-item failure logging
([`parallel`](@ref)), combining per-item log rows into a processor status
([`master_status`](@ref)), report text and formatting helpers, and the Markdown-safe
logger installed on the head and all workers.
"""
module Juleana

using ArgParse: @add_arg_table!, ArgParseSettings, parse_args
import CairoMakie
# Loading CommonMark activates Tachikoma's Markdown extension, which the report viewer renders with.
import CommonMark
using ConcurrentCollections: ConcurrentDict
using Dates: Dates, DateTime, Millisecond, Second, UTC, canonicalize, now, @dateformat_str
using Format: format
import Graphs
using HDF5: h5open
using IntervalSets: (..), leftendpoint, rightendpoint
using LaTeXStrings: LaTeXStrings, @L_str
using LegendDataManagement: LegendDataManagement, DataPeriod, DataRun, DataTier,
    DetectorId, FileKey, LegendData, ProcessStatus, bad_filekeys, channelinfo, data_path,
    dataprod_config, get_aux_cal_propfunc, get_aux_evt_detsel_propfunc, get_exposure,
    get_ged_evt_kwargs, get_values, is_analysis_run, is_lrun, ljl_propfunc, lreport,
    lreport!, lstring, partitioninfo, process_failed, process_succeeded, process_warning,
    read_filekeys, read_ldata, readlprops, runinfo, search_disk, start_filekey,
    write_filekeys, writelprops, writelreport
using LegendDataManagement.LDMUtils: create_logtbl, create_metadatatbl, create_pars,
    create_validity, get_mltrainfilename, get_partition_channelinfo,
    get_partitionvalidity, get_plottitle, get_preportfilename, get_rreportfilename,
    get_totalTimer, savelfig, writevalidity
using LegendDataTypes: decode_data, fast_flatten
using LegendDSP: LegendDSP, DSPConfig, dsp_decay_times, dsp_icpc_compressed, dsp_pmts,
    dsp_qc_flt_optimization_compressed, dsp_qdrift_flt_optimization, dsp_sipm_compressed,
    get_qc_ml_func
using LegendEventAnalysis: LegendEventAnalysis, TimeEvolution, calibrate_all,
    calibrate_ged_detector_data, flag_coincidences, rate, relative, smooth
using LegendHDF5IO: lh5open
import LegendMakie
using LegendSpecFits: LegendSpecFits, autocal_energy, ctc_energy, cut_single_peak, fit_aoe_compton,
    fit_aoe_compton_combined, fit_aoe_corrections, fit_calibration, fit_enc_sigmas,
    fit_fwhm, fit_fwhm_ft, fit_peaks, fit_sf_wl, fit_single_trunc_gauss,
    fit_sipm_spectrum, fit_sipm_threshold, fit_sipm_wl, generate_aoe_compton_bands,
    get_continuum_survival_fraction, get_low_aoe_cut, get_peak_survival_fraction,
    get_peaks_survival_fractions, lq_ctc_correction, lq_norm, peakhists_gamma,
    set_timelimit, simple_calibration, sipm_simple_calibration
using Base.ScopedValues: ScopedValue, with
using Distributed: AbstractWorkerPool, myid, nprocs, nworkers
using Logging: Logging, AbstractLogger, LogLevel, global_logger
using LoggingExtras: ActiveFilteredLogger, FormatLogger, MinLevelLogger, TeeLogger
import Makie
using Measurements: value as mvalue
using ParallelProcessingTools: ParallelProcessingTools, @always_everywhere,
    CreateOrModify, CreateOrReplace, FlexWorkerPool, OnLocalhost, OnSlurm,
    onlyfirst_exception, onworker, original_exception, pinthreads_auto,
    ppt_worker_pool!, ppt_worker_pool, runworkers, write_files, write_worker_start_script
using ProgressLogging: ProgressLogging
using ProgressMeter: @showprogress, Progress, next!, update!
using PropDicts: PropDict
using PropertyFunctions: PropertyFunctions, @pf, filterby
using REPL.TerminalMenus: MultiSelectMenu, RadioMenu, request
using StatsBase: StatsBase, Histogram, fit, mean, median, quantile, std
using StructArrays: StructArray
using Tachikoma: Tachikoma
using TerminalLoggers: TerminalLogger
using TimerOutputs: TimerOutputs, @timeit, TimerOutput
using TypedTables: Table, columnnames, columns
using Unitful: Unitful, @u_str, uconvert, unit, ustrip
import UnitfulAtomic
using UUIDs: UUID, uuid4

include("markdown_logging.jl")
include("file_logging.jl")
include("log_texts.jl")
include("progress.jl")
include("parallel.jl")
include("qc.jl")
include("processing_config.jl")
include("processor_graph.jl")
include("processing_loop.jl")
include("registry.jl")
include("session.jl")
include("config.jl")
include("reports.jl")
include("interactive.jl")
include("controller.jl")
include("no_tui.jl")
include("tui_checklist.jl")
include("tui_kwargs.jl")
include("tui_setup.jl")
include("tui_progress.jl")
include("tui_log.jl")
include("tui_graph.jl")
include("tui_reports.jl")
include("tui.jl")
include("tui_logo.jl")
include("tui_branding.jl")

include("processors/p_process_aoe_calibration_cut.jl")
include("processors/p_process_aoe_cut.jl")
include("processors/p_process_aoe_optimization.jl")
include("processors/p_process_decay_time.jl")
include("processors/p_process_energy.jl")
include("processors/p_process_filter_optimization.jl")
include("processors/p_process_lq_calibration_cut.jl")
include("processors/p_process_psd_efficiencies.jl")
include("processors/p_process_sipm_calibration_phy.jl")
include("processors/p_process_sipm_optimization_phy.jl")
include("processors/p_process_skm_phy.jl")
include("processors/p_process_stability_plots_phy.jl")
include("processors/process_aoe_calibration_cut.jl")
include("processors/process_aoe_optimization.jl")
include("processors/process_ct_correction.jl")
include("processors/process_decay_time.jl")
include("processors/process_dsp_aux_phy.jl")
include("processors/process_dsp_cal.jl")
include("processors/process_dsp_phy.jl")
include("processors/process_energy_calibration.jl")
include("processors/process_evt_phy.jl")
include("processors/process_filter_optimization.jl")
include("processors/process_lq_calibration_cut.jl")
include("processors/process_peak_split.jl")
include("processors/process_psd_efficiencies.jl")
include("processors/process_qcs_cal.jl")
include("processors/process_qcs_phy.jl")
include("processors/process_sipm_calibration_phy.jl")
include("processors/process_sipm_optimization_phy.jl")
include("processors/process_stability_plots_phy.jl")

export UnderscoreSafeLogger
export parallel, failure_log
export master_status, detector_status, truncate_string, truncate_error
export load_qc_evaluator
export ProcessingConfig, ProcessorSpec, run_steps, partition_steps, check_processor_kwargs
export ProcessorGraph, processor_graph, topological_order, required_processors, dependent_processors, layered_layout
export run_processing, ProcessingStopped, ProgressStore, progress, busy_workers, step_messages, show_progress
export DataflowSession, menu
export DataflowController, dispatch!, snapshot, ControllerCommand, LoadSession, ReloadConfig,
    SelectPeriods, SelectRuns, SelectSteps, SetReprocess, SetAnalysisRunsOnly, SetCheckDependencies, SetKwarg,
    ResetKwargs, ResetDependencyGraph, StartProcessing, StopProcessing, WriteConfig, SubmitWorkers

public effective_config, escape_log_underscores, processing_logger, process_log_file, parse_log_level, wait_for, PROCESSORS, register_processor!, init_process,
    main, setup_session, run_no_tui, run_tui, parse_commandline, check_reports,
    report_path, read_report, report_index, failure_summary, report_overview

end # module
