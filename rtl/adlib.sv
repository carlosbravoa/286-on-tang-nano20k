// AdLib: a YM3812 (OPL2) at ports 388h (register number; status when read) and 389h (data).
// The chip is JTOPL (rtl/jtopl, GPL-3.0), clocked at 3.58 MHz by a fractional clock enable.
`timescale 1ns/1ps
module adlib #(parameter int CLK_HZ = 25_312_500) (
    input  logic        clk,
    input  logic        reset,
    input  logic        wr,             // write to 388h (a0 = 0) or 389h (a0 = 1)
    input  logic        a0,
    input  logic [7:0]  wdata,
    output logic [7:0]  status,
    output logic signed [15:0] snd,
    output logic        sample          // snd has a new value
);
    // 3.579545 MHz from the CPU clock: a 16-bit phase counter that overflows that often
    localparam int INC = int'(3579545.0 * 65536.0 / CLK_HZ + 0.5);
    logic [15:0] phase_q;
    logic        cen_q, wr_q, a0_q;
    logic [7:0]  data_q;
    logic [3:0]  rst_q = 4'hF;          // the chip wants a reset some of its clocks long
    always_ff @(posedge clk) begin
        {cen_q, phase_q} <= {1'b0, phase_q} + 17'(INC);
        wr_q <= wr; a0_q <= a0; data_q <= wdata;
        if (reset) rst_q <= 4'hF;
        else if (cen_q && rst_q != 0) rst_q <= rst_q - 4'd1;
    end
    wire irq_n;
    jtopl2 opl (.rst(rst_q != 0), .clk(clk), .cen(cen_q), .din(data_q), .addr(a0_q),
                .cs_n(!wr_q), .wr_n(!wr_q), .dout(status), .irq_n(irq_n), .snd(snd), .sample(sample));
endmodule
