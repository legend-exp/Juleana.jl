#!/bin/bash
# =============================================================================
# Check Cluster Resources - Shows available CPUs, RAM, and GPUs per node
# Works on any SLURM cluster
# Usage: ./check_cluster_resources.sh
# =============================================================================

set -o pipefail

echo "============================================================================="
echo "                    CLUSTER RESOURCE AVAILABILITY"
echo "                    $(date)"
echo "============================================================================="
echo ""

# Header
printf "%-12s %8s %8s %8s %12s %12s %10s %6s %s\n" \
    "NODE" "CPUs" "CPUs" "CPUs" "RAM" "RAM" "STATE" "JOBS" ""
printf "%-12s %8s %8s %8s %12s %12s %10s %6s %s\n" \
    "" "Total" "Alloc" "Free" "Total" "Free" "" "" ""
echo "-----------------------------------------------------------------------------"

# Get node information using sinfo and scontrol
# Format: NodeName AllocCPUs/IdleCPUs/OtherCPUs/TotalCPUs FreeMem(MB) TotalMem(MB) State
sinfo -N -h -o "%N %C %e %m %T" 2>/dev/null | sort -u | while read node cpuinfo freemem totalmem state; do
    # Skip if empty
    [ -z "$node" ] && continue
    
    # Parse CPU info (format: allocated/idle/other/total)
    total_cpus=$(echo "$cpuinfo" | cut -d'/' -f4)
    alloc_cpus=$(echo "$cpuinfo" | cut -d'/' -f1)
    idle_cpus=$(echo "$cpuinfo" | cut -d'/' -f2)
    
    # Handle missing values
    [ -z "$total_cpus" ] && total_cpus=0
    [ -z "$alloc_cpus" ] && alloc_cpus=0
    [ -z "$idle_cpus" ] && idle_cpus=0
    [ -z "$freemem" ] && freemem=0
    [ -z "$totalmem" ] && totalmem=0
    
    # Convert memory to GB (input is in MB)
    total_mem_gb=$((totalmem / 1024))
    free_mem_gb=$((freemem / 1024))
    
    # Get number of running jobs on this node
    running_jobs=$(squeue -w "$node" -h -t R 2>/dev/null | wc -l)
    
    # Calculate availability percentage (dynamic for any cluster)
    if [ "$total_cpus" -gt 0 ] && [ "$total_mem_gb" -gt 0 ]; then
        cpu_pct=$((idle_cpus * 100 / total_cpus))
        mem_pct=$((free_mem_gb * 100 / total_mem_gb))
    else
        cpu_pct=0
        mem_pct=0
    fi
    
    # Status indicator based on percentage availability
    if [ "$cpu_pct" -gt 50 ] && [ "$mem_pct" -gt 50 ]; then
        status="🟢"  # >50% free
    elif [ "$cpu_pct" -gt 25 ] && [ "$mem_pct" -gt 25 ]; then
        status="🟡"  # >25% free
    elif [ "$idle_cpus" -gt 0 ]; then
        status="🟠"  # Some CPUs free
    else
        status="🔴"  # Fully allocated
    fi
    
    printf "%-12s %8s %8s %8s %10sGB %10sGB %10s %6s %s\n" \
        "$node" "$total_cpus" "$alloc_cpus" "$idle_cpus" \
        "$total_mem_gb" "$free_mem_gb" "$state" "$running_jobs" "$status"
done

echo ""
echo "============================================================================="
echo "                           SUMMARY"
echo "============================================================================="

# Total cluster summary
echo ""
echo "Cluster Totals:"
sinfo -h -o "%C" 2>/dev/null | head -1 | while read cpuinfo; do
    alloc=$(echo "$cpuinfo" | cut -d'/' -f1)
    idle=$(echo "$cpuinfo" | cut -d'/' -f2)
    other=$(echo "$cpuinfo" | cut -d'/' -f3)
    total=$(echo "$cpuinfo" | cut -d'/' -f4)
    echo "  CPUs:  $alloc allocated / $idle idle / $total total"
    
    # Calculate utilization
    if [ "$total" -gt 0 ]; then
        util=$((alloc * 100 / total))
        echo "  Utilization: ${util}%"
    fi
done

# Jobs in queue
echo ""
echo "Queue Status:"
echo "  Running jobs:  $(squeue -t R -h 2>/dev/null | wc -l)"
echo "  Pending jobs:  $(squeue -t PD -h 2>/dev/null | wc -l)"
echo "  Your running:  $(squeue -u $USER -t R -h 2>/dev/null | wc -l)"
echo "  Your pending:  $(squeue -u $USER -t PD -h 2>/dev/null | wc -l)"

