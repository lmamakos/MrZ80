# Renders the architecture diagrams from their Graphviz sources.
#
#   make            all SVGs and PNGs
#   make clean      remove generated images
#
# The sheets, top to bottom (doc/ARCHITECTURE.md explains how they fit):
#
#   block.dot            the front page: major functional blocks on the Z-80 bus,
#                      labelled with their I/O ports and memory ranges only
#   overview.dot         the whole core at module level, with the sys/ framework as
#                      one box
#   z80.dot            T80, bus arbitration, reset-vector trampoline, MMU,
#                      block RAM, SDRAM client and the wait generation
#   peripherals.dot    the I/O devices and what they reach off-core
#   iomap.dot          the port map, plus the MMU / front-panel / PSG register
#                      windows
#   psg.dot          dual YM2149 sound: wrapper, vendored cores, pan sequencer
#   ssp.dot          the RISC-V System Support Processor and its seam
#   clocks.dot       clock domains, reset tree, clock-domain crossings
#
# block.dot is the one to show anyone who is using the machine rather than
# changing it; the others are implementation detail, one page each.
#
# Needs graphviz (dot).  The .dot sources are committed, and so are the SVGs
# referenced from doc/ARCHITECTURE.md, so the docs read without a toolchain;
# PNGs are ignored (regenerate with "make -C doc/architecture").

DOT      := $(wildcard *.dot)
SVGS     := $(DOT:.dot=.svg)
PNG      := $(DOT:.dot=.png)

.PHONY: all clean
.SUFFIXES:

all: $(SVGS) $(PNG)

%.svg: %.dot
	dot -Tsvg -o $@ $<

%.png: %.dot
	dot -Tpng -Gdpi=110 -o $@ $<

clean:
	rm -f $(SVGS) $(PNG)
