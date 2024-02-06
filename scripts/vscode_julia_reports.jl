begin
    struct Report
        objects::AbstractVector
    end

    Report() = Report(Any[])

    function Base.show(io::IO, r::Report)
        for x in r.objects
            show(io, x)
            println(io)
        end
    end

    function Base.show(io::IO, m::MIME"text/plain", r::Report)
        for x in r.objects
            show(io, m, x)
            println(io)
        end
    end

    function Base.show(io::IO, ::MIME"text/html", r::Report)
        for x in r.objects
            if showable(MIME("text/html"), x)
                show(io, MIME("text/html"), x)
            else
                show(io, MIME("text/plain"), x)
            end
            println(io)
        end
    end

    Base.show(io::IO, ::MIME"juliavscode/html", r::Report) = show(io, MIME("text/html"), r)
end


using Plots, Markdown

r = Report(
    [
        plot(rand(10), rand(10)),
        Markdown.parse("Plot caption with **important** text."),
        stephist(randn(10^5)),
        Markdown.parse("Another *plot* caption."),
    ]
)

#=
# For testing:
d = last(Base.Multimedia.displays)
display(d, MIME("juliavscode/html"), r)
=#

# display(r)
