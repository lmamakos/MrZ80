#!/bin/bash
# check_sync.sh - verify each SIMULATION-ONLY copy under sim/ has NOT
# drifted from its real synthesis-source counterpart, except for the
# specific `use` line(s) redirected to sim_compat_pkg (see
# sim_compat_pkg.vhd for why these copies exist at all: GHDL cannot
# analyze the real IEEE.STD_LOGIC_ARITH/STD_LOGIC_UNSIGNED uses).
#
# Method: for each (real, sim, redirected-line-numbers) triple, delete
# exactly those line numbers from BOTH files and diff the remainder --
# it must come out byte-identical (modulo CRLF, which the real sources
# use throughout). Separately confirms the sim copy's redirected lines
# actually reference sim_compat_pkg (so a "drift" can't silently pass by
# coincidentally matching line counts).
#
# Run this after ANY edit to any of the real files or their sim copies.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# real_relpath : sim_relpath : redirected line numbers (space-separated, 1-based)
CHECKS=(
    "MicrocomputerZ80CPM.vhd:sim/MicrocomputerZ80CPM_sim.vhd:18 19"
    "Components/UART/bufferedUART.vhd:sim/bufferedUART_sim.vhd:21"
    "Components/SDCARD/sd_controller.vhd:sim/sd_controller_sim.vhd:100"
)

fail=0

for check in "${CHECKS[@]}"; do
    real_rel="${check%%:*}"
    rest="${check#*:}"
    sim_rel="${rest%%:*}"
    lines="${rest#*:}"

    real="$PROJECT_ROOT/$real_rel"
    sim="$PROJECT_ROOT/$sim_rel"

    if [[ ! -f "$real" || ! -f "$sim" ]]; then
        echo "check_sync.sh: FAIL - expected both $real_rel and $sim_rel to exist" >&2
        fail=1
        continue
    fi

    # Build a sed delete expression for the given line numbers, e.g. "18d;19d"
    sed_expr=""
    for ln in $lines; do
        sed_expr+="${ln}d;"
    done

    real_masked="$(sed "$sed_expr" "$real" | tr -d '\r')"
    sim_masked="$(sed "$sed_expr" "$sim" | tr -d '\r')"

    if [[ "$real_masked" != "$sim_masked" ]]; then
        echo "check_sync.sh: FAIL - $sim_rel has drifted from $real_rel" >&2
        echo "beyond the expected redirected line(s) ($lines)." >&2
        echo "" >&2
        diff <(echo "$real_masked") <(echo "$sim_masked") >&2 || true
        echo "" >&2
        echo "Fix: cp $real_rel $sim_rel" >&2
        echo "then redirect line(s) $lines (the IEEE.STD_LOGIC_ARITH/" >&2
        echo "STD_LOGIC_UNSIGNED use-clause(s)) to reference sim_compat_pkg" >&2
        echo "(see sim/sim_compat_pkg.vhd)." >&2
        fail=1
        continue
    fi

    # Sanity check: the redirected lines in the sim copy must actually
    # reference sim_compat_pkg (or, for MicrocomputerZ80CPM_sim.vhd,
    # numeric_std) -- otherwise a drift could coincidentally still pass
    # the masked-diff check above (e.g. if someone blanked the lines).
    redirected_content="$(for ln in $lines; do sed -n "${ln}p" "$sim"; done)"
    if ! echo "$redirected_content" | grep -qi "sim_compat_pkg\|numeric_std"; then
        echo "check_sync.sh: FAIL - $sim_rel line(s) $lines no longer" >&2
        echo "reference sim_compat_pkg/numeric_std as expected:" >&2
        echo "$redirected_content" >&2
        fail=1
        continue
    fi

    echo "check_sync.sh: OK - $sim_rel matches $real_rel (only line(s) $lines redirected)"
done

exit $fail
