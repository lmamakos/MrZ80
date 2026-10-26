\ MrZ80 SSP demo application dictionary -- P0 compiletoflash pipeline
\ rehearsal content (D-35). Real SSP application words replace this file
\ as P1a FW features land; the build pipeline is unchanged.
\
\ fed to the REPL AFTER `compiletoflash`, i.e. these words land in the
\ contiguous MROM dictionary window at FlashDictionaryAnfang.

$20000000 constant SSP_BASE ( ssp_bridge base, ssp/regs/ssp_regs.csv )
$20000000 constant SSP_ID   ( bridge ID register )

: reg-id       SSP_ID @ ;             ( -- u  bridge ID word )
: 42answer     42 ;                 ( -- n  pipeline canary value )
: cpu-hello    ." Hello from the SSP application dictionary" cr ;
