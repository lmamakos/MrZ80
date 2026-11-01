# Shared Z-80 disassembler: build the Camel blocks and run the cross-environment
# tests.  See README.md.   make check   runs everything.
#
#   make blocks   generate blocks 30-49 and rebuild forth.blk (forth/blocks)
#   make camel    run the test vectors in CamelFORTH  (z80 python package)
#   make mecrisp  run them in Mecrisp-Quintus under qemu
#   make check    both, verify each against the assembler, diff the two
OUT ?= /tmp/opencode/dztest
TEST = test

.PHONY: all blocks check camel mecrisp clean

all: blocks

blocks:
	$(MAKE) -C ../blocks

check: camel mecrisp
	python3 $(TEST)/verify.py $(OUT)/camel.json
	python3 $(TEST)/verify.py $(OUT)/mecrisp.json
	python3 $(TEST)/compare.py $(OUT)/camel.json $(OUT)/mecrisp.json

camel: blocks | $(OUT)
	python3 $(TEST)/harness_camel.py $(OUT)/camel.json

mecrisp: | $(OUT)
	$(MAKE) -C ../../ssp/fw qemu >/dev/null
	python3 $(TEST)/harness_mecrisp.py $(OUT)/mecrisp.json

$(OUT):
	mkdir -p $(OUT)

clean:
	rm -rf $(OUT)
