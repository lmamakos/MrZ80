# CamelFORTH Z-80 

## Background

This FORTH implementation has been modified from it's original target
of running on a Z-80 CP/M system to also run on the "bare metal" of a
Z-80 system, with direct I/O to the console and no other operating
system.  The intention is to use it as a standalone capability to
explore the hardware of the system an act as a sort of monitor
program.

The intention is that the OS specific modules be isolated in the
`io-cpm.azm` and `io-multi.azm` files.

The first, `io-cpm.azm` accesses the standard CP/M BDOS to do console
I/O as well as accessing files on the CP/M system to store and load
FORTH "blocks".

The second, `io-multi.azm` is alternatively used in the "bare-metal"
version which runs directly on the hardware.


## Shared Z-80 disassembler

`DISASM` (blocks 30-49) is generated from `disasm/z80dis.fth`, the same source
the SSP monitor's `U` command uses. Do not edit the generated block files; see
`disasm/README.md`.


## Some notes, tools and snippets used for standalone environment

The FPGA core that implements the Z-80 system has an MMU (as
implemented in the `../Components/alancox/MMU.vhd` HDL) that allows
access to a 256MB sized address space, using 4 pages, each 16KB in
size.  Additionally, direct I/O anywhere in that space can be done
using I/O ports to specify the physical address and to read or write
bytes (with auto incrementation of the address pointer).

There is provision to preload an up to 8MB "RAM disk" at the top of
the first 128MB of SDRAM.  The intention is that this RAM disk will be
preloaded by the FPGA core with FORTH blocks containing useful FORTH
words that can be used in the standalone environment.  FORTH block I/O
would use this RAM disk to do I/O on 1KB sized blocks using the common
FORTH block I/O words.


## Some tools and snippets used for the CP/M environment

### listing and copying files in/out disk image

```
cpmls -f z80pack-hd  forthdev.dsk
cpmcp -f z80pack-hd  forthdev.dsk cam* 4:
```

Copying files in and out of CP/M disk, running inside
of SIMH and z80pack environment:

```
cpmcp  -t -f z80pack-hd ../z80pack/cpmsim/disks/drivei.dsk  *.azm *.sub forthmon.blk 4:
```
Use `BUILD.SUB` inside of CP/M to build new binary.  Then copy out the listings file for reference:

```
cpmcp  -t -f z80pack-hd ../z80pack/cpmsim/disks/drivei.dsk    4:camel80.prn .
```

Make blocks file:

```
cat start.f blank.f blank.f blank.f blank.f blank.f blank.f blank.f blank.f blank.f blank.f blank.f blank.f blank.f blank.f blank.f blank.f blank.f blank.f blank.f|sh mkblk.sh> forthmon.blk
```

Previous bootstrap loading words
```

( *************** Bootstrapping ***************)
DECIMAL
: load-block ( blockaddr -- ) 
    16 0 DO DUP I 64 * +  64 2DUP
      CR I . 62 EMIT TYPE 
      EVALUATE LOOP DROP ;

HEX 
: LOAD open-file 8000 read-file 
  10 0 DO 8000 I 40 * + 40 2DUP CR BASE @ DECIMAL I . BASE ! 3E EMIT
  SPACE TYPE EVALUATE LOOP ;

: init-block-file 
  S" block number)"
   40 1 DO
    2DUP
     [CHAR] ( dmabuf C!
     BL    dmabuf 1+ C!
     I 0 <# # # #> 
   LOOP
;
```

