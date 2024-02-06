using LegendDataManagement
using PropDicts
using Unitful
using Measurements
using Measurements: value, uncertainty

l200 = LegendData(:l200)

dets = channelinfo(l200, (:p03, :r000, :cal); system=:geds, only_processable=true).detector
chs = channelinfo(l200, (:p03, :r000, :cal); system=:geds, only_processable=true).channel


pars = l200.par.rpars.pz.p03.r000

filekey = start_filekey(l200, (:p03, :r000, :cal))


function Unitful.uparse(pd::PropDict)
    for (key, val) in pd
        if val isa PropDict
            if val isa Unitful.Quantity
                continue
            elseif haskey(val, :unit) && haskey(val, :val) && haskey(val, :err)
                pd[key].val = Unitful.Quantity(val.val, Unitful.uparse(val.unit))
                pd[key].err = Unitful.Quantity(val.err, Unitful.uparse(val.unit))
                delete!(pd[key], :unit)
            elseif haskey(val, :unit) && haskey(val, :val)
                if length(keys(val)) == 2
                    pd[key] = Unitful.Quantity(val.val, Unitful.uparse(val.unit))
                else
                    pd[key].val = Unitful.Quantity(val.val, Unitful.uparse(val.unit))
                    delete!(pd[key], :unit)
                end
            else
                pd[key] = uparse(val)
            end
        end
    end
    pd
end

function Measurements.measurement(pd::PropDict)
    for (key, val) in pd
        if val isa PropDict
            if val.val isa Measurements.Measurement 
                continue
            elseif haskey(val, :err) && haskey(val, :val)
                if length(keys(val)) == 2
                    pd[key] = measurement(val.val, val.err)
                else
                    pd[key].val = measurement(val.val, val.err)
                    delete!(pd[key], :err)
                end
            else
                pd[key] = measurement(val)
            end
        end
    end
    pd
end

# function tst(a::Real; kwargs...)
#     if haskey(kwargs, :write_units)
#         kwargs = pairs(NamedTuple(filter(k -> !(:write_units in k), kwargs)))
#         # new_kwargs = kwargs
#     end
#     kwargs
# end

function Unitful.ustrip(pd::PropDict)
    for (key, val) in pd
        if val isa PropDict
            if val.val isa Unitful.Quantity
                pd[key].unit = string(unit(val.val))
                if haskey(pd[key], :err)
                    pd[key].err = ustrip(val.err)
                end
                pd[key].val = ustrip(val.val)
            end
            pd[key] = ustrip(val)
        else
            if val isa Unitful.Quantity
                pd[key] = PropDict()
                pd[key].val = ustrip(val)
                pd[key].unit = string(unit(val))
            end
        end
    end
    pd
end

function mstrip(pd::PropDict)
    for (key, val) in pd
        if val isa PropDict
            if val.val isa Measurements.Measurement
                pd[key].err = uncertainty(val.val)
                pd[key].val = value(val.val)
            else
                pd[key] = mstrip(val)
            end
        else
            if val isa Unitful.Quantity
                if ustrip(val) isa Measurements.Measurement
                    pd[key] = PropDict()
                    pd[key].err = uncertainty(val)
                    pd[key].val = value(val)
                end
            elseif val isa Measurements.Measurement
                pd[key] = PropDict()
                pd[key].err = uncertainty(val)
                pd[key].val = value(val)
            end
        end
    end
    pd
end

# function PropDicts.writeprops(f, p::PropDict; write_units::Bool=true, write_errors::Bool=true, kwargs...)
#     if haskey(kwargs, :write_units)
#         kwargs = pairs(NamedTuple(filter(k -> !(:write_units in k), kwargs)))
#         p = ustrip(p)
#     end
#     if haskey(kwargs, :write_errors)
#         kwargs = pairs(NamedTuple(filter(k -> !(:write_errors in k), kwargs)))
#         p = mstrip(p)
#     end
#     writeprops(f, p; kwargs...)
# end

function PropDicts.writeprops(f, p::PropDict, write_units::Bool, write_errors::Bool; kwargs...)
    if write_units
        p = ustrip(p)
    end
    if write_errors
        p = mstrip(p)
    end
    writeprops(f, p; kwargs...)
end

# readlpropr, writelprops

pars_orig = readprops("legend-julia-dataflow/src/tst_pars.json")

pars_orig == mstrip(measurement(pars_orig))
pars_orig == ustrip(uparse(pars_orig))

pars = readprops("legend-julia-dataflow/src/tst_pars.json")

LegendDataManagement.recursive_uparse(pars)
measurement(pars)

mstrip(pars)
ustrip(pars)

writeprops("legend-julia-dataflow/src/tst_pars_out.json", pars, true, true; multiline=true)
pars_out = uparse(measurement(readprops("legend-julia-dataflow/src/tst_pars_out.json")))


a = """
{
"P00664A": {
        "n": 500,
        "a": {
            "val": 1.55,
            "err": 0.01,
            "unit": "μs"
        },
        "b": {
            "val": 15.5,
            "unit": "μs"
        }, 
        "c": {
            "val": 155,
            "err": 1
        }
    }
}
"""
JSON.parse(a)
