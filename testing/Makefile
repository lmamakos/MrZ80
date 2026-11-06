PROGS=	backtoback.bin	sdramexec.bin  sdramtest.bin  sdramsum.bin  sdramret.bin  timertest.bin  sdramstress.bin  blockdevtest.bin  sdcardtest.bin  fptest.bin  psgtest.bin  dazzldemo.bin
MISTER=	mister:/media/fat/games/MrZ80/diags/

all:	${PROGS}

install:
	scp  ${PROGS}  ${MISTER}

%.rel:	%.asm
	um80 $< -g -o $*.rel -l $*.prn

# MACRO-80 sources with the .azm suffix (same dialect; e.g. dazzldemo)
%.rel:	%.azm
	um80 $< -g -o $*.rel -l $*.prn

%.bin:	%.rel
	ul80 -p 0 --sym -x -o $*.hex $<
	objcopy -I ihex -O binary $*.hex $@ && rm $*.hex

clean:
	rm ${PROGS}
	rm  *.prn  *.lst  *.rel  *.sym  *.hex
	rm *~
