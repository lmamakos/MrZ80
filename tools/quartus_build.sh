#!/bin/bash
# quartus_build.sh — wrapper script to invoke Quartus compilation via SSH+Docker on tycho
#
# Usage:
#   tools/quartus_build.sh [quartus_sh options]
#   (or ./tools/quartus_build.sh if in the project root)
#
# Examples:
#   tools/quartus_build.sh --flow compile MultiComp -c MultiComp
#     (builds the entire project)
#
#   tools/quartus_build.sh --flow compile_synthesis MultiComp -c MultiComp
#     (runs only analysis & synthesis, skipping place & route)
#
#   tools/quartus_build.sh -t MultiComp
#     (queries current timing for the compiled design)
#
# Environment:
#   - Connects via SSH to the host 'tycho' (assumed to be in ~/.ssh/config or resolvable)
#   - Runs Docker container: ghcr.io/raetro/quartus:17.0
#   - Project root on tycho: Projects/z80fp/RomWBW_MultiComp_MiSTer
#   - Mounts current directory into /build inside the container
#
# Notes:
#   - This script can be run from the project root or from any subdirectory within it
#     (it will traverse up to find MultiComp.qpf and MultiComp.qsf).
#   - All output files are written back to the local project directory
#     after the container exits.
#   - This script requires SSH access to 'tycho' and Docker to be installed/configured there.

set -euo pipefail

# Find the project root by traversing up from the script's location
find_project_root() {
    local dir="$(cd "$(dirname "$0")" && pwd)"
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/MultiComp.qpf" && -f "$dir/MultiComp.qsf" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

PROJECT_ROOT=$(find_project_root) || {
    echo "Error: Could not find project root (MultiComp.qpf and MultiComp.qsf)."
    echo "Please ensure this script is run from within the project directory tree."
    exit 1
}

cd "$PROJECT_ROOT"

# Build the full command to be executed on tycho
# The script passes all arguments to quartus_sh
cmd="cd Projects/z80fp/MrZ80 && docker run --rm -v .:/build ghcr.io/raetro/quartus:17.0 quartus_sh $*"

echo "Invoking Quartus on tycho via Docker..."
echo "Command: $cmd"
echo ""

# Execute via SSH
ssh -t tycho "$cmd"
