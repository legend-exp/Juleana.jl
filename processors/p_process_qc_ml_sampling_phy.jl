"""
    p_process_qc_ml_sampling_phy(processing_config, l200, period; kwargs...)

`p_process_qc_ml_sampling` for the `phy` category.
"""
p_process_qc_ml_sampling_phy(processing_config::PropDict, l200::LegendData, period::DataPeriod,; kwargs...) =
    p_process_qc_ml_sampling(processing_config, l200, period; kwargs..., category = :phy)
