// The four colour planes of the EGA/VGA 16-colour modes, as the CPU sees them at A0000h.
// The four bytes that belong to one address are kept as one 32-bit word of SDRAM (byte n =
// plane n), so a CPU read is one SDRAM read (it fills the four latches) and a CPU write is one
// SDRAM write, with the planes chosen by the write mask.
//   3C4h/3C5h  sequencer: register 2 = planes that are written
//   3CEh/3CFh  graphics controller: 0 set/reset, 1 enable set/reset, 2 colour compare,
//              3 function (bits 4-3; rotate is not there), 4 plane that is read, 5 mode
//              (bits 1-0 write mode, bit 3 read mode), 7 colour don't care, 8 bit mask
// A 16-bit access is done as two byte accesses, low address first.
`timescale 1ns/1ps
module ega_planes (
    input  logic        clk,
    input  logic        reset,
    input  logic        sel_seq, sel_gc, a0, wr,
    input  logic [7:0]  io_wdata,
    output logic [7:0]  io_rdata,
    // CPU
    input  logic        req,            // held until ack
    input  logic        we,
    input  logic [15:0] addr,           // even
    input  logic [1:0]  be,
    input  logic [15:0] wdata,
    output logic [15:0] rdata,
    output logic        ack,
    // SDRAM, through the bridge: one 32-bit word
    output logic        px_req,
    output logic        px_we,
    output logic [15:0] px_addr,
    output logic [31:0] px_wdata,
    output logic [3:0]  px_wmask,
    input  logic [31:0] px_rdata,
    input  logic        px_ack
);
    logic [2:0] seq_idx_q;
    logic [3:0] gc_idx_q, mask_q, sr_q, esr_q, cc_q, cdc_q;
    logic [1:0] func_q, rmap_q, wmode_q;
    logic       rmode_q;
    logic [7:0] bit_q;
    logic [31:0] latch_q;
    logic       hi_q, busy_q;

    always_comb case ({sel_gc, a0})
        2'b00: io_rdata = {5'b0, seq_idx_q};
        2'b01: io_rdata = seq_idx_q == 3'd2 ? {4'b0, mask_q} : 8'h00;
        2'b10: io_rdata = {4'b0, gc_idx_q};
        default: case (gc_idx_q)
            4'd0: io_rdata = {4'b0, sr_q};
            4'd1: io_rdata = {4'b0, esr_q};
            4'd2: io_rdata = {4'b0, cc_q};
            4'd3: io_rdata = {3'b0, func_q, 3'b0};
            4'd4: io_rdata = {6'b0, rmap_q};
            4'd5: io_rdata = {4'b0, rmode_q, 1'b0, wmode_q};
            4'd7: io_rdata = {4'b0, cdc_q};
            4'd8: io_rdata = bit_q;
            default: io_rdata = 8'h00;
        endcase
    endcase

    // ── what a write puts into each plane ──
    wire [7:0] cpu_byte = hi_q ? wdata[15:8] : wdata[7:0];
    always_comb for (int p = 0; p < 4; p++) begin
        logic [7:0] l, d, f, m;
        l = latch_q[p*8 +: 8];
        d = wmode_q == 2'd2 ? {8{cpu_byte[p]}} : (wmode_q == 2'd3 || esr_q[p]) ? {8{sr_q[p]}} : cpu_byte;
        case (wmode_q == 2'd3 ? 2'd0 : func_q)
            2'd1: f = d & l;
            2'd2: f = d | l;
            2'd3: f = d ^ l;
            default: f = d;
        endcase
        m = wmode_q == 2'd3 ? bit_q & cpu_byte : bit_q;
        px_wdata[p*8 +: 8] = wmode_q == 2'd1 ? l : (f & m) | (l & ~m);
    end
    assign px_wmask = mask_q;
    assign px_we    = we;
    assign px_addr  = {addr[15:1], hi_q};

    // ── what a read gives: one plane, or where the colour is the one looked for ──
    logic [7:0] same, rd_byte;
    always_comb begin
        same = 8'hFF;
        for (int p = 0; p < 4; p++) if (cdc_q[p]) same &= ~(px_rdata[p*8 +: 8] ^ {8{cc_q[p]}});
        rd_byte = rmode_q ? same : px_rdata[rmap_q*8 +: 8];
    end

    always_ff @(posedge clk) begin
        ack <= 1'b0;
        if (req && !ack && !busy_q) begin                // start: the low byte, if it is asked for
            busy_q <= 1'b1; hi_q <= !be[0]; px_req <= 1'b1;
        end
        if (px_req && px_ack) begin
            px_req <= 1'b0;
            if (!we) begin
                latch_q <= px_rdata;
                if (hi_q) rdata[15:8] <= rd_byte; else rdata[7:0] <= rd_byte;
            end
            if (!hi_q && be[1]) hi_q <= 1'b1;            // then the high byte
            else begin ack <= 1'b1; busy_q <= 1'b0; end
        end
        if (busy_q && !px_req && !ack && !(px_ack)) px_req <= 1'b1;   // the second byte's access
        if (wr && sel_seq) begin
            if (!a0) seq_idx_q <= io_wdata[2:0];
            else if (seq_idx_q == 3'd2) mask_q <= io_wdata[3:0];
        end
        if (wr && sel_gc) begin
            if (!a0) gc_idx_q <= io_wdata[3:0];
            else case (gc_idx_q)
                4'd0: sr_q <= io_wdata[3:0];
                4'd1: esr_q <= io_wdata[3:0];
                4'd2: cc_q <= io_wdata[3:0];
                4'd3: func_q <= io_wdata[4:3];
                4'd4: rmap_q <= io_wdata[1:0];
                4'd5: begin wmode_q <= io_wdata[1:0]; rmode_q <= io_wdata[3]; end
                4'd7: cdc_q <= io_wdata[3:0];
                4'd8: bit_q <= io_wdata;
                default: ;
            endcase
        end
        if (reset) begin
            px_req <= 1'b0; busy_q <= 1'b0; ack <= 1'b0; hi_q <= 1'b0;
            mask_q <= 4'hF; sr_q <= '0; esr_q <= '0; cc_q <= '0; cdc_q <= 4'hF;
            func_q <= '0; rmap_q <= '0; wmode_q <= '0; rmode_q <= 1'b0; bit_q <= 8'hFF;
        end
    end
endmodule
