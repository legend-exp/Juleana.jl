#!/bin/bash
# =============================================================================
# Juleana SLURM Job Setup Script
# 
# This script interactively creates a SLURM batch script for running Juleana
# data processing jobs. It guides you through all necessary configuration
# options with explanations.
#
# Usage: ./setup_batch_job.sh
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Juleana root is one level up from setup/
JULEANA_ROOT="$(dirname "$SCRIPT_DIR")"

echo -e "${CYAN}"
echo "============================================================================="
echo "                    JULEANA SLURM JOB SETUP"
echo "============================================================================="
echo -e "${NC}"
echo "This script will help you create a SLURM batch script for Juleana."
echo "Press ENTER to accept default values shown in [brackets]."
echo ""

# =============================================================================
# SECTION 1: PATHS CONFIGURATION
# =============================================================================
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}                         PATHS CONFIGURATION${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Job name
echo -e "${BLUE}Job Name${NC}"
echo "  A short identifier for your job (visible in squeue)"
read -p "  Job name [legend-juleana]: " JOB_NAME
JOB_NAME=${JOB_NAME:-legend-juleana}
echo ""

# Julia Project Path
echo -e "${BLUE}Julia Project Path${NC}"
echo "  Path to the Juleana.jl directory containing Project.toml"
echo "  This is where 'julia --project=' will point to"
DEFAULT_JULIA_PROJECT="$JULEANA_ROOT"
read -p "  Julia project [$DEFAULT_JULIA_PROJECT]: " JULIA_PROJECT
JULIA_PROJECT=${JULIA_PROJECT:-$DEFAULT_JULIA_PROJECT}
echo ""

# Processing Config
echo -e "${BLUE}Processing Config${NC}"
echo "  Path to the processing_config.json file"
echo "  This defines which processors to run and their settings"
DEFAULT_PROCESSING_CONFIG="$JULEANA_ROOT/config/processing_config.json"
read -p "  Processing config [$DEFAULT_PROCESSING_CONFIG]: " PROCESSING_CONFIG
PROCESSING_CONFIG=${PROCESSING_CONFIG:-$DEFAULT_PROCESSING_CONFIG}
echo ""

# LEGEND Data Config
echo -e "${BLUE}LEGEND Data Config${NC}"
echo "  Path to your data configuration (e.g. config.json)"
echo "  This defines paths to metadata, tier data, and parameters"
echo "  Example: /path/to/jl-v0.5.0/config.json"
read -p "  LEGEND_DATA_CONFIG: " LEGEND_DATA_CONFIG

# Validate and extract log path from LEGEND_DATA_CONFIG
if [ -z "$LEGEND_DATA_CONFIG" ]; then
    echo -e "${RED}  Error: LEGEND_DATA_CONFIG is required!${NC}"
    exit 1
fi

if [ ! -f "$LEGEND_DATA_CONFIG" ]; then
    echo -e "${RED}  Warning: File not found: $LEGEND_DATA_CONFIG${NC}"
    echo "  Continuing anyway, but make sure the path is correct."
fi

# Try to extract jllog path from config
LOG_BASE_PATH=""
if [ -f "$LEGEND_DATA_CONFIG" ]; then
    # Get the directory containing the config file (this is $_)
    CONFIG_DIR="$(dirname "$LEGEND_DATA_CONFIG")"
    
    # Try to extract tier/jllog path and resolve $_
    JLLOG_PATH=$(grep -o '"tier/jllog"[[:space:]]*:[[:space:]]*"[^"]*"' "$LEGEND_DATA_CONFIG" 2>/dev/null | sed 's/.*"\([^"]*\)"/\1/' | sed "s|\\\$_|$CONFIG_DIR|g")
    
    if [ -n "$JLLOG_PATH" ]; then
        # Create the directory if it doesn't exist
        LOG_BASE_PATH="$JLLOG_PATH"
        echo -e "${GREEN}  ✓ Found jllog path: $LOG_BASE_PATH${NC}"
    fi
fi

# If we couldn't extract, ask for it
if [ -z "$LOG_BASE_PATH" ]; then
    echo ""
    echo -e "${BLUE}SLURM Log Directory${NC}"
    echo "  Could not auto-detect jllog path from config."
    echo "  Where should SLURM output/error logs be stored?"
    DEFAULT_LOG_PATH="$JULEANA_ROOT/logs"
    read -p "  Log directory [$DEFAULT_LOG_PATH]: " LOG_BASE_PATH
    LOG_BASE_PATH=${LOG_BASE_PATH:-$DEFAULT_LOG_PATH}
fi

# Create log directory if needed
mkdir -p "$LOG_BASE_PATH" 2>/dev/null || true

echo ""

# =============================================================================
# SECTION 2: SLURM RESOURCE CONFIGURATION
# =============================================================================
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}                      SLURM RESOURCE CONFIGURATION${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Resources are calculated as: TOTAL_CPUs = TASKS × CPUs_PER_TASK"
echo "  Memory is: TOTAL_RAM = TOTAL_CPUs × MEM_PER_CPU"
echo ""

# Number of nodes
echo -e "${BLUE}Number of Nodes${NC}"
echo "  How many compute nodes to use"
read -p "  Nodes [1]: " NODES
NODES=${NODES:-1}
echo ""

# Tasks per node (= number of Julia workers)
echo -e "${BLUE}Tasks per Node (= Julia Workers)${NC}"
echo "  Each task becomes one Julia worker process"
echo "  More workers = more parallel file processing"
echo -e "  ${CYAN}Note: This should match 'local.n' in processing_config.json${NC}"
read -p "  Tasks per node [64]: " NTASKS
NTASKS=${NTASKS:-64}
echo ""

# CPUs per task (= Julia threads per worker)
echo -e "${BLUE}CPUs per Task (= Julia Threads per Worker)${NC}"
echo "  Each worker gets this many CPU cores/threads"
echo "  Set JULIA_NUM_THREADS to match this value"
echo "  Recommended: 2 for most workloads"
read -p "  CPUs per task [2]: " CPUS_PER_TASK
CPUS_PER_TASK=${CPUS_PER_TASK:-2}
echo ""

# Memory per CPU
echo -e "${BLUE}Memory per CPU${NC}"
echo "  RAM allocated per CPU core (in GB)"
echo "  Maximum allowed on most clusters: 8GB"
echo "  Total RAM = Tasks × CPUs × MemPerCPU"
TOTAL_CPUS=$((NTASKS * CPUS_PER_TASK))
echo -e "  ${CYAN}Your config: $NTASKS tasks × $CPUS_PER_TASK CPUs = $TOTAL_CPUS total CPUs${NC}"
read -p "  Memory per CPU in GB [8]: " MEM_PER_CPU
MEM_PER_CPU=${MEM_PER_CPU:-8}
TOTAL_MEM=$((TOTAL_CPUS * MEM_PER_CPU))
echo -e "  ${CYAN}Total RAM: $TOTAL_CPUS CPUs × ${MEM_PER_CPU}GB = ${TOTAL_MEM}GB${NC}"
echo ""

# Time limit
echo -e "${BLUE}Time Limit${NC}"
echo "  Maximum job runtime (format: HH:MM:SS or D-HH:MM:SS)"
echo "  Job will be killed if it exceeds this time"
read -p "  Time limit [12:00:00]: " TIME_LIMIT
TIME_LIMIT=${TIME_LIMIT:-12:00:00}
echo ""

# =============================================================================
# SECTION 3: JULIA ENVIRONMENT CONFIGURATION
# =============================================================================
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}                    JULIA ENVIRONMENT CONFIGURATION${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Julia threads (should match CPUs per task)
echo -e "${BLUE}Julia Threads${NC}"
echo "  Number of threads per Julia worker (should match CPUs per task)"
echo "  This sets JULIA_NUM_THREADS environment variable"
read -p "  Julia threads [$CPUS_PER_TASK]: " JULIA_THREADS
JULIA_THREADS=${JULIA_THREADS:-$CPUS_PER_TASK}
echo ""

# Worker timeout
echo -e "${BLUE}Worker Timeout${NC}"
echo "  Timeout in seconds for Julia worker communication"
echo "  Increase if you see worker timeout errors"
read -p "  Worker timeout in seconds [240]: " WORKER_TIMEOUT
WORKER_TIMEOUT=${WORKER_TIMEOUT:-240}
echo ""

# Debug mode
echo -e "${BLUE}Debug Mode${NC}"
echo "  Comma-separated list of modules to enable debug output"
echo "  Example: Main,LegendSpecFits,LegendEventAnalysis"
echo "  Leave empty for no debug output"
read -p "  Debug modules [Main,LegendSpecFits]: " DEBUG_MODULES
DEBUG_MODULES=${DEBUG_MODULES:-Main,LegendSpecFits}
echo ""

# =============================================================================
# SECTION 4: OUTPUT FILE NAME
# =============================================================================
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}                         OUTPUT CONFIGURATION${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Output script name
echo -e "${BLUE}Output Script Name${NC}"
echo "  Name of the generated batch script"
echo "  Will be created in: $JULEANA_ROOT/"
DEFAULT_SCRIPT_NAME="run_${JOB_NAME}.sh"
read -p "  Script name [$DEFAULT_SCRIPT_NAME]: " SCRIPT_NAME
SCRIPT_NAME=${SCRIPT_NAME:-$DEFAULT_SCRIPT_NAME}
OUTPUT_SCRIPT="$JULEANA_ROOT/$SCRIPT_NAME"
echo ""

# =============================================================================
# SUMMARY AND CONFIRMATION
# =============================================================================
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}                              SUMMARY${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${CYAN}Paths:${NC}"
echo "  Job Name:           $JOB_NAME"
echo "  Julia Project:      $JULIA_PROJECT"
echo "  Processing Config:  $PROCESSING_CONFIG"
echo "  Data Config:        $LEGEND_DATA_CONFIG"
echo "  Log Directory:      $LOG_BASE_PATH"
echo ""
echo -e "${CYAN}SLURM Resources:${NC}"
echo "  Nodes:              $NODES"
echo "  Tasks (Workers):    $NTASKS"
echo "  CPUs per Task:      $CPUS_PER_TASK"
echo "  Total CPUs:         $TOTAL_CPUS"
echo "  Memory per CPU:     ${MEM_PER_CPU}GB"
echo "  Total Memory:       ${TOTAL_MEM}GB"
echo "  Time Limit:         $TIME_LIMIT"
echo ""
echo -e "${CYAN}Julia Settings:${NC}"
echo "  Julia Threads:      $JULIA_THREADS"
echo "  Worker Timeout:     ${WORKER_TIMEOUT}s"
echo "  Debug Modules:      ${DEBUG_MODULES:-none}"
echo ""
echo -e "${CYAN}Output:${NC}"
echo "  Script:             $OUTPUT_SCRIPT"
echo ""

read -p "Generate this script? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${RED}Aborted.${NC}"
    exit 1
fi

# =============================================================================
# GENERATE THE BATCH SCRIPT
# =============================================================================

cat > "$OUTPUT_SCRIPT" << SCRIPT_EOF
#!/bin/bash
# =============================================================================
# Juleana SLURM Batch Script
# Generated by setup_batch_job.sh on $(date)
# =============================================================================

#SBATCH --job-name=$JOB_NAME
#SBATCH --nodes=$NODES
#SBATCH --ntasks-per-node=$NTASKS
#SBATCH --cpus-per-task=$CPUS_PER_TASK
#SBATCH --mem-per-cpu=${MEM_PER_CPU}G
#SBATCH --time=$TIME_LIMIT
#SBATCH --output=$LOG_BASE_PATH/slurm-%j.out
#SBATCH --error=$LOG_BASE_PATH/slurm-%j.err

# Exit on error
set -euo pipefail

# =============================================================================
# Environment Configuration
# =============================================================================

# LEGEND data configuration path
export LEGEND_DATA_CONFIG="$LEGEND_DATA_CONFIG"

# Julia worker communication timeout (seconds)
export JULIA_WORKER_TIMEOUT=$WORKER_TIMEOUT

# Disable multi-threading in BLAS (Julia handles parallelism)
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1

# Number of Julia threads per worker
export JULIA_NUM_THREADS=$JULIA_THREADS

# Debug output for specified modules
export JULIA_DEBUG="$DEBUG_MODULES"

# Graphics backend (non-interactive for cluster)
export GKSwstype=100

# =============================================================================
# Paths
# =============================================================================

JULIA_PROJECT="$JULIA_PROJECT"
PROCESSING_CONFIG="$PROCESSING_CONFIG"

# =============================================================================
# Run Juleana
# =============================================================================

julia --project="\$JULIA_PROJECT" "\$JULIA_PROJECT/main.jl" -c "\$PROCESSING_CONFIG"
SCRIPT_EOF

chmod +x "$OUTPUT_SCRIPT"

# =============================================================================
# UPDATE PROCESSING CONFIG WITH WORKER COUNT
# =============================================================================

TOTAL_WORKERS=$((NODES * NTASKS))

if [[ -f "$PROCESSING_CONFIG" ]]; then
    # Update the local.n value in processing_config.json to match total workers
    if command -v python3 &> /dev/null; then
        python3 -c "
import json
import sys

config_path = '$PROCESSING_CONFIG'
workers = $TOTAL_WORKERS

try:
    with open(config_path, 'r') as f:
        config = json.load(f)
    
    if 'config' in config and 'runmode_settings' in config['config'] and 'local' in config['config']['runmode_settings']:
        old_n = config['config']['runmode_settings']['local'].get('n', 'not set')
        config['config']['runmode_settings']['local']['n'] = workers
        
        with open(config_path, 'w') as f:
            json.dump(config, f, indent=4)
        
        print(f'Updated local.n: {old_n} -> {workers}')
    else:
        print('Warning: Could not find config.runmode_settings.local in processing_config.json')
        sys.exit(1)
except Exception as e:
    print(f'Error updating processing_config.json: {e}')
    sys.exit(1)
"
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}Updated processing_config.json: local.n = $TOTAL_WORKERS${NC}"
        else
            echo -e "${YELLOW}Warning: Could not update processing_config.json automatically${NC}"
            echo -e "${YELLOW}Please manually set local.n to $TOTAL_WORKERS${NC}"
        fi
    else
        echo -e "${YELLOW}Warning: python3 not available, cannot update processing_config.json${NC}"
        echo -e "${YELLOW}Please manually set local.n to $TOTAL_WORKERS in $PROCESSING_CONFIG${NC}"
    fi
fi

echo ""
echo -e "${GREEN}=============================================================================${NC}"
echo -e "${GREEN}                         SCRIPT GENERATED SUCCESSFULLY${NC}"
echo -e "${GREEN}=============================================================================${NC}"
echo ""
echo "  Script created: $OUTPUT_SCRIPT"
echo "  Workers:        $TOTAL_WORKERS (Nodes: $NODES × Tasks: $NTASKS)"
echo ""
echo "  To submit the job:"
echo -e "    ${CYAN}sbatch $OUTPUT_SCRIPT${NC}"
echo ""
echo "  To check cluster resources first:"
echo -e "    ${CYAN}$SCRIPT_DIR/check_cluster_resources.sh${NC}"
echo ""
echo "  To monitor your job:"
echo -e "    ${CYAN}squeue -u \$USER${NC}"
echo ""
