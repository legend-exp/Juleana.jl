# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

# The item that `parallel` is processing in the current task, `nothing` outside of `parallel`
const CURRENT_ITEM = ScopedValue{Any}(nothing)

"""
    ProcessStepError <: Exception

The error thrown by [`@process_step`](@ref) when its block fails: the step name `name`, the
item of [`parallel`](@ref) that was processed (`nothing` outside of `parallel`) and the
[`root_exception`](@ref) `exception` of the failure. It prints as `"<name>: <exception>"`.
"""
struct ProcessStepError <: Exception
    name::String
    item::Any
    exception::Any
end

Base.show(io::IO, e::ProcessStepError) = print(io, e.name, ": ", e.exception)

"""
    @process_step name block

Run `block` as one named step of a processor and return its value. If `block` throws, log
`"<name> failed for <detector>: <error>"` as an `@error` and throw a
[`ProcessStepError`](@ref) with the [`root_exception`](@ref) of the failure. The detector is
that of the item [`parallel`](@ref) is processing; without one, the message has no
`for <detector>`.

`name` is a string, usually with interpolations; it is only evaluated when `block` fails.
When steps are nested, only the innermost failing step logs: an outer step passes the
`ProcessStepError` on unchanged. `block` has the variable scope of a `try` block: it can
assign variables of the enclosing function, and variables first assigned in `block` are
local to it.

# Examples
```julia
result_simple, report_simple = @process_step "\$e_type simple calibration" begin
    simple_calibration(e_uncal, th228_lines, left_window_sizes, right_window_sizes)
end
```
"""
macro process_step(name, block)
    err = gensym("err")
    return quote
        try
            $(esc(block))
        catch $err
            process_step_failed($err, $(esc(name)), $(string(__source__.file)), $(__source__.line))
        end
    end
end

function process_step_failed(e, name, file, line)
    e isa ProcessStepError && rethrow()
    item = CURRENT_ITEM[]
    step_error = ProcessStepError(string(name), item, root_exception(e))
    det = hasproperty(item, :detector) ? " for $(item.detector)" : ""
    @error "$(step_error.name) failed$det: $(truncate_error(step_error.exception))" _file = file _line = line
    throw(step_error)
end
