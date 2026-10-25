# Front-panel profile build rules for fpprofile.py.
#
#   make            regenerate profile.fpp (from the customised
#                   profile.yaml) and example_profiles.fpp (from the
#                   shipped example_profiles.yaml)
#   make install    scp both .fpp files to the MiSTer SD card
#   make test       run the fpprofile unit-test suite
#   make dump       decode profile.fpp for inspection
#   make clean      remove editor backups and __pycache__
#
# On the MiSTer the files are picked by the OSD item "Front Panel
# Profiles" (FC5); loading one resets the core so it takes effect
# immediately.  Override MISTER/DESTDIR on the command line to target a
# different host or directory.
#
# The .fpp artifacts are committed on purpose -- they are loadable
# deliverables -- so `clean` deliberately does not touch them.

MISTER    := mister
DESTDIR   := /media/fat/games/MrZ80
PYTHON    ?= python3
FPPROFILE := fpprofile.py
FPPS      := profile.fpp example_profiles.fpp

.PHONY: all install test dump clean

all: $(FPPS)

# Each .fpp comes from the .yaml of the same name.
%.fpp: %.yaml $(FPPROFILE)
	$(PYTHON) $(FPPROFILE) $< -o $@

install: all
	scp $(FPPS) $(MISTER):$(DESTDIR)/
	@echo "Installed to $(MISTER):$(DESTDIR)/ -- select the file with OSD > Front Panel Profiles."

test:
	$(PYTHON) -m unittest test_fpprofile

dump: profile.fpp
	$(PYTHON) $(FPPROFILE) --dump profile.fpp

clean:
	rm -f *~
	rm -rf __pycache__
