# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

using Juleana
using Test
using Markdown
using Logging
using TerminalLoggers

include(joinpath(@__DIR__, "../src/markdown_logging.jl"))

@testset "juleana" begin
    @testset "log underscores" begin
        message = escape_log_underscores("process_dsp_cal and e_cusp_ctc; `already_quoted`")
        @test message == "process\\_dsp\\_cal and e\\_cusp\\_ctc; `already_quoted`"
        @test !any(x -> x isa Markdown.Italic, Markdown.parse(message).content[1].content)
        @test escape_log_underscores("already\\_escaped") == "already\\_escaped"
        @test escape_log_underscores("``code_with_underscores`` and a_b") == "``code_with_underscores`` and a\\_b"

        output = IOBuffer()
        with_logger(UnderscoreSafeLogger(TerminalLogger(output))) do
            @info "process_dsp_cal and e_cusp_ctc; `already_quoted`"
        end
        @test occursin("process_dsp_cal and e_cusp_ctc; already_quoted", String(take!(output)))
    end
end
