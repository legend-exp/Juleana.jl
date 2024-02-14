# create pars PropDict from result after parallel processing
function create_pars(pd::PropDict, result)
    for (chinfo_ch, res_ch) in result
        if res_ch.processed isa Dict || res_ch.processed
            det = chinfo_ch.detector
            pd_det = ifelse(haskey(pd, det), pd[det], PropDict())
            pd_det = nt2pd(pd_det, res_ch.result)
            pd[det] = pd_det
        end
    end
    pd
end


# convert NamedTuple to PropDict
function nt2pd(pd::PropDict, nt::Union{NamedTuple, Dict})
    for k in keys(nt)
        if nt[k] isa NamedTuple || nt[k] isa Dict
            pd[k] = if !(haskey(pd, k)) PropDict() end
            nt2pd(pd[k], nt[k])
        else
            pd[k] = nt[k]
        end
    end
    pd
end


# write validity.jsonl
function writevalidity(props_db::LegendDataManagement.PropsDB, filekey::FileKey)
    # write validity
    # get timestamp from filekey
    pars_validTimeStamp = string(filekey.time)
    # get validity filename and check if exists
    validity_filename = joinpath(data_path(props_db), "validity.jsonl")
    mkpath(dirname(validity_filename))
    touch(validity_filename)
    # check if validity already written
    has_validity = any([contains(ln, "$pars_validTimeStamp") for ln in eachline(open(validity_filename, "r"))])
    if !has_validity
        @info "Write validity for $pars_validTimeStamp"
        open(validity_filename, "a") do io
            println(io, "{\"valid_from\":\"$pars_validTimeStamp\", \"category\":\"all\", \"apply\":[\"$(filekey.period)/$(filekey.run).json\"]}")
        end
    else
        @info "Validity for $pars_validTimeStamp already written"
    end
end