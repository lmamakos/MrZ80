\ mecrisp-port.fs -- test-only Mecrisp port (qemu): memory is a plain
\ image preloaded at guest RAM $80100000, shown to the core at logical $9000
\ (the same addresses the Camel harness uses).  The real SSP port is in
\ ssp/fw/apps/monitor.fs (DZ@ reads the parked Z-80 through the D-30 engine).
0 variable DZ-PC
0 variable DZ-IX
0 variable DZ-DV
0 variable DZ-HD
: DZ@ ( a -- b ) $9000 - $80100000 + c@ ;
