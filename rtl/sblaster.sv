// A small Sound Blaster (it says version 2.0): 8-bit sound, played by direct writes or through
// DMA channel 1, with an interrupt at the end of each block. With it comes the one channel of
// the DMA controller it needs. No recording, no MIDI, no compressed sound.
//
//   226h  W  DSP reset                    22Ah  R  DSP data
//   22Ch  W  DSP command / data           22Ch  R  bit 7 = 0: ready for a command
//   22Eh  R  bit 7 = data to read; reading it also takes back the interrupt
//   DSP commands: 10 direct sample, 14/91 play a block, 1C/90 play blocks one after another,
//   40 rate, 48 block size, D0 pause, D4 go on, D1/D3 speaker on/off, D8 speaker state,
//   DA/D9 stop after this block, E0 identify, E1 version, E4/E8 test byte, F2 interrupt now
//   DMA: 002h address, 003h count (channel 1), 008h status, 00Ah mask, 00Bh mode,
//   00Ch low/high byte pointer, 00Dh reset, 083h page
`timescale 1ns/1ps
module sblaster #(parameter int CLK_HZ = 25_312_500) (
    input  logic        clk,
    input  logic        reset,
    // I/O: one of the selects with wr or rd, for one clock
    input  logic        sel_dsp,        // 220h-22Fh
    input  logic        sel_dma,        // 000h-00Fh
    input  logic        sel_page,       // 083h
    input  logic [3:0]  a,
    input  logic        wr, rd,
    input  logic [7:0]  wdata,
    output logic [7:0]  rdata,
    output logic        irq,
    // a byte of RAM for the sound
    output logic        dm_req,
    output logic [22:0] dm_addr,
    input  logic [7:0]  dm_rdata,
    input  logic        dm_ack,
    output logic [7:0]  dac             // unsigned, 80h = silence
);
    // ── DMA channel 1 ──
    logic [15:0] base_a_q, base_n_q, cur_a_q, cur_n_q;
    logic [6:0]  page_q;
    logic        ff_q, masked_q, auto_q, tc_q;
    // ── DSP ──
    logic [7:0]  cmd_q, p0_q, out_q, out2_q, test_q, tc_rate_q;
    logic [1:0]  need_q, have_q, out_n_q;     // parameter bytes wanted / got; bytes to read
    logic [15:0] len_q, blk_q;
    logic        play_q, loop_q, pause_q, spk_q, last_q, rst_q;
    // sample clock: a 1 MHz tick, then (256 - rate) of them a sample
    localparam int INC = int'(1000000.0 * 65536.0 / CLK_HZ + 0.5);
    logic [15:0] ph_q;
    logic        us_q;
    logic [7:0]  div_q;
    logic        want_q;                // a sample is due

    function automatic logic [1:0] params(input logic [7:0] c);
        case (c)
            8'h10, 8'h40, 8'hE0, 8'hE4: return 2'd1;
            8'h14, 8'h48, 8'h91: return 2'd2;
            default: return 2'd0;
        endcase
    endfunction

    assign dm_addr = {page_q, cur_a_q};
    assign rdata = sel_page ? {1'b0, page_q}
                 : sel_dma  ? (a == 4'h8 ? {7'b0, tc_q, 1'b0}
                              : a == 4'h2 ? (ff_q ? cur_a_q[15:8] : cur_a_q[7:0])
                              : a == 4'h3 ? (ff_q ? cur_n_q[15:8] : cur_n_q[7:0]) : 8'h00)
                 : a == 4'hA ? out_q
                 : a == 4'hE ? {out_n_q != 0, 7'h7F}
                 : a == 4'hC ? 8'h7F : 8'hFF;

    wire dsp_wr   = sel_dsp && wr && a == 4'hC;
    wire run_cmd  = dsp_wr && (need_q == 0 ? params(wdata) == 0 : have_q + 2'd1 == need_q);
    wire [7:0]  c  = need_q == 0 ? wdata : cmd_q;      // the command that is complete now
    wire [15:0] w2 = {wdata, p0_q};                     // its two parameter bytes
    wire running  = play_q && !pause_q && !masked_q;

    always_ff @(posedge clk) begin
        {us_q, ph_q} <= {1'b0, ph_q} + 17'(INC);
        if (us_q) begin
            div_q <= div_q + 8'd1;
            if (div_q == 8'hFF) begin div_q <= tc_rate_q; want_q <= 1'b1; end
        end
        // ── play: a byte from RAM for every sample ──
        if (want_q && running && !dm_req) begin dm_req <= 1'b1; want_q <= 1'b0; end
        if (!running) want_q <= 1'b0;
        if (dm_req && dm_ack) begin
            dm_req <= 1'b0;
            dac <= dm_rdata;
            cur_a_q <= cur_a_q + 16'd1; cur_n_q <= cur_n_q - 16'd1;
            if (cur_n_q == 0) begin                      // the DMA count has run out
                tc_q <= 1'b1;
                if (auto_q) begin cur_a_q <= base_a_q; cur_n_q <= base_n_q; end
                else masked_q <= 1'b1;
            end
            len_q <= len_q - 16'd1;
            if (len_q == 0) begin                        // the block is done
                irq <= 1'b1;
                if (loop_q && !last_q) len_q <= blk_q;
                else play_q <= 1'b0;
            end
        end
        // ── DMA registers ──
        if (sel_page && wr) page_q <= wdata[6:0];
        if (sel_dma && (wr || rd) && (a == 4'h2 || a == 4'h3)) ff_q <= !ff_q;
        if (sel_dma && rd && a == 4'h8) tc_q <= 1'b0;
        if (sel_dma && wr) case (a)
            4'h2: if (ff_q) begin base_a_q[15:8] <= wdata; cur_a_q[15:8] <= wdata; end
                  else      begin base_a_q[7:0]  <= wdata; cur_a_q[7:0]  <= wdata; end
            4'h3: if (ff_q) begin base_n_q[15:8] <= wdata; cur_n_q[15:8] <= wdata; end
                  else      begin base_n_q[7:0]  <= wdata; cur_n_q[7:0]  <= wdata; end
            4'hA: if (wdata[1:0] == 2'd1) masked_q <= wdata[2];
            4'hB: if (wdata[1:0] == 2'd1) auto_q <= wdata[4];
            4'hC: ff_q <= 1'b0;
            4'hD: begin ff_q <= 1'b0; masked_q <= 1'b1; end
            default: ;
        endcase
        // ── DSP ──
        if (sel_dsp && rd && a == 4'hA && out_n_q != 0) begin out_q <= out2_q; out_n_q <= out_n_q - 2'd1; end
        if (sel_dsp && rd && a == 4'hE) irq <= 1'b0;
        if (sel_dsp && wr && a == 4'h6) begin
            rst_q <= wdata[0];
            if (rst_q && !wdata[0]) begin                // reset done: answer AAh
                out_q <= 8'hAA; out_n_q <= 2'd1;
                need_q <= 2'd0; have_q <= 2'd0; play_q <= 1'b0; pause_q <= 1'b0; spk_q <= 1'b0;
                irq <= 1'b0; dac <= 8'h80; dm_req <= 1'b0;
            end
        end
        if (dsp_wr) begin
            if (need_q == 0) begin cmd_q <= wdata; need_q <= params(wdata); have_q <= 2'd0; end
            else begin p0_q <= wdata; have_q <= have_q + 2'd1; end
            if (run_cmd) begin
                need_q <= 2'd0;
                case (c)
                    8'h10: dac <= wdata;
                    8'h14, 8'h91: begin len_q <= w2; play_q <= 1'b1; loop_q <= 1'b0; last_q <= 1'b0; pause_q <= 1'b0; end
                    8'h1C, 8'h90: begin len_q <= blk_q; play_q <= 1'b1; loop_q <= 1'b1; last_q <= 1'b0; pause_q <= 1'b0; end
                    8'h40: tc_rate_q <= wdata;
                    8'h48: blk_q <= w2;
                    8'hD0: pause_q <= 1'b1;
                    8'hD4: pause_q <= 1'b0;
                    8'hD1: spk_q <= 1'b1;
                    8'hD3: spk_q <= 1'b0;
                    8'hD8: begin out_q <= {8{spk_q}}; out_n_q <= 2'd1; end
                    8'hD9, 8'hDA: last_q <= 1'b1;
                    8'hE0: begin out_q <= ~wdata; out_n_q <= 2'd1; end
                    8'hE1: begin out_q <= 8'h02; out2_q <= 8'h01; out_n_q <= 2'd2; end
                    8'hE4: test_q <= wdata;
                    8'hE8: begin out_q <= test_q; out_n_q <= 2'd1; end
                    8'hF2: irq <= 1'b1;
                    default: ;
                endcase
            end
        end
        if (reset) begin
            ff_q <= 1'b0; masked_q <= 1'b1; auto_q <= 1'b0; tc_q <= 1'b0; page_q <= '0;
            need_q <= 2'd0; have_q <= 2'd0; out_n_q <= 2'd0; play_q <= 1'b0; pause_q <= 1'b0;
            loop_q <= 1'b0; last_q <= 1'b0; spk_q <= 1'b0; rst_q <= 1'b0; irq <= 1'b0;
            dm_req <= 1'b0; want_q <= 1'b0; dac <= 8'h80; tc_rate_q <= 8'd156;
        end
    end
endmodule
