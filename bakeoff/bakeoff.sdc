# bakeoff.sdc -- 50 MHz sysclk target for the throwaway bake-off fits (OQ-20)
create_clock -name {clk} -period 20.000 [get_ports {clk}]
derive_clock_uncertainty
