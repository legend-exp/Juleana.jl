""" 
    sbatch(data::LegendData, processing_config::PropDict, period::DataPeriodLike, run::DataRunLike)
    sbatch(data::LegendData, processing_config::PropDict, part::DataPartitionLike)
SLURM job submission utilities to submit a job to the SLURM scheduler to process a single run.
"""
function sbatch(data::LegendData, processing_config::PropDict, period::DataPeriodLike, run::DataRunLike)
    period, run = DataPeriod(period), DataRun(run)
    
    # get env variables for slurm processing
    ntasks = "--ntasks=$(parse(Int, ENV["SLURM_NTASKS"]))"
    cpus_per_task = "--cpus-per-task=$(parse(Int, ENV["SLURM_CPUS_PER_TASK"]))"
    mem_per_cpu = "--mem-per-cpu=$(ENV["SLURM_MEM_PER_CPU"])"
    task_timeout = "--time=$(Dates.Time(ENV["SLURM_TASK_TIMEOUT"]))"

    # log path
    log_path = mkpath(joinpath(processing_config.processing.log_path, "$(period)-$(run)"))
    jobname = "--job-name=juleana-$(period)-$(run)"
    output = "--output=$(mkpath(log_path))/%x_%j.out"

    # julia path
    julia_path = joinpath(Sys.BINDIR, "julia")
    julia_project = "--project=$(dirname(Pkg.project().path))"
    julia_script = joinpath(dirname(@__DIR__), "main.jl")
    dataflow_config = "--config $(ifelse(Base.Filesystem.isabspath(processing_config.parsed_args.config), processing_config.parsed_args.config, joinpath(dirname(@__DIR__), processing_config.parsed_args.config)))"
    dataflow_args = "--periods $(period.no) --runs $(run.no) --only_runs --ignore_config --log_path $(log_path)"
    dataflow_args *= " $(ifelse(processing_config.parsed_args.reprocess, " --reprocess", ""))"
    dataflow_args *= " $(ifelse(processing_config.parsed_args.analysis_runs_only, " --analysis_runs_only", ""))"

    # get sbatch command
    sbatch_cmd = `sbatch $(ntasks) $(cpus_per_task) $(mem_per_cpu) $(task_timeout) $(jobname) $(output) --wrap="$(julia_path) $(julia_project) $(julia_script) $(dataflow_config) $(dataflow_args)"`
    @debug "Submit job: $sbatch_cmd"
    Base.run(sbatch_cmd; wait=false)
end

function sbatch(data::LegendData, processing_config::PropDict, part::DataPartitionLike)
    part = DataPartition(part)

    # get env variables for slurm processing
    ntasks = "--ntasks=$(parse(Int, ENV["SLURM_NTASKS"]))"
    cpus_per_task = "--cpus-per-task=$(parse(Int, ENV["SLURM_CPUS_PER_TASK"]))"
    mem_per_cpu = "--mem-per-cpu=$(ENV["SLURM_MEM_PER_CPU"])"
    task_timeout = "--time=$(Dates.Time(ENV["SLURM_TASK_TIMEOUT"]))"

    # get dependency tree for partition
    dependencies = get_slurm_partition_dependencies(data, part)

    # log path
    log_path = mkpath(joinpath(processing_config.processing.log_path, "$(part)"))
    jobname = "--job-name=juleana-$(part)"
    output = "--output=$(mkpath(log_path))/%x_%j.out"

    # julia path
    julia_path = joinpath(Sys.BINDIR, "julia")
    julia_project = "--project=$(dirname(Pkg.project().path))"
    julia_script = joinpath(dirname(@__DIR__), "main.jl")
    dataflow_config = "--config $(ifelse(Base.Filesystem.isabspath(processing_config.parsed_args.config), processing_config.parsed_args.config, joinpath(dirname(@__DIR__), processing_config.parsed_args.config)))"
    dataflow_args = "--periods $(period.no) --runs $(run.no) --only_partitions --ignore_config --log_path $(log_path)"
    dataflow_args *= " $(ifelse(processing_config.parsed_args.reprocess, " --reprocess", ""))"
    dataflow_args *= " $(ifelse(processing_config.parsed_args.analysis_runs_only, " --analysis_runs_only", ""))"

    # get sbatch command
    sbatch_cmd = `sbatch $(ntasks) $(cpus_per_task) $(mem_per_cpu) $(task_timeout) $(dependencies) $(jobname) $(output) --wrap="$(julia_path) $(julia_project) $(julia_script) $(dataflow_config) $(dataflow_args)"`
    @debug "Submit job: $sbatch_cmd"
    Base.run(sbatch_cmd; wait=false)
end


function get_slurm_job_ids_by_name(name::String)
    # Run the squeue command and get the output as a string
    squeue_output = read(`squeue -h -o "%.18i %.100j"`, String)

    # Split the output into lines
    lines = split(squeue_output, '\n')

    # Filter the lines that contain the job name and return the job IDs
    return [split(line)[1] for line in lines if occursin(name, line)]
end

function get_slurm_partition_dependencies(data::LegendData, part::DataPartitionLike; dependency::String="afterany")
    part = DataPartition(part)
    # get partinfo
    partinfo = partitioninfo(data)[part]
    # get all slurm job ids for the given partition
    job_ids = reduce(vcat, [get_slurm_job_ids_by_name("juleana-$(run.period)-$(run.run)") for run in partinfo])
    if isempty(job_ids)
        return ""
    else
        return "--dependency=$dependency:" * join(job_ids, ":")
    end
end

function get_slurm_flags(processing_config::PropDict; set_env::Bool=false)
    # get SLURM config settings
    if isempty(processing_config.config.slurm_settings)
        ``
    else
        Cmd(string.(processing_config.config.slurm_settings))
    end
end

function get_julia_flags(processing_config::PropDict)
    # get Julia config settings
    if isempty(processing_config.config.julia_settings)
        ``
    else
        Cmd(string.(processing_config.config.julia_settings))
    end
end