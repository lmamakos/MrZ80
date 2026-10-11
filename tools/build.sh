#!/bin/bash
# build.sh — convenience wrapper for common Quartus build targets
#
# Usage:
#   tools/build.sh [target]
#   (or ./tools/build.sh if in the project root)
#
# Targets:
#   full       Build the entire project (analysis, synthesis, place & route) [default]
#   synth      Run only analysis & synthesis (skip place & route)
#   help       Display this help message
#   <other>    Pass directly to quartus_build.sh (for custom arguments)
#
# Examples:
#   tools/build.sh              # Full compile
#   tools/build.sh synth        # Synthesis only
#   tools/build.sh help         # Show Quartus help
#
# The output .rbf file will be written to output_files/MrZ80.rbf

set -euo pipefail

# Find the tools directory (where this script is located)
TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
# Project root is one level up from tools/
PROJECT_ROOT="$(dirname "$TOOLS_DIR")"
QUARTUS_BUILD="$TOOLS_DIR/quartus_build.sh"

# Validate project root and quartus_build.sh
if [[ ! -f "$PROJECT_ROOT/MrZ80.qpf" || ! -f "$PROJECT_ROOT/MrZ80.qsf" ]]; then
    echo "Error: MrZ80.qpf and MrZ80.qsf not found in $PROJECT_ROOT"
    echo "Please run this script from the project root or a subdirectory."
    exit 1
fi

if [[ ! -x "$QUARTUS_BUILD" ]]; then
    echo "Error: $QUARTUS_BUILD not found or not executable."
    echo "Please ensure quartus_build.sh is in the same directory as this script."
    exit 1
fi

# Parse target (default to 'full')
TARGET="${1:-full}"

case "$TARGET" in
    full)
        echo "Building entire project (analysis, synthesis, place & route)..."
        "$QUARTUS_BUILD" --flow compile MrZ80 -c MrZ80
        ;;
    synth)
        echo "Running analysis & synthesis only (skipping place & route)..."
        "$QUARTUS_BUILD" --flow analysis_and_synthesis MrZ80 -c MrZ80
        ;;
    help)
        echo "Usage: tools/build.sh [target]"
        echo ""
        echo "Targets:"
        echo "  full       Build the entire project (analysis, synthesis, place & route) [default]"
        echo "  synth      Run only analysis & synthesis (skip place & route)"
        echo "  help       Display this help message"
        echo "  <other>    Pass directly to quartus_build.sh (for custom arguments)"
        echo ""
        echo "Examples:"
        echo "  tools/build.sh              # Full compile"
        echo "  tools/build.sh synth        # Synthesis only"
        echo "  tools/build.sh help         # Show Quartus help"
        exit 0
        ;;
    *)
        # Pass unknown targets directly to quartus_build.sh
        echo "Passing target '$TARGET' directly to quartus_build.sh..."
        "$QUARTUS_BUILD" "$TARGET" "${@:2}"
        ;;
esac
