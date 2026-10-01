CPMDISK=../z80pack/cpmsim/disks/drivei.dsk
CPMFORMAT=z80pack-hd
CPMDEST=4:

MULTICOMPDEST=5:
MULTICOMPDISK=../z80pack/cpmsim/disks/drivei.dsk
MULTICOMPFORMAT=z80pack-hd

all:	camel80.bin camelf.bin camel80cpm.com

# Assembly: all variants share the camel80.azm kernel but differ in -D
# defines (which also selects the io-*.azm it INCLUDEs via IFDEF CPM).
camel80.rel:	camel80.azm camel80d.azm camel80h.azm cameltst.azm io-multi.azm
	um80 camel80.azm -D BOOTABLE=1 -g -o camel80.rel -l camel80.prn

# this version enabled for custom NEXT instruction in FPGA T80 CPU
camelf.rel:	camel80.azm camel80d.azm camel80h.azm cameltst.azm io-multi.azm
	um80 camel80.azm -D BOOTABLE=1 -D CUSTNEXT=1 -g -o camelf.rel -l camelf.prn

# CP/M variant: same camel80.azm kernel, assembled with -D CPM so it
# INCLUDEs io-cpm.azm (BDOS file I/O) instead of io-multi.azm (embedded
# Z80 Multicomputer ROM words). Output is a flat binary with ORG 100h
# baked in by the source (CP/M's TPA entry point) -- i.e. it can be copied
# directly onto a CP/M disk image as CAMEL80.COM with no on-CP/M assembly
# step required.
camel80cpm.rel:	camel80.azm camel80d.azm camel80h.azm cameltst.azm io-cpm.azm
	um80 camel80.azm -D CPM=1 -g -o camel80cpm.rel -l camel80cpm.prn

# Link + flatten to flat binary, shared by all variants.
%.bin: %.rel
	ul80 -p 0 --sym -x -o $*.hex $<
	objcopy -I ihex -O binary $*.hex $@ && rm $*.hex

%.com: %.rel
	ul80 -p 0 --sym -x -o $*.hex $<
	objcopy -I ihex -O binary $*.hex $@ && rm $*.hex


clean:
	rm -f  *.prn *.lst *.rel *.sym camel80.bin camelf.bin camel80cpm.com
	rm -f  *~

all:
	cd blocks; make

install:	camel80.bin camelf.bin
	scp camel80.bin       mister:/media/fat/games/MultiComp/camel80.bin
	scp camelf.bin        mister:/media/fat/games/MultiComp/camelf.bin
	scp blocks/forth.blk  mister:/media/fat/games/MultiComp/forth.dsk

cpm: blocks/forth.blk
	@echo make sure to remove all the *.AZM and *.SUB files from the CP/M disk image
	cpmcp -t -f ${CPMFORMAT}  ${CPMDISK}  camel80.azm    ${CPMDEST}camel80.azm
	cpmcp -t -f ${CPMFORMAT}  ${CPMDISK}  camel80d.azm   ${CPMDEST}camel80d.azm
	cpmcp -t -f ${CPMFORMAT}  ${CPMDISK}  camel80h.azm   ${CPMDEST}camel80h.azm	
	cpmcp -t -f ${CPMFORMAT}  ${CPMDISK}  camel80cfg.azm ${CPMDEST}camelcfg.azm
	cpmcp -t -f ${CPMFORMAT}  ${CPMDISK}  io-cpm.azm     ${CPMDEST}io-cpm.azm
	cpmcp -t -f ${CPMFORMAT}  ${CPMDISK}  build.sub      ${CPMDEST}build.sub
	cpmcp    -f ${CPMFORMAT}  ${CPMDISK}  blocks/forth.blk   ${CPMDEST}forth.blk
	@echo "Now ^C in CP/M to login disk and then build"

cpminstall: blocks/forth.blk
	cpmcp    -f ${CPMFORMAT}  ${CPMDISK}  blocks/forth.blk   ${CPMDEST}forth.blk

fetchcpm:
	cpmcp -f ${CPMFORMAT}  ${CPMDISK}  ${CPMDEST}camel80.com zout/camel80.com
	cp blocks/forth.blk zout/

embedded:
	@echo make sure to remove all the *.AZM and *.SUB files from the CP/M disk image
	cpmcp -t -f ${MULTICOMPFORMAT}  ${MULTICOMPDISK}  camel80.azm    ${MULTICOMPDEST}camel80.azm
	cpmcp -t -f ${MULTICOMPFORMAT}  ${MULTICOMPDISK}  camel80d.azm   ${MULTICOMPDEST}camel80d.azm
	cpmcp -t -f ${MULTICOMPFORMAT}  ${MULTICOMPDISK}  camel80h-embedded.azm   ${MULTICOMPDEST}camel80h.azm	
	cpmcp    -f ${MULTICOMPFORMAT}  ${MULTICOMPDISK}  blocks/forthmon.blk   ${MULTICOMPDEST}forthmon.blk
	cpmcp -t -f ${MULTICOMPFORMAT}  ${MULTICOMPDISK}  camel80cfg-embedded.azm ${MULTICOMPDEST}camelcfg.azm
	cpmcp -t -f ${MULTICOMPFORMAT}  ${MULTICOMPDISK}  build-embedded.sub      ${MULTICOMPDEST}build.sub
	cpmcp    -f ${MULTICOMPFORMAT}  ${MULTICOMPDISK}  support/m80.com support/l80.com   ${MULTICOMPDEST}forthmon.blk
	@echo "Now ^C in CP/M to login disk and then build"

blocks/forth.blk: blocks
	cd blocks; make

%.blk: %.f
	./mkblk.sh $<   > $@ 

%.blk: %.fth
	./mkblk.sh $<   > $@ 
