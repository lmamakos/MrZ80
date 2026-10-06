PROGS=	backtoback.bin	sdramexec.bin  sdramtest.bin  sdramsum.bin  sdramret.bin  timertest.bin  sdramstress.bin
MISTER=	mister:/media/fat/games/MultiComp/

all:	${PROGS}

install:
	scp  ${PROGS}  ${MISTER}

%.rel:	%.asm
	um80 $< -g -o $*.rel -l $*.prn

%.bin:	%.rel
	ul80 -p 0 --sym -x -o $*.hex $<
	objcopy -I ihex -O binary $*.hex $@ && rm $*.hex

clean:
	rm ${PROGS}
	rm  *.prn  *.lst  *.rel  *.sym  *.hex
	rm *~
