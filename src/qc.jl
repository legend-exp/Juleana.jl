"""
    load_qc_evaluator(l200::LegendData, filekey::FileKey)

Load the ML QC evaluator function if available.

Returns `missing` if no trained model file exists for `filekey`; errors while
reading an existing file propagate. Downstream DSP code skips Haar wavelet classification
when the evaluator is `missing` and defaults `qc_label` to `-1`.
"""
function load_qc_evaluator(l200::LegendData, filekey::FileKey)
    ml_filename = get_mltrainfilename(l200, filekey)
    
    if isfile(ml_filename)
        f_evaluate_qc = h5open(ml_filename) do train_data
            get_qc_ml_func(
                Array(train_data["ml_train/dsp/dwt_norm"]), 
                Array(train_data["ml_train/dsp/dc_label"]), 
                l200.par.rpars.ml(filekey)
            )
        end
        @info "Loaded trained SVM model from $(basename(ml_filename))"
        return f_evaluate_qc
    else
        @info "ML training file not found: $(basename(ml_filename)) - skipping ML QC"
        return missing
    end
end