echo ""
echo "============================================================================="
echo "                     BEST NODES FOR IMMEDIATE START"
echo "============================================================================="
echo ""

# Find nodes with free resources, sorted by idle CPUs
best_nodes=$(sinfo -N -h -o "%N %C %e %T" 2>/dev/null | sort -u | while read node cpuinfo freemem state; do
    [ -z "$node" ] && continue
    idle_cpus=$(echo "$cpuinfo" | cut -d'/' -f2)
    free_mem_gb=$((freemem / 1024))
    
    # Only show nodes with available resources
    if [ "$idle_cpus" -gt 0 ] 2>/dev/null; then
        echo "$idle_cpus $free_mem_gb $node $state"
    fi
done | sort -rn | head -5)

if [ -z "$best_nodes" ]; then
    echo "   NO FREE CPUs AVAILABLE ON ANY NODE!"
    echo ""
    echo "  All nodes are fully allocated. Your job will be queued."
    echo "  Estimated wait time depends on running job durations."
    echo ""
    echo "  Options:"
    echo "    1. Submit job anyway - it will start when resources free up"
    echo "    2. Request fewer resources to fit into gaps"
    echo "    3. Check back later: ./check_cluster_resources.sh"
    echo ""
    
    # Show nodes with most free RAM (might accept jobs with few CPUs)
    echo "  Nodes with most free RAM (for small CPU jobs):"
    sinfo -N -h -o "%N %e %T" 2>/dev/null | sort -u | while read node freemem state; do
        [ -z "$node" ] && continue
        free_mem_gb=$((freemem / 1024))
        echo "    $node: ${free_mem_gb}GB RAM free ($state)"
    done | sort -t':' -k2 -rn | head -3
else
    echo "  Nodes with free resources (sorted by free CPUs):"
    echo ""
    printf "  %-12s %10s %12s %s\n" "NODE" "Free CPUs" "Free RAM" "STATE"
    echo "  -----------------------------------------------"
    echo "$best_nodes" | while read idle_cpus free_mem_gb node state; do
        printf "  %-12s %10s %10sGB %s\n" "$node" "$idle_cpus" "$free_mem_gb" "$state"
    done
    
    # Get best node info for suggestion
    best_node=$(echo "$best_nodes" | head -1 | awk '{print $3}')
    best_cpus=$(echo "$best_nodes" | head -1 | awk '{print $1}')
    best_ram=$(echo "$best_nodes" | head -1 | awk '{print $2}')
    
    echo ""
    echo "  Suggested SBATCH for immediate start on $best_node:"
    echo "    #SBATCH --nodelist=$best_node"
    echo "    #SBATCH --ntasks-per-node=$best_cpus"
    echo "    #SBATCH --mem=${best_ram}G"
fi

echo ""
echo "============================================================================="
echo "                        PARTITION INFO"
echo "============================================================================="
echo ""
printf "%-15s %6s %12s %6s %8s %12s\n" "PARTITION" "AVAIL" "TIMELIMIT" "NODES" "CPUS" "MEMORY/NODE"
echo "-----------------------------------------------------------------------"
sinfo -h -o "%P %a %l %D %c %m" 2>/dev/null | while read part avail timelimit nodes cpus mem; do
    mem_gb=$((mem / 1024))
    printf "%-15s %6s %12s %6s %8s %10sGB\n" "$part" "$avail" "$timelimit" "$nodes" "$cpus" "$mem_gb"
done

echo ""
echo "============================================================================="
echo "                         YOUR PENDING JOBS"
echo "============================================================================="
echo ""
pending_count=$(squeue -u $USER -t PD -h 2>/dev/null | wc -l)
if [ "$pending_count" -eq 0 ]; then
    echo "  No pending jobs."
else
    printf "  %-12s %-25s %-8s %-6s %-10s %s\n" "JOBID" "NAME" "NODES" "CPUS" "MEM" "REASON"
    echo "  ---------------------------------------------------------------------------"
    squeue -u $USER -t PD -o "%12i %25j %8D %6c %10m %R" --noheader 2>/dev/null | sed 's/^/  /'
fi

echo ""
echo "============================================================================="
echo "                      YOUR LIMITS & ASSOCIATIONS"
echo "============================================================================="
echo ""

