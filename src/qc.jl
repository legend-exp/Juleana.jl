"""
    load_qc_evaluator(l200::LegendData, filekey::FileKey)

Return the ML quality-cut evaluator for `filekey`, built by `LegendDSP.get_qc_ml_func`
from the trained model file `get_mltrainfilename(l200, filekey)` and the
`l200.par.rpars.ml` parameters, and log which file was used.

Return `missing` and log an info message if the model file does not exist; errors while
reading an existing file propagate. The DSP processors skip the Haar wavelet
classification when the evaluator is `missing` and set `qc_label` to `-1`.
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
