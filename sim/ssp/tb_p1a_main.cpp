// tb_p1a_main.cpp -- Verilator harness for the P1a "first light" SoC
// (ssp_top + z80_bfm, sim/ssp/p1a_sim_top.v).  Clone of tb_stub_main.cpp
// with the p1a extras: no trap pin (gracilis, D-37), final info line comes
// from the RTL $display task; input-release gate identical (operator bytes
// flow only after FW proves life: first TX + grace).
//
// Plusargs: +ROM=<hex> +DUMP=<hex> +IDLE=<n> +MAXCYCLES=<n> +ECHO=1 +PAUSE=<n>
//           +LINEWAIT=1|2: line-at-a-time pacing for long scripts.  After each
//           CR the input is held until the line has been processed:
//             1 (Mecrisp REPL, dictionary build): the FW's prompt "ok." has
//               been printed and TX has then been quiet for +QUIET=<n>
//               cycles (default 100000); +LINETO=<n> (default 8M) cycles
//               release it anyway (error lines print no "ok.").  A slow
//               Mecrisp line (~50k cycles per token) otherwise lets the
//               sender run several lines ahead and overflow the RX FIFO.
//             2 (monitor): TX quiet for +QUIET=<n> cycles since the CR / the
//               last TX byte (the monitor's commands are much faster than
//               its serial output).
// Exit codes: 0 normal, 3 nothing ever transmitted (boot dead),
//             1 counted bus/rom-illegal errors (after dump).

#include "Vssp_p1a_top.h"
#include "verilated.h"
#if VM_TRACE
#include "verilated_vcd_c.h"
#endif

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <fcntl.h>
#include <termios.h>
#include <unistd.h>

static Vssp_p1a_top *g_top = nullptr;
static int g_argc = 0;
static char **g_argv = nullptr;
static long long g_cycle = 0;
static long long g_first_tx = -1;
static long long g_last_tx = 0;
static long long g_last_rx = 0;      // cycle the last input byte went out
static long g_tx_bytes = 0, g_rx_bytes = 0;
static bool g_eof = false;
static bool g_echo = false;

static long long g_line_cr = -1;     // cycle the last CR went out (linewait)
static bool      g_line_ok = false;  // "ok." seen since that CR
static long long g_line_to = 8000000;
static int       g_tx_hist = 0;      // last three TX bytes
static unsigned char g_buf[4096];
static int g_b0 = 0, g_bn = 0;

extern "C" void tb_putc(int c) {
    if (getenv("TXTRACE")) fprintf(stderr, "TX c=%02x cyc=%lld\n", c & 0xff, g_cycle);
    fputc(c & 0xff, stdout);
    fflush(stdout);
    g_tx_bytes++;
    g_tx_hist = ((g_tx_hist << 8) | (c & 0xff)) & 0xffffff;
    if (g_tx_hist == (('o' << 16) | ('k' << 8) | '.')) g_line_ok = true;
    if (g_first_tx < 0) g_first_tx = g_cycle;
    g_last_tx = g_cycle;
}

static long long g_rxat = 400000;   // +RXAT=-1 disables cycle fallback

static long long g_quiet = 100000;  // TX-quiet grace before typing on
static long long g_pause = 400000;  // +PAUSE: length of an in-band 0x01 pause
static long long g_pause_until = 0;
static int       g_linewait = 0;

extern "C" int tb_rx_poll(void) {
    // Operator model, two steps (R26):
    //  1. The FIRST byte (normally the escape) goes out at +RXAT, or earlier
    //     once the FW has transmitted and then gone quiet.  R25: CONSOLE_OWN
    //     resets 0, so the monitor is silent on the pin until the escape --
    //     a TX-only gate would deadlock.
    //  2. The REST waits until the monitor's TX has been quiet for g_quiet
    //     cycles (it has finished printing and is polling KEY).  Sending
    //     while it prints can overflow the RX FIFO (128 bytes).  Precisely: the
    //     rest goes out once g_quiet cycles have passed since both byte 1
    //     and the last TX byte.
    // +RXAT=<cycles> sets step 1 (default 400k = 8 ms at 50 MHz).
    static long long sent1_at = -1;
    static bool open = false;
    // In-band pause (R27): a 0x01 byte in the input is consumed by the
    // harness, never sent, and holds the input for +PAUSE cycles.  Lets a
    // script wait out a slow Mecrisp line (each token is a full dictionary
    // search, ~50k cycles) before the next escape, so a late-executing
    // line cannot overwrite the escape's hardware hand-over.
    if (g_cycle < g_pause_until) return -1;
    if (g_line_cr >= 0) {
        if (g_linewait == 2) {
            long long since = g_last_tx > g_line_cr ? g_last_tx : g_line_cr;
            if (g_cycle < since + g_quiet) return -1;
        } else if (g_line_ok) {
            if (g_cycle < g_last_tx + g_quiet) return -1;
        } else if (g_cycle < g_line_cr + g_line_to) {
            return -1;
        }
        g_line_cr = -1;
    }
    if (!open) {
        bool quiet = g_first_tx >= 0 && g_cycle >= g_last_tx + g_quiet;
        if (sent1_at < 0) {
            if (!(quiet || (g_rxat >= 0 && g_cycle >= g_rxat))) return -1;
        } else {
            long long since = g_last_tx > sent1_at ? g_last_tx : sent1_at;
            if (g_cycle < since + g_quiet) return -1;
            open = true;
            fprintf(stderr, "[p1a] rx open @cycle %lld\n", g_cycle);
        }
    }
    if (g_b0 == g_bn) {
        g_b0 = g_bn = 0;
        while (!g_eof) {
            ssize_t n = read(0, g_buf + g_bn, sizeof(g_buf) - g_bn);
            if (n > 0) {
                g_bn += (int)n;
                if ((size_t)g_bn == sizeof(g_buf)) break;
                continue;
            }
            if (n == 0) g_eof = true;
            break;
        }
        if (g_b0 == g_bn) return -1;
    }
    unsigned char c = g_buf[g_b0++];
    if (g_b0 == g_bn) g_b0 = g_bn = 0;
    if (c == 0x01) {                        // pause marker
        g_pause_until = g_cycle + g_pause;
        return -1;
    }
    if (g_echo) { fputc(c, stdout); fflush(stdout); }
    if (sent1_at < 0) {
        sent1_at = g_cycle;
        fprintf(stderr, "[p1a] rx byte 1 @cycle %lld\n", g_cycle);
    }
    g_rx_bytes++;
    g_last_rx = g_cycle;
    if (g_linewait && c == 0x0D) { g_line_cr = g_cycle; g_line_ok = false; }
    return c;
}

