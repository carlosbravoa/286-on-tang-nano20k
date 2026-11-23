// Serial output with a 1024-byte queue (what does not fit is dropped): the BIOS' text, for
// bring-up, on the board's USB serial port.
`timescale 1ns/1ps
module uart_tx_fifo #(parameter int CLK_HZ = 25_312_500, parameter int BAUD = 115200) (
    input  logic       clk,
    input  logic       reset,
    input  logic       wr,
    input  logic [7:0] data,
    output logic       tx
);
    localparam int DIV = CLK_HZ / BAUD;
    logic [7:0]  mem [0:1023];
    logic [10:0] wp_q, rp_q;
    logic [7:0]  rd_q;
    logic [9:0]  sh_q;
    logic [3:0]  bits_q;
    logic [15:0] cnt_q;
    logic [1:0]  st_q;                  // 0 idle, 1 read the queue, 2 load, 3 send
    wire full = (wp_q ^ rp_q) == 11'h400;
    always_ff @(posedge clk) begin
        if (wr && !full) begin mem[wp_q[9:0]] <= data; wp_q <= wp_q + 11'd1; end
        rd_q <= mem[rp_q[9:0]];
        case (st_q)
            2'd0: if (wp_q != rp_q) st_q <= 2'd1;
            2'd1: st_q <= 2'd2;
            2'd2: begin sh_q <= {1'b1, rd_q, 1'b0}; bits_q <= 4'd10; cnt_q <= 16'(DIV - 1); rp_q <= rp_q + 11'd1; st_q <= 2'd3; end
            default: if (cnt_q == 0) begin
                         cnt_q <= 16'(DIV - 1); sh_q <= {1'b1, sh_q[9:1]}; bits_q <= bits_q - 4'd1;
                         if (bits_q == 4'd1) st_q <= 2'd0;
                     end else cnt_q <= cnt_q - 16'd1;
        endcase
        if (reset) begin wp_q <= '0; rp_q <= '0; st_q <= 2'd0; sh_q <= 10'h3FF; end
    end
    assign tx = st_q == 2'd3 ? sh_q[0] : 1'b1;
endmodule
