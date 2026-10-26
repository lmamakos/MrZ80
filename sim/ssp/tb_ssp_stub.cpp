// tb_ssp_stub.cpp -- Verilator harness for ssp_stub_top (P0 RV-side sim).
//
// Console: model TX bytes -> stdout (flushed per byte); stdin -> RX queue.
// Local echo reproduces terminal behaviour so captured console logs match
// the qemu-lane format (assertions like "cmd -> result" keep working).
//
// RX pacing is structural: the RTL calls tb_rx_poll() only while its 8-byte
// FIFO has room, and this harness releases bytes one poll at a time --
// firmware-paced by construction, no host-side sleeps required.
//
// Plusargs: +ROM=<hex> (default ssp/fw/build/mecrisp-ssp.hex)
//           +DUMP=<hex> (dump rom[] at end of run; omit to skip)
//           +IDLE=<n>   exit after n cycles with no TX after stdin EOF
//           +MAXCYCLES=<n> hard cycle budget
//
// Exit codes: 0 normal, 2 core trap, 3 nothing ever transmitted (boot dead).

#include "Vssp_stub_top.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <fcntl.h>
#include <poll.h>
#include <termios.h>
#include <unistd.h>

static Vssp_stub_top *g_top = nullptr;
static int g_argc = 0;
static char **g_argv = nullptr;
static long long g_cycle = 0;
static long long g_first_tx = -1;          // cycle of FW's first TX byte
static long long g_last_tx = 0;
static long g_tx_bytes = 0, g_rx_bytes = 0;
static bool g_eof = false;
static bool g_echo = false;                // FW echoes received chars itself
                                          // (Mecrisp key); +ECHO=1 adds tty-style echo

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

extern "C" int tb_rx_poll(void) {
    // Operator semantics: the console is released only after the firmware
    // proves it is alive (first TX byte) plus a grace period -- FW's
    // uart_init rx_clr would otherwise flush early keystrokes (the real
    // operator types only after seeing the prompt).
    if (g_first_tx < 0 || g_cycle < g_first_tx + 100000) return -1;
    if (g_b0 == g_bn) {                      // queue empty: refill
        g_b0 = g_bn = 0;
        while (!g_eof) {
            ssize_t n = read(0, g_buf + g_bn, sizeof(g_buf) - g_bn);
            if (n > 0) {
                g_bn += (int)n;
                if ((size_t)g_bn == sizeof(g_buf)) break;
                continue;
            }
            if (n == 0) g_eof = true;       // stdin EOF
            break;                          // EAGAIN (or EOF)
        }
        if (g_b0 == g_bn) return -1;
    }
    unsigned char c = g_buf[g_b0++];
    if (g_b0 == g_bn) g_b0 = g_bn = 0;
    if (g_echo) {                           // local echo (terminal-like)
        fputc(c, stdout);
        fflush(stdout);
    }
    g_rx_bytes++;
    return c;
}

extern "C" void tb_bus_err(int addr) {
    fprintf(stderr, "[stub] decoder error: core accessed 0x%08x\n", addr);
}

static long long plusarg_ll(const char *key, long long dflt) {
    const char *p = nullptr;
    for (int i = 1; i < g_argc; i++)
        if (!strncmp(g_argv[i], key, strlen(key))) { p = g_argv[i] + strlen(key); break; }
    if (!p) return dflt;
    return (*p) ? strtoll(p, nullptr, 0) : 1;   // bare switch form
}

int main(int argc, char **argv) {
    g_argc = argc; g_argv = argv;
    Verilated::commandArgs(argc, argv);

    if (plusarg_ll("+NOECHO=", -1) >= 0) g_echo = false;
    if (plusarg_ll("+ECHO=",   -1) >= 0) g_echo = true;
    long long idle = plusarg_ll("+IDLE=", 5000000);
    long long maxc = plusarg_ll("+MAXCYCLES=", 400000000);

    // Non-blocking stdin; raw mode when attached to a terminal.
    struct termios tio_save;
    bool tty = isatty(0);
    if (tty) { tcgetattr(0, &tio_save);
        struct termios raw = tio_save;
        raw.c_lflag &= ~(ICANON | ECHO);
        raw.c_cc[VMIN] = 0; raw.c_cc[VTIME] = 0;
        tcsetattr(0, TCSANOW, &raw); }
    fcntl(0, F_SETFL, fcntl(0, F_GETFL, 0) | O_NONBLOCK);

    g_top = new Vssp_stub_top;

    // 5 cycles of reset
    g_top->clk = 0; g_top->rst_n = 0; g_top->dump_req = 0;
    for (int i = 0; i < 5; i++) { g_top->clk = !g_top->clk; g_top->eval(); g_cycle++; }
    g_top->rst_n = 1;

    int rc = 0;
    bool trapped = false;
    while (!Verilated::gotFinish() && g_cycle < maxc) {
        g_top->clk = 0; g_top->eval();
        g_top->clk = 1; g_top->eval();
        g_cycle += 2;
        if (g_top->trap) { trapped = true; break; }
        if (g_eof && g_b0 == g_bn && g_cycle - g_last_tx > idle) break;
    }

    if (trapped) {
        fprintf(stderr, "[stub] TRAP asserted (core exception) at cycle %lld\n", g_cycle);
        rc = 2;
    }

    // ROM dump for the D-35 pipeline (kernel + built dictionary)
    g_top->dump_req = 1;
    g_top->clk = 0; g_top->eval();
    g_top->clk = 1; g_top->eval();
    g_top->dump_req = 0; g_top->clk = 0; g_top->eval();

    fprintf(stderr,
            "[stub] done: cycles=%lld tx=%ld rx=%ld rx_fifo=%u rx_overrun=%u "
            "rom_core_writes=%u bus_errs=%u trap=%d\n",
            g_cycle, g_tx_bytes, g_rx_bytes,
            (unsigned)g_top->rx_fifo_level, (unsigned)g_top->rx_overrun,
            (unsigned)g_top->dbg_rom_core_writes, (unsigned)g_top->dbg_bus_errs,
            (int)trapped);

    if (!trapped && g_tx_bytes == 0) { fprintf(stderr, "[stub] no console output -- boot dead\n"); rc = 3; }
    if (!trapped && g_top->dbg_bus_errs) rc = rc ? rc : 1;
    if (!trapped && g_top->dbg_rom_core_writes) {
        fprintf(stderr, "[stub] NOTE: writes below dict window (would corrupt release image)\n");
        rc = rc ? rc : 1;
    }

    delete g_top;
    if (tty) tcsetattr(0, TCSANOW, &tio_save);
    return rc;
}
