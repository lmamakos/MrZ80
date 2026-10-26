-- ============================================================================
-- sim_compat_pkg.vhd - SIMULATION-ONLY compatibility shim.
--
-- MicrocomputerZ80CPM.vhd uses the legacy Synopsys `IEEE.STD_LOGIC_ARITH` /
-- `IEEE.STD_LOGIC_UNSIGNED` packages (only for `cpuClkCount`/`sdClkCount`,
-- two 6-bit std_logic_vector counters compared/incremented against integer
-- literals -- see the "+"/"<" uses in the cpuClock-divider process). Real
-- synthesis (Quartus) ships these packages and needs no changes.
--
-- GHDL (the open-source simulator used for this project's testbenches) does
-- NOT ship a redistributable implementation of these packages -- they are
-- proprietary Synopsys extensions, never part of the IEEE standard, and
-- GHDL's own package build deliberately ships the "synopsys" library
-- source tree empty for licensing reasons. GHDL also specially recognises
-- (and rejects as "ill-formed") any user-provided package literally named
-- IEEE.STD_LOGIC_ARITH/STD_LOGIC_UNSIGNED, so they cannot be locally
-- reimplemented under the `ieee` library name either.
--
-- Rather than modify the real synthesis sources (which must stay
-- byte-for-byte what Quartus builds), sim/MicrocomputerZ80CPM_sim.vhd,
-- sim/bufferedUART_sim.vhd, and sim/sd_controller_sim.vhd are
-- SIMULATION-ONLY copies with their `use IEEE.STD_LOGIC_ARITH`/
-- `STD_LOGIC_UNSIGNED` line(s) redirected to `use work.sim_compat_pkg.all`
-- (this package), which reimplements exactly the operators actually used
-- across those files under an unsigned interpretation (matching
-- STD_LOGIC_UNSIGNED semantics): `std_logic_vector + integer`,
-- `std_logic_vector - integer`, `std_logic_vector < integer`, and
-- `std_logic_vector = integer`.
--
-- sim/check_sync.sh diffs each simulation copy against its real
-- counterpart and fails if anything beyond the expected `use`-line
-- redirect differs, so none of these copies can silently drift from the
-- real synthesis source. Run it after ANY edit to any of these files.
--
-- RESYNC 2026-10-26 (P0, H-1): the top level grew since this shim was
-- written (capture-chain segments, reset_counter, sdram_gap_cnt,
-- serialClkCount) and now also uses the STD_LOGIC_ARITH `unsigned`
-- SUBTYPE in signal declarations and the `unsigned(std_logic_vector)`
-- conversion. No new shim declarations are needed for those: GHDL's
-- ieee.numeric_std (with -fsynopsys) provides the `unsigned` subtype and
-- the `unsigned()` conversion directly. The resync only had to restore
-- the canonical redirect PAIR in sim/MicrocomputerZ80CPM_sim.vhd --
--   use ieee.numeric_std.all;      (was IEEE.STD_LOGIC_ARITH)
--   use work.sim_compat_pkg.all;   (was IEEE.STD_LOGIC_UNSIGNED)
-- which mirrors the original pattern; an intermediate attempt that
-- replaced BOTH lines with sim_compat_pkg alone lost numeric_std and
-- failed exactly these `unsigned` references. The top level has no
-- explicit `use ieee.numeric_std.all` of its own, so the sim copy must
-- supply it via this redirect. Operators verified present after resync:
-- slv+/-integer, slv</>=integer (here), unsigned subtype + conversion
-- (here), and the bufferedUART/sd_controller uses -- no additions to
-- this package body were required.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package sim_compat_pkg is
    function "+" (l : std_logic_vector; r : integer) return std_logic_vector;
    function "-" (l : std_logic_vector; r : integer) return std_logic_vector;
    function "<" (l : std_logic_vector; r : integer) return boolean;
    function "=" (l : std_logic_vector; r : integer) return boolean;
end package sim_compat_pkg;

package body sim_compat_pkg is

    function "+" (l : std_logic_vector; r : integer) return std_logic_vector is
    begin
        return std_logic_vector(unsigned(l) + to_unsigned(r, l'length));
    end function;

    function "-" (l : std_logic_vector; r : integer) return std_logic_vector is
    begin
        return std_logic_vector(unsigned(l) - to_unsigned(r, l'length));
    end function;

    function "<" (l : std_logic_vector; r : integer) return boolean is
    begin
        return to_integer(unsigned(l)) < r;
    end function;

    function "=" (l : std_logic_vector; r : integer) return boolean is
    begin
        return to_integer(unsigned(l)) = r;
    end function;

end package body sim_compat_pkg;
