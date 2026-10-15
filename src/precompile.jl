# This file is a part of Juleana.jl, licensed under the MIT License (MIT).

# Compile the terminal interface when the package is precompiled, so that its first frame
# appears without compiling the drawing code: draw the startup screen, every page and the
# key help of an interface without a session into a test buffer. Nothing reads data or
# writes files, and no task outlives the workload.
@setup_workload begin
    @compile_workload begin
        ctrl = DataflowController(Dict{String,Any}("config" => nothing); loader = nothing)
        m = JuleanaTUI(ctrl; splash_seconds = 0.0)
        # ends the task that runs the commands of the interface
        close(m.commands)
        m.snap = snapshot(ctrl)
        tb = Tachikoma.TestBackend(140, 40)
        frame() = Tachikoma.view(m, Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 140, 40),
            Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[]))
        m.splash = true
        frame()
        m.splash = false
        # pages are set directly: key events would start the background reads of the pages
        for page in eachindex(TUI_PAGES)
            m.page = page
            frame()
        end
        m.help = true
        frame()
    end
end
