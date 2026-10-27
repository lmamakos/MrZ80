// tb_p1a_main.cpp -- Verilator harness for the P1a "first light" SoC
// (ssp_top + z80_bfm, sim/ssp/p1a_sim_top.v).  Clone of tb_stub_main.cpp
// with the p1a extras: no trap pin (gracilis, D-37), final info line comes
// from the RTL $display task; input-release gate identical (operator bytes
// flow only after FW proves life: first TX + grace).
//
// Plusargs: +ROM=<hex> +DUMP=<hex> +IDLE=<n> +MAXCYCLES=<n> +ECHO=1
//           plus the RTL-side switches (+OSD_OK/+OM/+WAIT/+RVRST/+NOGUEST).
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
static long g_tx_bytes = 0, g_rx_bytes = 0;
static bool g_eof = false;
static bool g_echo = false;

static unsigned char g_buf[4096];
static int g_b0 = 0, g_bn = 0;

extern "C" void tb_putc(int c) {
    if (getenv("TXTRACE")) fprintf(stderr, "TX c=%02x cyc=%lld\n", c & 0xff, g_cycle);
    fputc(c & 0xff, stdout);
    fflush(stdout);
    g_tx_bytes++;
    if (g_first_tx < 0) g_first_tx = g_cycle;
    g_last_tx = g_cycle;
}

static long long g_rxat = 400000;   // +RXAT=-1 disables cycle fallback

extern "C" int tb_rx_poll(void) {
    // Console release: after the FW's TX line goes QUIET (last byte + grace:
    // the kernel is done boot-printing and is polling KEY) OR after a fixed
    // cycle budget (R25: CONSOLE_OWN resets 0 -- a vanilla kernel never
    // transmits to the SNAC pin until the operator escapes into the monitor,
    // so a TX-only gate would deadlock the ESC-first flow).
    // +RXAT=<cycles> tunes the fallback (default 400k = 8 ms at 50 MHz).
    // (R26: was first_tx+grace, which fired mid-banner and overflowed the
    // depth-8 RX FIFO -- bytes lost before the kernel ever listened.)
    // The +RXAT fallback applies only while the FW has never transmitted;
    // once it talks, wait for it to go quiet.
    bool released = (g_first_tx >= 0) ? (g_cycle >= g_last_tx + 100000)
                                      : (g_rxat >= 0 && g_cycle >= g_rxat);
    if (!released) return -1;
    static bool rel_logged = false;
    if (!rel_logged) { rel_logged = true;
        fprintf(stderr, "[p1a] rx released @cycle %lld\n", g_cycle); }
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
    if (g_echo) { fputc(c, stdout); fflush(stdout); }
    g_rx_bytes++;
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
        if (g_eof && g_b0 == g_bn && g_cycle - g_last_tx > idle) break;
    }

    // MROM dump (dict pipeline)
    g_top->dump_req = 1;
    g_top->clk = 0; g_top->eval();
    g_top->clk = 1; g_top->eval();
    g_top->dump_req = 0; g_top->clk = 0; g_top->eval();

    fprintf(stderr,
            "[p1a] done: cycles=%lld tx=%ld rx=%ld rom_illegal=%u bus_errs=%u\n",
            g_cycle, g_tx_bytes, g_rx_bytes,
            (unsigned)g_top->dbg_rom_illegal_writes,
            (unsigned)g_top->dbg_bus_errs);

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