static long long plusarg_ll(const char *key, long long dflt) {
    const char *p = nullptr;
    for (int i = 1; i < g_argc; i++)
        if (!strncmp(g_argv[i], key, strlen(key))) { p = g_argv[i] + strlen(key); break; }
    if (!p) return dflt;
    return (*p) ? strtoll(p, nullptr, 0) : 1;
}

int main(int argc, char **argv) {
    g_argc = argc; g_argv = argv;
    Verilated::commandArgs(argc, argv);

    if (plusarg_ll("+NOECHO=", -1) >= 0) g_echo = false;
    if (plusarg_ll("+ECHO=",   -1) >= 0) g_echo = (plusarg_ll("+ECHO=", 0) != 0);
    long long idle = plusarg_ll("+IDLE=", 8000000);
    long long maxc = plusarg_ll("+MAXCYCLES=", 600000000);
    g_rxat = plusarg_ll("+RXAT=", 400000);
    g_pause = plusarg_ll("+PAUSE=", 400000);
    g_quiet = plusarg_ll("+QUIET=", 100000);
    g_linewait = (int)plusarg_ll("+LINEWAIT=", 0);
    g_line_to = plusarg_ll("+LINETO=", 8000000);

    struct termios tio_save;
    bool tty = isatty(0);
    if (tty) { tcgetattr(0, &tio_save);
        struct termios raw = tio_save;
        raw.c_lflag &= ~(ICANON | ECHO);
        raw.c_cc[VMIN] = 0; raw.c_cc[VTIME] = 0;
        tcsetattr(0, TCSANOW, &raw); }
    fcntl(0, F_SETFL, fcntl(0, F_GETFL, 0) | O_NONBLOCK);

    g_top = new Vssp_p1a_top;

#if VM_TRACE
    VerilatedVcdC *tfp = nullptr;
    if (plusarg_ll("+VCD", -1) >= 0) {
        Verilated::traceEverOn(true);
        tfp = new VerilatedVcdC;
        g_top->trace(tfp, 99);
        tfp->open("sim/ssp/p1a.vcd");
    }
#endif

    g_top->clk = 0; g_top->rst_n = 0; g_top->dump_req = 0;
    for (int i = 0; i < 5; i++) { g_top->clk = !g_top->clk; g_top->eval(); g_cycle++; }
    g_top->rst_n = 1;

    int rc = 0;
    while (!Verilated::gotFinish() && g_cycle < maxc) {
#if VM_TRACE
        if (tfp) tfp->dump((double)g_cycle);    // pre-edge state
#endif
        g_top->clk = 0; g_top->eval();
        g_top->clk = 1; g_top->eval();
        g_cycle += 1;                     // one clock edge per iteration
        if (g_eof && g_b0 == g_bn &&
            g_cycle - (g_last_tx > g_last_rx ? g_last_tx : g_last_rx) > idle) break;
    }

    // MROM dump (dict pipeline)
    g_top->dump_req = 1;
    g_top->clk = 0; g_top->eval();
    g_top->clk = 1; g_top->eval();
    g_top->dump_req = 0; g_top->clk = 0; g_top->eval();

    fprintf(stderr,
            "[p1a] done: cycles=%lld tx=%ld rx=%ld rom_illegal=%u bus_errs=%u"
            " guest_rx=%u freeze_acc=%u io_wr=%u(%02x,%02x)\n",
            g_cycle, g_tx_bytes, g_rx_bytes,
            (unsigned)g_top->dbg_rom_illegal_writes,
            (unsigned)g_top->dbg_bus_errs,
            (unsigned)g_top->dbg_guest_rx, (unsigned)g_top->dbg_freeze_acc,
            (unsigned)g_top->dbg_io_wr_count, (unsigned)g_top->dbg_io_wr_port,
            (unsigned)g_top->dbg_io_wr_data);

    if (g_tx_bytes == 0) { fprintf(stderr, "[p1a] no console output -- boot dead\n"); rc = 3; }
    if (g_top->dbg_bus_errs) rc = rc ? rc : 1;
    if (g_top->dbg_rom_illegal_writes) rc = rc ? rc : 1;

#if VM_TRACE
    if (tfp) { tfp->close(); delete tfp; }
#endif
    delete g_top;
    if (tty) tcsetattr(0, TCSANOW, &tio_save);
    return rc;
}
