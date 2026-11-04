# Renders the architecture diagram from its Graphviz source.
#
#   make            the SVG and PNG
#   make clean      remove the generated images
#
# block.dot is the whole set: the major functional blocks on the Z-80 bus,
# labelled with their I/O ports and memory ranges and nothing more.  It is the
# view for people using the machine; the implementation detail lives in
# HARDWARE.md and the RTL, not in a subordinate sheet.
#
# Needs graphviz (dot).  The .dot source and the SVG referenced from
# doc/ARCHITECTURE.md are committed, so the docs read without a toolchain; the
# PNG is build output and is gitignored (regenerate with
# "make -C doc/architecture").

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
