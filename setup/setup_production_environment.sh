#!/bin/bash
# =============================================================================
# Juleana Production Environment Setup Script
# 
# This script interactively creates a new production environment for Juleana
# data processing. It sets up the directory structure, config files, and
# symlinks for raw data access.
#
# Usage: ./setup_production_environment.sh
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
# Default production base is where Juleana.jl is located
DEFAULT_PRODUCTION_BASE="$(dirname "$JULEANA_ROOT")"

echo -e "${CYAN}"
echo "============================================================================="
echo "              JULEANA PRODUCTION ENVIRONMENT SETUP"
echo "============================================================================="
echo -e "${NC}"
echo "This script will help you create a new production environment for Juleana."
echo "Press ENTER to accept default values shown in [brackets]."
echo ""

# =============================================================================
# SECTION 1: PRODUCTION NAME AND PATH
# =============================================================================
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}                      PRODUCTION CONFIGURATION${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Production name
echo -e "${BLUE}Production Name${NC}"
echo "  A unique identifier for this production (e.g., jl-v0.5.0)"
echo "  Must be a single string with no spaces"
while true; do
    read -p "  Production name: " PRODUCTION_NAME
    if [[ -z "$PRODUCTION_NAME" ]]; then
        echo -e "${RED}  Error: Production name is required!${NC}"
    elif [[ "$PRODUCTION_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        break
    else
        echo -e "${RED}  Error: Invalid name. Use only letters, numbers, dots, dashes, underscores.${NC}"
    fi
done
echo ""

# Production base path
echo -e "${BLUE}Production Base Path${NC}"
echo "  The directory where production folders will be created"
echo "  The production folder will be: <base>/$PRODUCTION_NAME/"
read -p "  Base path [$DEFAULT_PRODUCTION_BASE]: " PRODUCTION_BASE
PRODUCTION_BASE=${PRODUCTION_BASE:-$DEFAULT_PRODUCTION_BASE}

# Remove trailing slash if present
PRODUCTION_BASE="${PRODUCTION_BASE%/}"

PRODUCTION_PATH="$PRODUCTION_BASE/$PRODUCTION_NAME"
echo ""

# Check if production already exists
if [ -d "$PRODUCTION_PATH" ]; then
    echo -e "${YELLOW}  Warning: Directory already exists: $PRODUCTION_PATH${NC}"
    read -p "  Overwrite existing production? [y/N]: " OVERWRITE
    if [[ "$OVERWRITE" =~ ^[Yy]$ ]]; then
        echo -e "${RED}  This will DELETE all data in $PRODUCTION_PATH!${NC}"
        read -p "  Type 'DELETE' to confirm: " CONFIRM_DELETE
        if [[ "$CONFIRM_DELETE" == "DELETE" ]]; then
            rm -rf "$PRODUCTION_PATH"
            echo -e "${GREEN}  ✓ Removed existing directory${NC}"
        else
            echo -e "${RED}  Aborted.${NC}"
            exit 1
        fi
    else
        echo -e "${RED}  Aborted.${NC}"
        exit 1
    fi
fi
echo ""

# =============================================================================
# SECTION 2: RAW DATA PATHS
# =============================================================================
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}                        RAW DATA CONFIGURATION${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Juleana needs access to raw calibration and physics data."
echo "  These are typically located at different paths but have the same structure."
echo "  A unified 'raw' symlink directory will be created to access both."
echo ""

# Cal data path
echo -e "${BLUE}Calibration (cal) Raw Data Path${NC}"
echo "  Path to the directory containing calibration raw data"
echo "  Should end at the 'raw' level (e.g., .../tier/raw)"
echo "  The structure below should be: raw/cal/p01/r000/..."
while true; do
    read -p "  Cal raw path: " CAL_RAW_PATH
    if [[ -z "$CAL_RAW_PATH" ]]; then
        echo -e "${RED}  Error: Cal raw path is required!${NC}"
    elif [ -d "$CAL_RAW_PATH" ]; then
        # Remove trailing slash
        CAL_RAW_PATH="${CAL_RAW_PATH%/}"
        echo -e "${GREEN}  ✓ Path exists${NC}"
        break
    else
        echo -e "${YELLOW}  Warning: Path does not exist: $CAL_RAW_PATH${NC}"
        read -p "  Continue anyway? [y/N]: " CONTINUE
        if [[ "$CONTINUE" =~ ^[Yy]$ ]]; then
            CAL_RAW_PATH="${CAL_RAW_PATH%/}"
            break
        fi
    fi
done
echo ""

# Phy data path
echo -e "${BLUE}Physics (phy) Raw Data Path${NC}"
echo "  Path to the directory containing physics raw data"
echo "  Should end at the 'raw' level (e.g., .../tier/raw)"
echo "  The structure below should be: raw/phy/p01/r000/..."
while true; do
    read -p "  Phy raw path: " PHY_RAW_PATH
    if [[ -z "$PHY_RAW_PATH" ]]; then
        echo -e "${RED}  Error: Phy raw path is required!${NC}"
    elif [ -d "$PHY_RAW_PATH" ]; then
        # Remove trailing slash
        PHY_RAW_PATH="${PHY_RAW_PATH%/}"
        echo -e "${GREEN}  ✓ Path exists${NC}"
        break
    else
        echo -e "${YELLOW}  Warning: Path does not exist: $PHY_RAW_PATH${NC}"
        read -p "  Continue anyway? [y/N]: " CONTINUE
        if [[ "$CONTINUE" =~ ^[Yy]$ ]]; then
            PHY_RAW_PATH="${PHY_RAW_PATH%/}"
            break
        fi
    fi
done
echo ""

# =============================================================================
# SECTION 3: CONFIRMATION
# =============================================================================
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}                           SUMMARY${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${CYAN}Production:${NC}"
echo "  Name:              $PRODUCTION_NAME"
echo "  Path:              $PRODUCTION_PATH"
echo ""
echo -e "${CYAN}Raw Data:${NC}"
echo "  Cal raw:           $CAL_RAW_PATH"
echo "  Phy raw:           $PHY_RAW_PATH"
echo ""
echo -e "${CYAN}Directories to be created:${NC}"
echo "  $PRODUCTION_PATH/"
echo "  ├── config.json"
echo "  ├── legend-metadata/          (to be set up later)"
echo "  └── generated/"
echo "      ├── tier/"
echo "      ├── jllog/"
echo "      ├── jlreport/"
echo "      ├── jlplt/"
echo "      └── jlpar/"
echo "          ├── rpars/"
echo "          └── ppars/"
echo ""
echo "  $PRODUCTION_BASE/raw/         (symlinks)"
echo "  ├── cal -> $CAL_RAW_PATH/cal"
echo "  └── phy -> $PHY_RAW_PATH/phy"
echo ""
echo "  $PRODUCTION_BASE/jlpeaks/     (shared peaks directory)"
echo "  $PRODUCTION_BASE/jlml/        (shared ML directory)"
echo ""

read -p "Create this production environment? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${RED}Aborted.${NC}"
    exit 1
fi

# =============================================================================
# CREATE DIRECTORY STRUCTURE
# =============================================================================
echo ""
echo -e "${CYAN}Creating directories...${NC}"

# Main production directory
mkdir -p "$PRODUCTION_PATH"
echo -e "${GREEN}  ✓ Created $PRODUCTION_PATH${NC}"

# Generated subdirectories
mkdir -p "$PRODUCTION_PATH/generated/tier"
mkdir -p "$PRODUCTION_PATH/generated/jllog"
mkdir -p "$PRODUCTION_PATH/generated/jlreport"
mkdir -p "$PRODUCTION_PATH/generated/jlplt"
mkdir -p "$PRODUCTION_PATH/generated/jlpar/rpars"
mkdir -p "$PRODUCTION_PATH/generated/jlpar/ppars"
echo -e "${GREEN}  ✓ Created generated/ subdirectories${NC}"

# Placeholder for legend-metadata
mkdir -p "$PRODUCTION_PATH/legend-metadata"
echo -e "${GREEN}  ✓ Created legend-metadata/ placeholder${NC}"

# Shared directories (jlpeaks, jlml)
mkdir -p "$PRODUCTION_BASE/jlpeaks"
mkdir -p "$PRODUCTION_BASE/jlml"
echo -e "${GREEN}  ✓ Created shared jlpeaks/ and jlml/ directories${NC}"

# =============================================================================
# CREATE RAW SYMLINKS
# =============================================================================
echo ""
echo -e "${CYAN}Creating raw data symlinks...${NC}"

# Create raw directory with symlinks
RAW_SYMLINK_DIR="$PRODUCTION_BASE/raw"
mkdir -p "$RAW_SYMLINK_DIR"

# Create cal symlink
CAL_SOURCE="$CAL_RAW_PATH/cal"
if [ -d "$CAL_SOURCE" ] || [ -L "$CAL_SOURCE" ]; then
    ln -sfn "$CAL_SOURCE" "$RAW_SYMLINK_DIR/cal"
    echo -e "${GREEN}  ✓ Created symlink: raw/cal -> $CAL_SOURCE${NC}"
elif [ -d "$CAL_RAW_PATH" ]; then
    # Maybe the path already points to the cal directory
    ln -sfn "$CAL_RAW_PATH" "$RAW_SYMLINK_DIR/cal"
    echo -e "${YELLOW}  ⚠ Created symlink: raw/cal -> $CAL_RAW_PATH (no /cal subdirectory found)${NC}"
else
    echo -e "${RED}  ✗ Could not create cal symlink - source not found${NC}"
fi

# Create phy symlink
PHY_SOURCE="$PHY_RAW_PATH/phy"
if [ -d "$PHY_SOURCE" ] || [ -L "$PHY_SOURCE" ]; then
    ln -sfn "$PHY_SOURCE" "$RAW_SYMLINK_DIR/phy"
    echo -e "${GREEN}  ✓ Created symlink: raw/phy -> $PHY_SOURCE${NC}"
elif [ -d "$PHY_RAW_PATH" ]; then
    # Maybe the path already points to the phy directory
    ln -sfn "$PHY_RAW_PATH" "$RAW_SYMLINK_DIR/phy"
    echo -e "${YELLOW}  ⚠ Created symlink: raw/phy -> $PHY_RAW_PATH (no /phy subdirectory found)${NC}"
else
    echo -e "${RED}  ✗ Could not create phy symlink - source not found${NC}"
fi

# =============================================================================
# CREATE CONFIG.JSON
# =============================================================================
echo ""
echo -e "${CYAN}Creating config.json...${NC}"

CONFIG_FILE="$PRODUCTION_PATH/config.json"
cat > "$CONFIG_FILE" << EOF
{
    "setups": {
        "l200": {
            "paths": {
                "metadata": "\$_/legend-metadata/",

                "tier": "\$_/generated/tier/",
                "tier/jlpeaks": "\$_/../jlpeaks/",
                "tier/jlml": "\$_/../jlml/",
                "tier/raw": "\$_/../raw/",
                "tier/jllog": "\$_/generated/jllog/",
                "tier/jlreport": "\$_/generated/jlreport/",
                "tier/jlplt": "\$_/generated/jlplt/",

                "par": "\$_/generated/jlpar/"
            }
        }
    }
}
EOF

echo -e "${GREEN}  ✓ Created $CONFIG_FILE${NC}"

# =============================================================================
# CLONE LEGEND-METADATA
# =============================================================================
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}                      LEGEND-METADATA SETUP${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

echo -e "${BLUE}Clone legend-metadata Repository${NC}"
echo "  The metadata repository contains configuration for LEGEND data processing"
read -p "  Clone legend-metadata? [Y/n]: " CLONE_METADATA
CLONE_METADATA=${CLONE_METADATA:-Y}

if [[ "$CLONE_METADATA" =~ ^[Yy]$ ]]; then
    METADATA_PATH="$PRODUCTION_PATH/legend-metadata"
    
    # Remove placeholder directory
    rm -rf "$METADATA_PATH"
    
    echo ""
    echo -e "${CYAN}Cloning legend-metadata repository...${NC}"
    
    # Clone with submodules
    if git clone --recursive git@github.com:legend-exp/legend-metadata.git "$METADATA_PATH" 2>/dev/null; then
        echo -e "${GREEN}  ✓ Cloned legend-metadata${NC}"
        
        cd "$METADATA_PATH"
        
        # Suppress detached head warnings
        git config --local advice.detachedHead false
        
        # Initialize and update submodules
        git submodule init
        git submodule update
        
        echo ""
        echo -e "${CYAN}Checking out main branch for all submodules...${NC}"
        
        # Checkout main branch for legend-metadata itself
        git checkout main 2>/dev/null && git pull origin main 2>/dev/null || true
        
        # Checkout main for all submodules except jldataprod/config and jldataprod/overrides
        git submodule foreach --recursive '
            if [[ "$name" != "jldataprod/config" && "$name" != "jldataprod/overrides" ]]; then
                git checkout main 2>/dev/null && git pull origin main 2>/dev/null || echo "  Note: $name - using default branch"
            fi
        ' 2>/dev/null || true
        
        echo -e "${GREEN}  ✓ Checked out main branch for standard submodules${NC}"
        
        # Ask for jldataprod branches
        echo ""
        echo -e "${BLUE}jldataprod/config Branch${NC}"
        echo "  This submodule contains Juleana processing configuration"
        echo "  Available branches can be viewed at: github.com/legend-exp/legend-metadata-jldataprod-config"
        read -p "  Branch for jldataprod/config [main]: " JLDATAPROD_CONFIG_BRANCH
        JLDATAPROD_CONFIG_BRANCH=${JLDATAPROD_CONFIG_BRANCH:-main}
        
        echo ""
        echo -e "${BLUE}jldataprod/overrides Branch${NC}"
        echo "  This submodule contains detector-specific parameter overrides"
        echo "  Available branches can be viewed at: github.com/legend-exp/legend-metadata-jldataprod-overrides"
        read -p "  Branch for jldataprod/overrides [main]: " JLDATAPROD_OVERRIDES_BRANCH
        JLDATAPROD_OVERRIDES_BRANCH=${JLDATAPROD_OVERRIDES_BRANCH:-main}
        
        echo ""
        echo -e "${CYAN}Checking out jldataprod branches...${NC}"
        
        # Checkout jldataprod/config
        if [ -d "$METADATA_PATH/jldataprod/config" ]; then
            cd "$METADATA_PATH/jldataprod/config"
            if git checkout "$JLDATAPROD_CONFIG_BRANCH" 2>/dev/null && git pull origin "$JLDATAPROD_CONFIG_BRANCH" 2>/dev/null; then
                echo -e "${GREEN}  ✓ jldataprod/config -> $JLDATAPROD_CONFIG_BRANCH${NC}"
            else
                echo -e "${YELLOW}  ⚠ Could not checkout $JLDATAPROD_CONFIG_BRANCH for jldataprod/config${NC}"
            fi
        fi
        
        # Checkout jldataprod/overrides
        if [ -d "$METADATA_PATH/jldataprod/overrides" ]; then
            cd "$METADATA_PATH/jldataprod/overrides"
            if git checkout "$JLDATAPROD_OVERRIDES_BRANCH" 2>/dev/null && git pull origin "$JLDATAPROD_OVERRIDES_BRANCH" 2>/dev/null; then
                echo -e "${GREEN}  ✓ jldataprod/overrides -> $JLDATAPROD_OVERRIDES_BRANCH${NC}"
            else
                echo -e "${YELLOW}  ⚠ Could not checkout $JLDATAPROD_OVERRIDES_BRANCH for jldataprod/overrides${NC}"
            fi
        fi
        
        cd "$SCRIPT_DIR"
        
    else
        echo -e "${RED}  ✗ Failed to clone legend-metadata${NC}"
        echo -e "${YELLOW}    Make sure you have SSH access to github.com/legend-exp${NC}"
        echo -e "${YELLOW}    You can set up metadata manually later in: $METADATA_PATH${NC}"
    fi
else
    echo "  Skipping legend-metadata clone."
    echo "  You can set up metadata manually later in: $PRODUCTION_PATH/legend-metadata/"
fi

# =============================================================================
# SET AS DEFAULT (OPTIONAL)
# =============================================================================
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}                        FINALIZE SETUP${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

echo -e "${BLUE}Set as Default Production${NC}"
echo "  This will set LEGEND_DATA_CONFIG in your shell config file"
read -p "  Set this production as default? [Y/n]: " SET_DEFAULT
SET_DEFAULT=${SET_DEFAULT:-Y}

if [[ "$SET_DEFAULT" =~ ^[Yy]$ ]]; then
    # Determine shell config file
    SHELL_NAME=$(basename "$SHELL")
    case "$SHELL_NAME" in
        bash)
            RC_FILE="$HOME/.bashrc"
            ;;
        zsh)
            RC_FILE="$HOME/.zshrc"
            ;;
        *)
            RC_FILE="$HOME/.profile"
            ;;
    esac

    # Update or add LEGEND_DATA_CONFIG
    if grep -q "^export LEGEND_DATA_CONFIG=" "$RC_FILE" 2>/dev/null; then
        sed -i "s|^export LEGEND_DATA_CONFIG=.*|export LEGEND_DATA_CONFIG=\"$CONFIG_FILE\"|" "$RC_FILE"
        echo -e "${GREEN}  ✓ Updated LEGEND_DATA_CONFIG in $RC_FILE${NC}"
    else
        echo "" >> "$RC_FILE"
        echo "# Juleana production environment" >> "$RC_FILE"
        echo "export LEGEND_DATA_CONFIG=\"$CONFIG_FILE\"" >> "$RC_FILE"
        echo -e "${GREEN}  ✓ Added LEGEND_DATA_CONFIG to $RC_FILE${NC}"
    fi
    
    # Export for current session
    export LEGEND_DATA_CONFIG="$CONFIG_FILE"
    echo -e "${GREEN}  ✓ Set LEGEND_DATA_CONFIG for current session${NC}"
