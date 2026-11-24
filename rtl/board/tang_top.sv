// 286 on the Tang Nano 20K: clocks, reset, HDMI, SDRAM and pins around pc286_system.
// The clocking, the SDRAM controller and the HDMI transmitter are the ones proven on this
// board by the Atari816 project.
module tang_top (
    input  wire        sys_clk,        // 27 MHz
    input  wire [1:0]  btn,            // S1 (reset), S2: high when pressed
    output wire [3:0]  leds_n,
    output wire [2:0]  tmds_p, tmds_n,
    output wire        tmds_clk_p, tmds_clk_n,
    output wire        sd_clk, sd_mosi, sd_cs,
    input  wire        sd_miso,
    input  wire        kbd_rx,         // CH9350 (or Pico) TX: keyboard and mouse
    input  wire        bl616_uart_rx,
    output wire        bl616_uart_tx,  // BIOS text, on the USB serial port
    output wire        O_sdram_clk, O_sdram_cke, O_sdram_cs_n, O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n,
    output wire [1:0]  O_sdram_ba,
    output wire [10:0] O_sdram_addr,
    output wire [3:0]  O_sdram_dqm,
    inout  wire [31:0] IO_sdram_dq
);
    // ── clocks ──
    wire clk_5x, clk_pix, clk_fast, clk, clk_mem, hdmi_locked, core_locked;
    rpll_hdmi pll_hdmi (.clk_in(sys_clk), .clk_out(clk_5x), .locked(hdmi_locked));
    rpll_core pll_core (.clk_in(sys_clk), .clk_out(clk_fast), .locked(core_locked));

    // Both dividers must leave reset on the same clk_fast edge, or the phase between the CPU
    // clock and the SDRAM clock is a lottery at every power-on.
    reg [1:0] clkdiv_rstn_sync = 2'b00;
    always @(posedge clk_fast or negedge core_locked)
        if (!core_locked) clkdiv_rstn_sync <= 2'b00;
        else              clkdiv_rstn_sync <= {clkdiv_rstn_sync[0], 1'b1};
    CLKDIV #(.DIV_MODE("4"), .GSREN("false")) clkdiv_cpu (.CLKOUT(clk),     .HCLKIN(clk_fast), .RESETN(clkdiv_rstn_sync[1]), .CALIB(1'b1));
    CLKDIV #(.DIV_MODE("2"), .GSREN("false")) clkdiv_mem (.CLKOUT(clk_mem), .HCLKIN(clk_fast), .RESETN(clkdiv_rstn_sync[1]), .CALIB(1'b1));

    // ── reset: 1.2 ms after power-on, held by S1 ──
    reg [15:0] rst_timer = 16'd0;
    wire timer_done = rst_timer[15];
    always @(posedge sys_clk)
        if (btn[0]) rst_timer <= 16'd0;
        else if (!timer_done) rst_timer <= rst_timer + 16'd1;
    wire hw_reset_n = timer_done && !btn[0] && core_locked;
    wire hdmi_rst_n = hw_reset_n && hdmi_locked;
    CLKDIV #(.DIV_MODE("5"), .GSREN("false")) clkdiv_hdmi (.CLKOUT(clk_pix), .HCLKIN(clk_5x), .RESETN(hdmi_rst_n), .CALIB(1'b1));

    wire sdram_ready;
    reg [2:0] reset_s = 3'b111;
    always @(posedge clk) reset_s <= {reset_s[1:0], !(hw_reset_n && sdram_ready)};
    wire reset = reset_s[2];

    // ── the machine ──
    wire [9:0]  cx, cy;
    wire [23:0] rgb;
    wire        hsync, vsync, speaker, halted, opl_sample;
    wire signed [15:0] opl_snd;
    wire        sd_req, sd_read, sd_write, sd_burst, sd_complete, sd_refresh;
    wire [255:0] sd_burst_rdata;
    wire [22:0] sd_addr;
    wire [31:0] sd_wdata, sd_rdata;
    wire [3:0]  sd_wmask;
    wire        sd_cs_n;
    assign sd_cs = sd_cs_n;

    pc286_system #(.CLK_HZ(25_312_500), .BIOS_HEX("bios16.hex"), .HID_TABLE("hid_table.hex"), .FONT_HEX("vga8x16.hex"), .LINES(video_mode::LINES)) machine (
        .clk(clk), .reset(reset), .clk_pix(clk_pix), .cx(cx), .cy(cy), .rgb(rgb), .hsync(hsync), .vsync(vsync),
        .speaker(speaker), .opl_snd(opl_snd), .opl_sample(opl_sample), .kbd_rx(kbd_rx), .sd_sck(sd_clk), .sd_mosi(sd_mosi), .sd_cs_n(sd_cs_n), .sd_miso(sd_miso),
        .dbg_tx(bl616_uart_tx), .mon_rx(bl616_uart_rx), .halted(halted),
        .sd_req(sd_req), .sd_read(sd_read), .sd_write(sd_write), .sd_burst(sd_burst), .sd_addr(sd_addr), .sd_wdata(sd_wdata),
        .sd_brdata(sd_burst_rdata[127:0]),
        .sd_wmask(sd_wmask), .sd_rdata(sd_rdata), .sd_complete(sd_complete), .sd_refresh(sd_refresh));

    gw2ar_sdram #(.FREQ(50_625_000)) sdram (
        .clk(clk), .clk_mem(clk_mem), .reset_n(hw_reset_n),
        .req(sd_req), .req_complete(sd_complete), .read_en(sd_read), .write_en(sd_write),
        .burst(sd_burst), .burst_long(1'b1), .addr({2'b00, sd_addr}), .rdata(sd_rdata), .burst_rdata(sd_burst_rdata),
        .wdata(sd_wdata), .wmask(sd_wmask), .refresh(sd_refresh),
        .O_sdram_clk(O_sdram_clk), .O_sdram_cke(O_sdram_cke), .O_sdram_cs_n(O_sdram_cs_n),
        .O_sdram_ras_n(O_sdram_ras_n), .O_sdram_cas_n(O_sdram_cas_n), .O_sdram_wen_n(O_sdram_wen_n),
        .O_sdram_ba(O_sdram_ba), .O_sdram_addr(O_sdram_addr), .O_sdram_dqm(O_sdram_dqm),
        .IO_sdram_dq(IO_sdram_dq), .sdram_ready(sdram_ready));

    // ── HDMI: 640x480 at 60 Hz, the PC speaker as sound ──
    reg [9:0]  smp_cnt = 10'd0;         // 25.2 MHz / 525 = 48 kHz
    wire       smp_tick = smp_cnt == 10'd524;
    reg [1:0]  spk_s;
    reg        hdmi_reset = 1'b1;
    always @(posedge clk_pix) begin
        smp_cnt <= smp_tick ? 10'd0 : smp_cnt + 10'd1;
        spk_s <= {spk_s[0], speaker};
        hdmi_reset <= !hdmi_rst_n;
    end
    // AdLib sound comes on the CPU clock: each new sample is held and announced by a toggle,
    // and taken here when the toggle has arrived (the value is long stable by then)
    reg signed [15:0] opl_hold;
    reg        opl_tgl = 1'b0;
    always @(posedge clk) if (opl_sample) begin opl_hold <= opl_snd; opl_tgl <= !opl_tgl; end
    reg [2:0]  opl_tgl_s;
    reg signed [15:0] opl_pix;
    always @(posedge clk_pix) begin
        opl_tgl_s <= {opl_tgl_s[1:0], opl_tgl};
        if (opl_tgl_s[2] != opl_tgl_s[1]) opl_pix <= opl_hold;
    end
    wire signed [16:0] mix = opl_pix + (spk_s[1] ? 17'sd6144 : 17'sd0);
    wire [15:0] audio [1:0];
    assign audio[0] = mix[16] != mix[15] ? {mix[16], {15{!mix[16]}}} : mix[15:0];
    assign audio[1] = audio[0];
    wire [2:0] tmds;
    wire       tmds_clock;
    hdmi #(.VIDEO_ID_CODE(video_mode::LINES == 449 ? 0 : 1), .DVI_OUTPUT(1'b0), .VIDEO_REFRESH_RATE(60.0), .AUDIO_RATE(48000),
           .AUDIO_BIT_WIDTH(16), .START_X(0), .START_Y(0)) hdmi_core (
        .clk_pixel_x5(clk_5x), .clk_pixel(clk_pix), .clk_audio(smp_tick),
        .reset(hdmi_reset), .serializer_reset(!hdmi_rst_n),
        .hsync_in(hsync), .vsync_in(vsync), .rgb(rgb), .audio_sample_word(audio),
        .tmds(tmds), .tmds_clock(tmds_clock), .cx(cx), .cy(cy),
        .frame_width(), .frame_height(), .screen_width(), .screen_height());
    TLVDS_OBUF tlvds_d0  (.I(tmds[0]),    .O(tmds_p[0]),  .OB(tmds_n[0]));
    TLVDS_OBUF tlvds_d1  (.I(tmds[1]),    .O(tmds_p[1]),  .OB(tmds_n[1]));
    TLVDS_OBUF tlvds_d2  (.I(tmds[2]),    .O(tmds_p[2]),  .OB(tmds_n[2]));
    TLVDS_OBUF tlvds_clk (.I(tmds_clock), .O(tmds_clk_p), .OB(tmds_clk_n));

    // LEDs (lit when low): machine running, SD card selected, CPU halted, keyboard data
    assign leds_n = {kbd_rx, !halted, sd_cs_n, reset};
endmodule
