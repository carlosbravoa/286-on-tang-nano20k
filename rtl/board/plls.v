// The two PLLs of the Tang Nano 20K (GW2AR-18), both from the 27 MHz oscillator.
//   rpll_hdmi: 126 MHz = 27 * 14 / 3, five times the 25.2 MHz pixel clock (640x480 at 60 Hz)
//   rpll_core: 101.25 MHz = 27 * 15 / 4; divided by 4 it is the CPU clock (25.3125 MHz),
//              divided by 2 the SDRAM clock (50.625 MHz)
module rpll_hdmi (input wire clk_in, output wire clk_out, output wire locked);
    wire gnd = 1'b0;
    wire clkoutp_nc, clkoutd_nc, clkoutd3_nc;
    rPLL rpll_inst (
        .CLKIN(clk_in), .CLKFB(gnd), .RESET(gnd), .RESET_P(gnd),
        .FBDSEL({6{gnd}}), .IDSEL({6{gnd}}), .ODSEL({6{gnd}}),
        .PSDA({4{gnd}}), .DUTYDA({4{gnd}}), .FDLY({4{gnd}}),
        .LOCK(locked), .CLKOUT(clk_out), .CLKOUTP(clkoutp_nc), .CLKOUTD(clkoutd_nc), .CLKOUTD3(clkoutd3_nc));
    defparam rpll_inst.FCLKIN = "27";
    defparam rpll_inst.DYN_IDIV_SEL = "false";
    defparam rpll_inst.IDIV_SEL = 2;
    defparam rpll_inst.DYN_FBDIV_SEL = "false";
    defparam rpll_inst.FBDIV_SEL = 13;
    defparam rpll_inst.DYN_ODIV_SEL = "false";
    defparam rpll_inst.ODIV_SEL = 8;            // VCO 1008 MHz
    defparam rpll_inst.PSDA_SEL = "0000";
    defparam rpll_inst.DYN_DA_EN = "true";
    defparam rpll_inst.DUTYDA_SEL = "1000";
    defparam rpll_inst.CLKOUT_FT_DIR = 1'b1;
    defparam rpll_inst.CLKOUTP_FT_DIR = 1'b1;
    defparam rpll_inst.CLKOUT_DLY_STEP = 0;
    defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
    defparam rpll_inst.CLKFB_SEL = "internal";
    defparam rpll_inst.CLKOUT_BYPASS = "false";
    defparam rpll_inst.CLKOUTP_BYPASS = "false";
    defparam rpll_inst.CLKOUTD_BYPASS = "false";
    defparam rpll_inst.DYN_SDIV_SEL = 2;
    defparam rpll_inst.CLKOUTD_SRC = "CLKOUT";
    defparam rpll_inst.CLKOUTD3_SRC = "CLKOUT";
    defparam rpll_inst.DEVICE = "GW2AR-18C";
endmodule

module rpll_core (input wire clk_in, output wire clk_out, output wire locked);
    wire gnd = 1'b0;
    wire clkoutp_nc, clkoutd_nc, clkoutd3_nc;
    rPLL rpll_inst (
        .CLKIN(clk_in), .CLKFB(gnd), .RESET(gnd), .RESET_P(gnd),
        .FBDSEL({6{gnd}}), .IDSEL({6{gnd}}), .ODSEL({6{gnd}}),
        .PSDA({4{gnd}}), .DUTYDA({4{gnd}}), .FDLY({4{gnd}}),
        .LOCK(locked), .CLKOUT(clk_out), .CLKOUTP(clkoutp_nc), .CLKOUTD(clkoutd_nc), .CLKOUTD3(clkoutd3_nc));
    defparam rpll_inst.FCLKIN = "27";
    defparam rpll_inst.DYN_IDIV_SEL = "false";
    defparam rpll_inst.IDIV_SEL = 3;
    defparam rpll_inst.DYN_FBDIV_SEL = "false";
    defparam rpll_inst.FBDIV_SEL = 14;
    defparam rpll_inst.DYN_ODIV_SEL = "false";
    defparam rpll_inst.ODIV_SEL = 8;            // VCO 810 MHz
    defparam rpll_inst.PSDA_SEL = "0000";
    defparam rpll_inst.DYN_DA_EN = "true";
    defparam rpll_inst.DUTYDA_SEL = "1000";
    defparam rpll_inst.CLKOUT_FT_DIR = 1'b1;
    defparam rpll_inst.CLKOUTP_FT_DIR = 1'b1;
    defparam rpll_inst.CLKOUT_DLY_STEP = 0;
    defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
    defparam rpll_inst.CLKFB_SEL = "internal";
    defparam rpll_inst.CLKOUT_BYPASS = "false";
    defparam rpll_inst.CLKOUTP_BYPASS = "false";
    defparam rpll_inst.CLKOUTD_BYPASS = "false";
    defparam rpll_inst.DYN_SDIV_SEL = 2;
    defparam rpll_inst.CLKOUTD_SRC = "CLKOUT";
    defparam rpll_inst.CLKOUTD3_SRC = "CLKOUT";
    defparam rpll_inst.DEVICE = "GW2AR-18C";
endmodule
