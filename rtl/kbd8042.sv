// The keyboard controller as software sees it (ports 60h and 64h), without the 8042:
// scancodes arrive already in set 1. Commands that matter are answered: self test, A20
// through the output port, CPU reset, and the keyboard's own commands (acknowledged).
`timescale 1ns/1ps
module kbd8042 (
    input  logic       clk,
    input  logic       reset,
    input  logic       a2,          // 0 = port 60h, 1 = port 64h
    input  logic       wr,
    input  logic       rd,
    input  logic [7:0] wdata,
    output logic [7:0] rdata,
    input  logic       sc_valid,    // scancode stream
    input  logic [7:0] sc_data,
    output logic       sc_ready,
    output logic       irq1,
    output logic       a20_set,     // one cycle: write a20_value to the A20 gate
    output logic       a20_value,
    input  logic       a20_now,
    output logic       cpu_reset_req
);
    logic [7:0] out_q, cmd_byte_q;
    logic       obf_q, disabled_q;
    logic [1:0] expect_q;           // data byte expected at port 60h: 1 = command byte, 2 = output port
    logic [1:0] reply_n_q;          // replies waiting (keyboard commands)
    logic [7:0] reply_q, reply2_q;

    assign rdata = a2 ? {3'b000, 1'b1, 1'b0, 1'b1, 1'b0, obf_q} : out_q;
    assign irq1  = obf_q && cmd_byte_q[0];
    assign sc_ready = !obf_q && reply_n_q == 0 && !disabled_q && !(rd && !a2);

    always_ff @(posedge clk) begin
        a20_set <= 1'b0; cpu_reset_req <= 1'b0;
        if (rd && !a2) obf_q <= 1'b0;
        else if (!obf_q) begin
            if (reply_n_q != 0) begin
                out_q <= reply_q; reply_q <= reply2_q; reply_n_q <= reply_n_q - 2'd1; obf_q <= 1'b1;
            end else if (sc_valid && !disabled_q) begin out_q <= sc_data; obf_q <= 1'b1; end
        end
        if (wr && a2) begin
            expect_q <= 2'd0;
            casez (wdata)
                8'h20: begin reply_q <= cmd_byte_q; reply_n_q <= 2'd1; end
                8'h60: expect_q <= 2'd1;
                8'hAA: begin reply_q <= 8'h55; reply_n_q <= 2'd1; end
                8'hAB: begin reply_q <= 8'h00; reply_n_q <= 2'd1; end
                8'hAD: disabled_q <= 1'b1;
                8'hAE: disabled_q <= 1'b0;
                8'hD0: begin reply_q <= {6'b110111, a20_now, 1'b1}; reply_n_q <= 2'd1; end
                8'hD1: expect_q <= 2'd2;
                8'b1111_???0: cpu_reset_req <= 1'b1;     // pulse the reset line
                default: ;
            endcase
        end
        if (wr && !a2) begin
            expect_q <= 2'd0;
            if (expect_q == 2'd1) cmd_byte_q <= wdata;
            else if (expect_q == 2'd2) begin
                a20_set <= 1'b1; a20_value <= wdata[1];
                if (!wdata[0]) cpu_reset_req <= 1'b1;
            end else begin                               // a command for the keyboard itself
                reply_q <= 8'hFA; reply2_q <= 8'hAA;
                reply_n_q <= wdata == 8'hFF ? 2'd2 : 2'd1;
                if (wdata == 8'hEE) reply_q <= 8'hEE;
            end
        end
        if (reset) begin
            obf_q <= 1'b0; disabled_q <= 1'b0; expect_q <= 2'd0; reply_n_q <= 2'd0;
            cmd_byte_q <= 8'h45; out_q <= 8'h00; a20_value <= 1'b0;
        end
    end
endmodule