fi

# =============================================================================
# SUCCESS MESSAGE
# =============================================================================
echo ""
echo -e "${GREEN}=============================================================================${NC}"
echo -e "${GREEN}              PRODUCTION ENVIRONMENT CREATED SUCCESSFULLY${NC}"
echo -e "${GREEN}=============================================================================${NC}"
echo ""
echo -e "${CYAN}Production:${NC}"
echo "  Path:               $PRODUCTION_PATH"
echo "  Config file:        $CONFIG_FILE"
echo "  Raw symlinks:       $RAW_SYMLINK_DIR/"
echo ""

# Show metadata info if it was cloned
if [[ "${CLONE_METADATA:-N}" =~ ^[Yy]$ ]] && [ -d "$PRODUCTION_PATH/legend-metadata/.git" ]; then
    echo -e "${CYAN}Metadata:${NC}"
    echo "  Path:               $PRODUCTION_PATH/legend-metadata/"
    echo "  jldataprod/config:  ${JLDATAPROD_CONFIG_BRANCH:-main}"
    echo "  jldataprod/overrides: ${JLDATAPROD_OVERRIDES_BRANCH:-main}"
    echo ""
fi

echo -e "${CYAN}Next steps:${NC}"

# Only show metadata setup step if it wasn't cloned
if [[ ! "${CLONE_METADATA:-N}" =~ ^[Yy]$ ]] || [ ! -d "$PRODUCTION_PATH/legend-metadata/.git" ]; then
    echo "  1. Set up legend-metadata in $PRODUCTION_PATH/legend-metadata/"
    echo "     (Clone or symlink your metadata repository)"
    echo ""
fi

echo "  2. Source your shell config to activate the environment:"
echo -e "     ${CYAN}source ${RC_FILE:-~/.bashrc}${NC}"
echo ""
echo "  3. Verify the setup:"
echo -e "     ${CYAN}echo \$LEGEND_DATA_CONFIG${NC}"
echo ""
echo "  4. Run setup_batch_job.sh to create a SLURM batch script:"
echo -e "     ${CYAN}$SCRIPT_DIR/setup_batch_job.sh${NC}"
echo ""
