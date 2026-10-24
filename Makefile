# MrZ80 helper Makefile.
#
# install: copy the freshly built core image to the MiSTer SD card,
# stamped with the current date, e.g. /media/fat/_Computer/MrZ80_20261024.rbf.
# The image is produced by tools/build.sh (Quartus in Docker on tycho).

MRBF    := $(CURDIR)/output_files/MrZ80.rbf
MISTER  := mister
DESTDIR := /media/fat/_Computer

.PHONY: install
install:
	@test -f "$(MRBF)" || { echo "No built image at $(MRBF) - build it first (tools/build.sh)." >&2; exit 1; }
	scp "$(MRBF)" "$(MISTER):$(DESTDIR)/MrZ80_$$(date +%Y%m%d).rbf"
