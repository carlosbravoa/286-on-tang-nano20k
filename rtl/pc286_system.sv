// The whole machine without the board's clocks and pins: the core, text video, the bridge
// to the SDRAM controller and the debug serial output.
`timescale 1ns/1ps
module pc286_system #(
    parameter int CLK_HZ = 25_312_500,
    parameter BIOS_HEX = "build/bios16.hex",
    parameter HID_TABLE = "build/hid_table.hex",
    parameter FONT_HEX = "fonts/vga8x16.hex",
    parameter int LINES = 525           // raster: 525 (640x480 at 60 Hz) or 449 (640x400 at 70 Hz)
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
    output logic        dbg_tx,         // serial: the BIOS' text and the monitor's answers
    input  logic        mon_rx,         // serial: commands for the monitor (rtl/monitor.sv)
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
    logic [9:0]  crtc_lc;
    logic [7:0]  crtc_off;
    logic [22:0] vf_addr;
    logic [127:0] vf_rdata;
    logic [5:0]  cursor_start;
    logic [4:0]  cursor_end;
    logic [7:0]  vid_mode, vid_color, vid_ctrl, dbg_char, vio_wdata, vio_rdata;
    logic [3:0]  vio_addr;
    logic        vio_wr, vio_rd;
    logic        dm_req, dm_ack, attr_reset, px_req, px_we, px_ack;
    logic [15:0] px_addr;
    logic [31:0] px_wdata, px_rdata;
    logic [3:0]  px_wmask;
    logic [22:0] dm_addr;
    logic [7:0]  dm_rdata;
    // the monitor: keys, mouse, a byte of RAM (it shares the Sound Blaster's port), reset
    logic        mon_sc_valid, mon_sc_ready, mon_mouse_valid, mon_tx_valid, mon_reset;
    logic [7:0]  mon_sc_data, mon_mouse_dx, mon_mouse_dy, mon_tx_data, m_wdata, dm_wdata;
    logic [2:0]  mon_mouse_btn;
    logic        m_req, m_we, m_ack, c_dm_req, dm_we, dm_busy_q, dm_mon_q, tx_full;
    logic [22:0] m_addr, c_dm_addr;
    wire         rst = reset || mon_reset;

    pc286_core #(.CLK_HZ(CLK_HZ), .BIOS_HEX(BIOS_HEX), .HID_TABLE(HID_TABLE)) core (.reset(rst),
        .dm_req(c_dm_req), .dm_addr(c_dm_addr), .dm_ack(dm_ack && !dm_mon_q), .*);

    video #(.FONT_HEX(FONT_HEX), .LINES(LINES)) video (.clk_pix, .cx, .cy, .rgb, .hsync, .vsync,
        .blank(vid_blank), .vretrace(vid_vsync), .clk, .reset(rst), .crtc_start, .crtc_lc, .crtc_off, .crtc_cursor,
        .cursor_start, .cursor_end, .vid_mode, .vid_color, .vid_ctrl, .attr_reset,
        .vio_wr, .vio_rd, .vio_addr, .vio_wdata, .vio_rdata, .vf_req, .vf_addr, .vf_rdata, .vf_ack);

    sdram_bridge bridge (.reset(rst), .*);

    // one byte port for two: whoever asks first has it until its answer
    always_ff @(posedge clk) begin
        if (!dm_busy_q) begin
            if (c_dm_req) begin dm_busy_q <= 1'b1; dm_mon_q <= 1'b0; end
            else if (m_req && !m_ack) begin dm_busy_q <= 1'b1; dm_mon_q <= 1'b1; end
        end else if (dm_ack) dm_busy_q <= 1'b0;
        if (rst) dm_busy_q <= 1'b0;
    end
    assign dm_req   = dm_busy_q && (dm_mon_q ? m_req : c_dm_req);
    assign dm_addr  = dm_mon_q ? m_addr : c_dm_addr;
    assign dm_we    = dm_mon_q && m_we;
    assign dm_wdata = m_wdata;
    assign m_ack    = dm_ack && dm_mon_q;

    monitor #(.CLK_HZ(CLK_HZ)) monitor (.clk, .reset, .rx(mon_rx),
        .tx_valid(mon_tx_valid), .tx_data(mon_tx_data), .tx_ready(!dbg_char_valid && !tx_full),
        .sc_valid(mon_sc_valid), .sc_data(mon_sc_data), .sc_ready(mon_sc_ready),
        .mouse_valid(mon_mouse_valid), .mouse_btn(mon_mouse_btn), .mouse_dx(mon_mouse_dx), .mouse_dy(mon_mouse_dy),
        .m_req, .m_we, .m_addr, .m_wdata, .m_rdata(dm_rdata), .m_ack, .machine_reset(mon_reset));

    // the text first; its bytes A0h-BFh would look like the monitor's answers
    wire [7:0] text = dbg_char[7:5] == 3'b101 ? "." : dbg_char;
    uart_tx_fifo #(.CLK_HZ(CLK_HZ)) dbg (.clk, .reset, .wr(dbg_char_valid || mon_tx_valid),
        .data(dbg_char_valid ? text : mon_tx_data), .full(tx_full), .tx(dbg_tx));
endmodule