# Get user's association and limits from sacctmgr
echo "  User: $USER"

# Try to get QOS limits
qos_info=$(sacctmgr show qos -n -P 2>/dev/null | head -5)
user_assoc=$(sacctmgr show assoc user=$USER -n -P format=Account,Partition,QOS,MaxJobs,MaxSubmit,MaxNodes,MaxCPUs,MaxMem 2>/dev/null | head -1)

if [ -n "$user_assoc" ]; then
    echo ""
    echo "  Your Association:"
    account=$(echo "$user_assoc" | cut -d'|' -f1)
    partition=$(echo "$user_assoc" | cut -d'|' -f2)
    qos=$(echo "$user_assoc" | cut -d'|' -f3)
    maxjobs=$(echo "$user_assoc" | cut -d'|' -f4)
    maxsubmit=$(echo "$user_assoc" | cut -d'|' -f5)
    maxnodes=$(echo "$user_assoc" | cut -d'|' -f6)
    maxcpus=$(echo "$user_assoc" | cut -d'|' -f7)
    maxmem=$(echo "$user_assoc" | cut -d'|' -f8)
    
    [ -n "$account" ] && echo "    Account:     $account"
    [ -n "$partition" ] && echo "    Partition:   $partition"
    [ -n "$qos" ] && echo "    QOS:         $qos"
    [ -n "$maxjobs" ] && [ "$maxjobs" != "" ] && echo "    Max Jobs:    $maxjobs"
    [ -n "$maxsubmit" ] && [ "$maxsubmit" != "" ] && echo "    Max Submit:  $maxsubmit"
    [ -n "$maxnodes" ] && [ "$maxnodes" != "" ] && echo "    Max Nodes:   $maxnodes"
    [ -n "$maxcpus" ] && [ "$maxcpus" != "" ] && echo "    Max CPUs:    $maxcpus"
    [ -n "$maxmem" ] && [ "$maxmem" != "" ] && echo "    Max Memory:  $maxmem"
fi

# Get partition limits (often the effective limit for users)
echo ""
echo "  Partition Limits (max per job):"
sinfo -h -o "%P %c %m %l" 2>/dev/null | while read part cpus mem timelimit; do
    # Remove trailing asterisk from default partition
    part_clean=$(echo "$part" | tr -d '*')
    mem_gb=$((mem / 1024))
    echo "    $part_clean: Max $cpus CPUs, ${mem_gb}GB RAM, Time: $timelimit"
done

# Show current usage
echo ""
echo "  Your Current Usage:"
running_jobs=$(squeue -u $USER -t R -h 2>/dev/null | wc -l)
pending_jobs=$(squeue -u $USER -t PD -h 2>/dev/null | wc -l)
total_cpus_used=$(squeue -u $USER -t R -h -o "%c" 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
total_nodes_used=$(squeue -u $USER -t R -h -o "%D" 2>/dev/null | awk '{sum+=$1} END {print sum+0}')

echo "    Running jobs: $running_jobs"
echo "    Pending jobs: $pending_jobs"
echo "    CPUs in use:  $total_cpus_used"
echo "    Nodes in use: $total_nodes_used"

# Try to get GrpTRES limits from QOS
echo ""
echo "  QOS Limits (if configured):"
sacctmgr show qos format=Name,MaxTRESPerUser,MaxJobsPerUser,MaxSubmitPerUser -n 2>/dev/null | grep -v "^$" | while read line; do
    qos_name=$(echo "$line" | awk '{print $1}')
    max_tres=$(echo "$line" | awk '{print $2}')
    max_jobs=$(echo "$line" | awk '{print $3}')
    max_submit=$(echo "$line" | awk '{print $4}')
    
    if [ -n "$max_tres" ] || [ -n "$max_jobs" ] || [ -n "$max_submit" ]; then
        echo "    QOS '$qos_name':"
        [ -n "$max_tres" ] && [ "$max_tres" != "" ] && echo "      MaxTRES/User: $max_tres"
        [ -n "$max_jobs" ] && [ "$max_jobs" != "" ] && echo "      MaxJobs/User: $max_jobs"
        [ -n "$max_submit" ] && [ "$max_submit" != "" ] && echo "      MaxSubmit/User: $max_submit"
    fi
done 2>/dev/null || echo "    (No QOS limits configured or accessible)"

echo ""
echo "============================================================================="
echo "Legend: 🟢 >50% free | 🟡 >25% free | 🟠 >0 CPUs | 🔴 Full"
echo "============================================================================="
