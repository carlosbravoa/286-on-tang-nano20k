// The whole machine without the board's clocks and pins: the core, text video, the bridge
// to the SDRAM controller and the debug serial output.
`timescale 1ns/1ps
module pc286_system #(
    parameter int CLK_HZ = 25_312_500,
    parameter BIOS_HEX = "build/bios16.hex",
    parameter HID_TABLE = "build/hid_table.hex",
    parameter FONT_HEX = "fonts/vga8x16.hex"
) (
    input  logic        clk,            // CPU clock
    input  logic        reset,
    input  logic        clk_pix,        // 25.2 MHz
    input  logic [9:0]  cx, cy,
    output logic [23:0] rgb,
    output logic        hsync, vsync,
    output logic        speaker,
    output logic signed [15:0] opl_snd, // AdLib, on the CPU clock
    output logic        opl_sample,
    input  logic        kbd_rx,
    output logic        sd_sck, sd_mosi, sd_cs_n,
    input  logic        sd_miso,
    output logic        dbg_tx,
    output logic        halted,
    // SDRAM controller
    output logic        sd_req, sd_read, sd_write, sd_burst,
    output logic [22:0] sd_addr,
    output logic [31:0] sd_wdata,
    output logic [3:0]  sd_wmask,
    input  logic [31:0] sd_rdata,
    input  logic [127:0] sd_brdata,     // the four words of a burst read
    input  logic        sd_complete,
    output logic        sd_refresh
);
    logic        mem_req, mem_fetch, mem_we, mem_ack, vf_req, vf_ack, vid_blank, vid_vsync, dbg_char_valid;
    logic [23:0] mem_addr;
    logic [1:0]  mem_be;
    logic [15:0] mem_wdata, mem_rdata, crtc_start, crtc_cursor;
    logic [22:0] vf_addr;
    logic [127:0] vf_rdata;
    logic [5:0]  cursor_start;
    logic [4:0]  cursor_end;
    logic [7:0]  vid_mode, vid_color, vid_ctrl, dbg_char, vio_wdata, vio_rdata;
    logic [3:0]  vio_addr;
    logic        vio_wr, vio_rd;

    pc286_core #(.CLK_HZ(CLK_HZ), .BIOS_HEX(BIOS_HEX), .HID_TABLE(HID_TABLE)) core (.*);

    video #(.FONT_HEX(FONT_HEX)) video (.clk_pix, .cx, .cy, .rgb, .hsync, .vsync,
        .blank(vid_blank), .vretrace(vid_vsync), .clk, .reset, .crtc_start, .crtc_cursor,
        .cursor_start, .cursor_end, .vid_mode, .vid_color, .vid_ctrl,
        .vio_wr, .vio_rd, .vio_addr, .vio_wdata, .vio_rdata, .vf_req, .vf_addr, .vf_rdata, .vf_ack);

    sdram_bridge bridge (.*);

    uart_tx_fifo #(.CLK_HZ(CLK_HZ)) dbg (.clk, .reset, .wr(dbg_char_valid), .data(dbg_char), .tx(dbg_tx));
endmodule
