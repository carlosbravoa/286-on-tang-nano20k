// 8254 timer: channel 0 (IRQ0) and channel 2 (speaker). Channel 1 (memory refresh on a real
// PC) is not there; port 61h bit 4 gives the toggling refresh bit instead.
// Modes 0, 2 and 3 are exact enough for PC software; modes 1, 4, 5 count like mode 0.
`timescale 1ns/1ps
module pit_channel (
    input  logic       clk,
    input  logic       reset,
    input  logic       tick,        // 1.193182 MHz enable
    input  logic       gate,
    input  logic       ctrl_wr,     // control word for this channel
    input  logic       cnt_wr,
    input  logic       cnt_rd,
    input  logic [7:0] wdata,
    output logic [7:0] rdata,
    output logic       out
);
    logic [15:0] count_q, reload_q, latch_q;
    logic [2:0]  mode_q;
    logic [1:0]  rw_q;
    logic        latched_q, wr_hi_q, rd_hi_q, load_q, run_q, gate_d;

    wire m2 = mode_q[1:0] == 2'd2, m3 = mode_q[1:0] == 2'd3;
    wire [15:0] rd_word = latched_q ? latch_q : count_q;
    wire rd_high = rw_q == 2'd2 || (rw_q == 2'd3 && rd_hi_q);
    assign rdata = rd_high ? rd_word[15:8] : rd_word[7:0];
    wire [15:0] start = m3 ? {reload_q[15:1], 1'b0} : reload_q;

    always_ff @(posedge clk) begin
        gate_d <= gate;
        if (tick) begin
            if (load_q) begin
                count_q <= start; load_q <= 1'b0; run_q <= 1'b1;
            end else if (run_q && gate) begin
                if (m2) begin
                    if (count_q == 16'd2) begin out <= 1'b0; count_q <= 16'd1; end
                    else if (count_q == 16'd1) begin out <= 1'b1; count_q <= reload_q; end
                    else count_q <= count_q - 16'd1;
                end else if (m3) begin
                    if (count_q == 16'd2) begin out <= ~out; count_q <= start; end
                    else count_q <= count_q - 16'd2;
                end else begin
                    count_q <= count_q - 16'd1;
                    if (count_q == 16'd1) out <= 1'b1;
                end
            end
        end
        if ((m2 || m3) && !gate) out <= 1'b1;
        if ((m2 || m3) && gate && !gate_d) load_q <= 1'b1;

        if (ctrl_wr) begin
            if (wdata[5:4] == 2'd0) begin               // latch command
                if (!latched_q) begin latch_q <= count_q; latched_q <= 1'b1; end
            end else begin
                rw_q <= wdata[5:4]; mode_q <= wdata[3:1];
                wr_hi_q <= 1'b0; rd_hi_q <= 1'b0; latched_q <= 1'b0;
                run_q <= 1'b0; load_q <= 1'b0;
                out <= wdata[3:1] != 3'd0;
            end
        end
        if (cnt_wr) begin
            if (rw_q == 2'd3 && !wr_hi_q) begin reload_q[7:0] <= wdata; wr_hi_q <= 1'b1; end
            else begin
                if (rw_q == 2'd1) reload_q <= {8'h00, wdata};
                else if (rw_q == 2'd2) reload_q <= {wdata, 8'h00};
                else reload_q[15:8] <= wdata;
                wr_hi_q <= 1'b0;
                if (!(m2 || m3) || !run_q) load_q <= 1'b1;   // modes 2/3 take it at the next reload
                if (!(m2 || m3)) out <= 1'b0;
            end
        end
        if (cnt_rd) begin
            if (rw_q == 2'd3 && !rd_hi_q) rd_hi_q <= 1'b1;
            else begin rd_hi_q <= 1'b0; latched_q <= 1'b0; end
        end
        if (reset) begin
            count_q <= 16'd0; reload_q <= 16'd0; mode_q <= 3'd3; rw_q <= 2'd3;
            latched_q <= 1'b0; wr_hi_q <= 1'b0; rd_hi_q <= 1'b0; load_q <= 1'b0; run_q <= 1'b0;
            out <= 1'b1; gate_d <= 1'b0;
        end
    end
endmodule

module pit8254 #(parameter int CLK_HZ = 25_312_500) (
    input  logic       clk,
    input  logic       reset,
    input  logic [1:0] addr,
    input  logic       wr,
    input  logic       rd,
    input  logic [7:0] wdata,
    output logic [7:0] rdata,
    input  logic       gate2,
    output logic       out0,
    output logic       out2,
    output logic       refresh_toggle   // port 61h bit 4, changes every 15 us
);
    localparam int PIT_HZ = 1_193_182;
    logic [25:0] acc_q;
    logic        tick;
    logic [3:0]  ref_q;
    always_ff @(posedge clk) begin
        tick <= 1'b0;
        if (acc_q + 26'(PIT_HZ) >= 26'(CLK_HZ)) begin acc_q <= acc_q + 26'(PIT_HZ) - 26'(CLK_HZ); tick <= 1'b1; end
        else acc_q <= acc_q + 26'(PIT_HZ);
        if (tick) begin
            ref_q <= ref_q == 4'd8 ? 4'd0 : ref_q + 4'd1;
            if (ref_q == 4'd8) refresh_toggle <= ~refresh_toggle;
        end
        if (reset) begin acc_q <= '0; ref_q <= '0; refresh_toggle <= 1'b0; end
    end

    wire ctrl = wr && addr == 2'd3;
    logic [7:0] r0, r2;
    pit_channel ch0 (.clk, .reset, .tick, .gate(1'b1),
        .ctrl_wr(ctrl && wdata[7:6] == 2'd0), .cnt_wr(wr && addr == 2'd0), .cnt_rd(rd && addr == 2'd0),
        .wdata, .rdata(r0), .out(out0));
    pit_channel ch2 (.clk, .reset, .tick, .gate(gate2),
        .ctrl_wr(ctrl && wdata[7:6] == 2'd2), .cnt_wr(wr && addr == 2'd2), .cnt_rd(rd && addr == 2'd2),
        .wdata, .rdata(r2), .out(out2));
    assign rdata = addr == 2'd0 ? r0 : addr == 2'd2 ? r2 : 8'hFF;
endmodule
