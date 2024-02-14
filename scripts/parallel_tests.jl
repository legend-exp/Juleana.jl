using Distributed
@everywhere function test(i::Int)
    while true
        sleep(i)
        println("Hello from a task")
    end
    true
end
t = @async test()

istaskdone(t)
@async Base.throwto(t, InterruptException())
Base.throwto(t, InterruptException())

timedwait(test, 10)

@everywhere begin
    import Dates
    using Logging, LoggingExtras
    const date_format = "HH:MM:SS"

    function dagger_logger(logger)
        logger = MinLevelLogger(logger, Logging.Info)
        logger = TransformerLogger(logger) do log
            merge(log, (; message = "$(Dates.format(Dates.now(), date_format)) ($(myid())) $(log.message)"))
        end
        return logger
    end
# set the global logger
global_logger(ConsoleLogger(stderr) |> dagger_logger)
end





using Distributed
@everywhere begin 
    using LoggingExtras
    logger = FormatLogger() do io, args
        println(io, "Worker $(myid()):", "[", args.level, "] ", args.message)
    end
end
addprocs(2)
pmap(1:10) do i
    println(i)
    with_logger(logger) do
        @info "Hello from task $i"
        sleep(i)
        @info "Hello again from task $i"
    end
end