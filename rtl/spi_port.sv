// A byte-wide SPI master (mode 0) on two I/O ports, for the SD card.
//   data port: write = send the byte; read = the byte received with the last one sent.
//              With AUTO set, a read also sends FFh, so "rep insb" reads a block.
//   control port: bit 0 chip select (1 = selected), bit 1 slow clock (for card start-up),
//              bit 2 AUTO; reads back the same, bit 7 = busy.
// The CPU waits (io_wait) when it touches the data port during a transfer.
`timescale 1ns/1ps
module spi_port #(parameter int FAST_DIV = 2, parameter int SLOW_DIV = 32) (  // half periods, in clocks
    input  logic       clk,
    input  logic       reset,
    input  logic       a0,          // 0 = data, 1 = control
    input  logic       sel,         // the CPU addresses this block (for io_wait)
    input  logic       wr,
    input  logic       rd,
    input  logic [7:0] wdata,
    output logic [7:0] rdata,
    output logic       io_wait,
    output logic       sck,
    output logic       mosi,
    input  logic       miso,
    output logic       cs_n
);
    logic [7:0] sh_q, rx_q;
    logic [3:0] bit_q;              // 8 while idle
    logic [5:0] div_q;
    logic       cs_q, slow_q, auto_q, miso_q;
    wire busy = bit_q != 4'd8;
    wire [5:0] half = slow_q ? 6'(SLOW_DIV - 1) : 6'(FAST_DIV - 1);

    assign io_wait = sel && !a0 && busy;
    assign rdata   = a0 ? {busy, 4'b0, auto_q, slow_q, cs_q} : rx_q;
    assign cs_n    = !cs_q;
    assign mosi    = sh_q[7];

    always_ff @(posedge clk) begin
        miso_q <= miso;
        if (busy) begin
            if (div_q == half) begin
                div_q <= '0;
                if (!sck) sck <= 1'b1;                   // rising edge: the card's bit is sampled below
                else begin
                    sck <= 1'b0;
                    sh_q <= {sh_q[6:0], miso_q};
                    bit_q <= bit_q + 4'd1;
                    if (bit_q == 4'd7) rx_q <= {sh_q[6:0], miso_q};
                end
            end else div_q <= div_q + 6'd1;
        end else if (!a0 && (wr || (rd && auto_q))) begin
            sh_q <= wr ? wdata : 8'hFF; bit_q <= 4'd0; div_q <= '0;
        end
        if (wr && a0) begin cs_q <= wdata[0]; slow_q <= wdata[1]; auto_q <= wdata[2]; end
        if (reset) begin
            bit_q <= 4'd8; sck <= 1'b0; cs_q <= 1'b0; slow_q <= 1'b1; auto_q <= 1'b0;
            sh_q <= 8'hFF; rx_q <= 8'hFF; div_q <= '0;
        end
    end
endmodule
