# Clocks of the 286 machine on the Tang Nano 20K
create_clock -name sys_clk -period 37.037 [get_ports {sys_clk}]

# HDMI: 126 MHz serializer clock, 25.2 MHz pixel clock
create_clock -name clk_5x -period 7.936 [get_nets {clk_5x}]
create_clock -name clk_pix -period 39.682 -waveform {0 19.841} [get_pins {clkdiv_hdmi/CLKOUT}]

# 101.25 MHz, the common source of the CPU clock (/4, 25.3125 MHz) and the SDRAM clock (/2).
# Generated clocks, so that the crossing between the two is analysed.
create_clock -name clk_fast -period 9.876 [get_pins {pll_core/rpll_inst/CLKOUT}]
create_generated_clock -name clk_cpu -source [get_pins {pll_core/rpll_inst/CLKOUT}] -divide_by 4 [get_pins {clkdiv_cpu/CLKOUT}]
create_generated_clock -name clk_mem -source [get_pins {pll_core/rpll_inst/CLKOUT}] -divide_by 2 [get_pins {clkdiv_mem/CLKOUT}]

set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {clk_pix clk_5x}] -group [get_clocks {clk_fast clk_cpu clk_mem}]

report_timing -setup -from_clock [get_clocks {clk_cpu}] -to_clock [get_clocks {clk_cpu}] -max_paths 30
report_timing -setup -from_clock [get_clocks {clk_cpu}] -to_clock [get_clocks {clk_mem}] -max_paths 20
report_timing -setup -from_clock [get_clocks {clk_mem}] -to_clock [get_clocks {clk_cpu}] -max_paths 20
report_timing -setup -from_clock [get_clocks {clk_pix}] -to_clock [get_clocks {clk_pix}] -max_paths 20
