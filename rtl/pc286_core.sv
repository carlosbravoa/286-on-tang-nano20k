// The 286 machine, board independent: SPK286, the BIOS ROM, address decode and the chipset.
// RAM is outside (SDRAM on the board, a model in simulation): one request at a time, held
// until mem_ack. Byte lanes: [7:0] is the even address, [15:8] the odd one.
//
// I/O map
//   020-021 master PIC      040-043 timer          060,064 keyboard controller
//   061     speaker, timer 2 gate, refresh bit     092     A20 (bit 1), CPU reset (bit 0)
//   0A0-0A1 slave PIC       0E0-0E1 SD card SPI    0E9     debug character (simulation)
//   0E4-0E6 mouse (buttons, x, y)                  0EA     video control (bit 0: mode 13h)
//   0EC-0EE memory window at D0000 (quarter, page low, page high and on)
//   388-389 AdLib (OPL2)                            3C6-3C9 VGA palette
//   3D4-3D5 CRTC            3D8 mode  3D9 colour   3DA     video status
`timescale 1ns/1ps
module pc286_core #(
    parameter int CLK_HZ = 25_312_500,
    parameter BIOS_HEX = "build/bios16.hex",   // 16-bit words, the top ROM_WORDS*2 bytes of the first megabyte
    parameter HID_TABLE = "build/hid_table.hex",
    parameter int ROM_AW = 13                  // 8192 words = 16 KB at FC000h
) (
    input  logic        clk,
    input  logic        reset,
    // RAM
    output logic        mem_req,
    output logic        mem_we,
    output logic        mem_fetch,      // the access is a code fetch
    output logic [23:0] mem_addr,       // address of the even byte (bit 0 is 0)
    output logic [1:0]  mem_be,
    output logic [15:0] mem_wdata,
    input  logic [15:0] mem_rdata,
    input  logic        mem_ack,
    // keyboard and mouse (CH9350 UART)
    input  logic        kbd_rx,
    // SD card
    output logic        sd_sck, sd_mosi, sd_cs_n,
    input  logic        sd_miso,
    // video
    output logic [15:0] crtc_start,     // first character cell shown
    output logic [9:0]  crtc_lc,        // line compare: below this raster line the picture starts again from 0
    output logic [15:0] crtc_cursor,    // cursor cell
    output logic [5:0]  cursor_start,   // bit 5 = cursor off
    output logic [4:0]  cursor_end,
    output logic [7:0]  vid_mode,       // port 3D8h
    output logic [7:0]  vid_color,      // port 3D9h
    output logic [7:0]  vid_ctrl,       // port 0EAh: bit 0 = mode 13h, bit 1 = 16-colour planes (see video.sv)
    output logic        attr_reset,     // 3DAh was read
    output logic        px_req, px_we,  // the EGA planes, to the bridge
    output logic [15:0] px_addr,
    output logic [31:0] px_wdata,
    output logic [3:0]  px_wmask,
    input  logic [31:0] px_rdata,
    input  logic        px_ack,
    output logic        vio_wr, vio_rd, // ports 3C0h-3CFh, in the video block
    output logic [3:0]  vio_addr,
    output logic [7:0]  vio_wdata,
    input  logic [7:0]  vio_rdata,
    input  logic        vid_blank,      // not in the picture area (3DAh bit 0)
    input  logic        vid_vsync,      // 3DAh bit 3
    // sound
    output logic        speaker,
    output logic signed [15:0] opl_snd, // AdLib and Sound Blaster together
    output logic        dm_req,         // a byte of RAM for the Sound Blaster
    output logic [22:0] dm_addr,
    input  logic [7:0]  dm_rdata,
    input  logic        dm_ack,
    output logic        opl_sample,
    // simulation / debug
    output logic        dbg_char_valid,
    output logic [7:0]  dbg_char,
    output logic        halted
);
    localparam logic [3:0] C_INTA = 4'h0, C_MEMR = 4'h5, C_MEMW = 4'h6,
                           C_IOR = 4'h9, C_IOW = 4'hA, C_FETCH = 4'hD;

    logic [23:0] address;
    logic [15:0] cpu_dout, cpu_din;
    logic [3:0]  status;
    logic bus_valid, bus_write, bhe_n, ready, intr, shutdown, cpu_reset;

    spk286 cpu (
        .clk(clk), .reset(cpu_reset), .ready(ready), .data_in(cpu_din),
        .execute_enable(1'b1), .timing_policy_request(2'd2),   // 2 = Max (dependency driven)
        .intr(intr), .nmi(1'b0), .hold_request(1'b0),
        .halted(halted), .shutdown(shutdown),
        // setup/debug inputs of the core, unused in a machine
        .gpr_read_a_index('0), .gpr_read_b_index('0), .gpr_read_a_byte(1'b0), .gpr_read_b_byte(1'b0),
        .gpr_write_en(1'b0), .gpr_write_byte(1'b0), .gpr_write_index('0), .gpr_write_data('0),
        .ip_write_en(1'b0), .ip_write_data('0),
        .flags_write_en(1'b0), .flags_write_data('0), .flags_write_mask('0),
        .segment_load_en(1'b0), .segment_load_index('0), .segment_load_selector('0),
        .segment_read_index('0), .segment_offset('0),
        .redirect(1'b0), .fetch_request(1'b0), .fetch_ready(1'b0),
        .address(address), .data_out(cpu_dout), .bus_valid(bus_valid), .bus_write(bus_write),
        .bus_bhe_n(bhe_n), .bus_status(status)
    );

    wire is_mem  = bus_valid && (status == C_MEMR || status == C_MEMW || status == C_FETCH);
    wire is_io   = bus_valid && (status == C_IOR || status == C_IOW);
    wire is_inta = bus_valid && status == C_INTA;

    // ── memory ──
    logic a20_q;
    wire  bios_alias = address[23:16] == 8'hFF;
    wire [23:0] lin = bios_alias ? {8'h0F, address[15:0]}
                                 : {address[23:21], address[20] & a20_q, address[19:0]};
    // The window: each 16 KB quarter of D0000-DFFFF can show any 16 KB of the 8 MB instead of
    // its own. For expanded memory, and for the BIOS to reach memory above 1 MB in real mode.
    //   port ECh: which quarter; EDh: page, low 8 bits; EEh: bit 0 = page bit 8, bit 7 = on
    logic [1:0] map_sel_q;
    logic [9:0] map_q [4];
    wire  [9:0] map_e = map_q[lin[15:14]];
    wire [23:0] phys = lin[23:16] == 8'h0D && map_e[9] ? {1'b0, map_e[8:0], lin[13:0]} : lin;
    wire is_rom = is_mem && phys[23:20] == 4'h0 && &phys[19:ROM_AW+1];   // top of the first megabyte

    logic [15:0] rom [0:(1<<ROM_AW)-1];
    initial $readmemh(BIOS_HEX, rom);
    logic [15:0] rom_q;
    logic        rom_ack_q;
    always_ff @(posedge clk) begin
        rom_q <= rom[phys[ROM_AW:1]];
        rom_ack_q <= is_rom && !rom_ack_q;
    end

    // with the 16-colour planes on, A0000-AFFFF is the planes, not RAM
    wire is_pl = is_mem && vid_ctrl[1] && phys[23:16] == 8'h0A;
    logic [15:0] pl_rdata;
    logic [7:0]  pl_r;
    logic        pl_ack;
    assign mem_req   = is_mem && !is_rom && !is_pl;
    assign mem_fetch = status == C_FETCH;
    assign mem_we    = bus_write;
    assign mem_addr  = {phys[23:1], 1'b0};
    assign mem_be    = {~bhe_n, ~address[0]};
    assign mem_wdata = cpu_dout;

    // ── I/O: byte devices; a word access is done as two byte accesses ──
    logic       io_phase_q, io_wait;
    logic [7:0] io_lo_q, io_rdata;
    wire        io_word  = !bhe_n && !address[0];
    wire [15:0] io_addr  = {address[15:1], address[0] | io_phase_q};
    wire [7:0]  io_wdata = io_addr[0] ? cpu_dout[15:8] : cpu_dout[7:0];
    wire        io_stb   = is_io && !io_wait;
    wire        io_done  = io_stb && (!io_word || io_phase_q);
    wire        io_wr    = io_stb && bus_write;
    wire        io_rd    = io_stb && !bus_write;
    always_ff @(posedge clk) begin
        if (io_stb) begin
            io_phase_q <= io_word && !io_phase_q;
            if (!io_phase_q) io_lo_q <= io_rdata;
        end
        if (cpu_reset) io_phase_q <= 1'b0;
    end

    wire sel_pic1 = io_addr[15:1] == 15'h0010;          // 020-021
    wire sel_pit  = io_addr[15:2] == 14'h0010;          // 040-043
    wire sel_kbd  = io_addr == 16'h0060 || io_addr == 16'h0064;
    wire sel_p61  = io_addr == 16'h0061;
    wire sel_p92  = io_addr == 16'h0092;
    wire sel_pic2 = io_addr[15:1] == 15'h0050;          // 0A0-0A1
    wire sel_spi  = io_addr[15:1] == 15'h0070;          // 0E0-0E1
    wire sel_mouse = io_addr[15:2] == 14'h0039;        // 0E4-0E7
    wire sel_map  = io_addr[15:2] == 14'h003B;          // 0EC-0EF
    wire sel_sb   = io_addr[15:4] == 12'h022;           // 220-22F: Sound Blaster
    wire sel_dma  = io_addr[15:4] == 12'h000;           // 000-00F: its DMA channel
    wire sel_dpg  = io_addr == 16'h0083;
    wire sel_opl  = io_addr[15:1] == 15'h01C4 || io_addr[15:1] == 15'h0114;   // 388-389, and 228-229
    wire sel_dbg  = io_addr == 16'h00E9;
    wire sel_vctl = io_addr == 16'h00EA;
    wire sel_vga  = io_addr[15:4] == 12'h03C;         // 3C0-3CF
    wire sel_seq  = io_addr[15:1] == 15'h01E2;          // 3C4-3C5
    wire sel_gc   = io_addr[15:1] == 15'h01E7;          // 3CE-3CF
    wire sel_crtc = io_addr[15:1] == 15'h01EA;          // 3D4-3D5
    wire sel_3d8  = io_addr == 16'h03D8;
    wire sel_3d9  = io_addr == 16'h03D9;
    wire sel_3da  = io_addr == 16'h03DA;

    // interrupts
    logic [7:0] pic1_r, pic2_r, vec1, vec2, irq1_lines, irq2_lines;
    logic [2:0] num1, num2;
    logic intr2, inta_second_q, pic_ack;
    logic [7:0] inta_vec_q;
    logic irq_timer, irq_kbd;
    logic irq_sb;
    assign irq1_lines = {irq_sb, 4'b0, intr2, irq_kbd, irq_timer};   // IRQ 7: the Sound Blaster
    logic m_new_q;
    logic [7:0] m_dx_q, m_dy_q, m_dx_lat, m_dy_lat;
    logic [2:0] m_btn_q;
    assign irq2_lines = {3'b0, m_new_q, 4'b0};          // IRQ 12: the mouse
    wire cascade = num1 == 3'd2 && intr2;
    pic8259 pic1 (.clk, .reset, .a0(io_addr[0]), .wr(io_wr && sel_pic1), .wdata(io_wdata), .rdata(pic1_r),
                  .irq(irq1_lines), .intr(intr), .ack(pic_ack), .irq_num(num1), .vector(vec1));
    pic8259 pic2 (.clk, .reset, .a0(io_addr[0]), .wr(io_wr && sel_pic2), .wdata(io_wdata), .rdata(pic2_r),
                  .irq(irq2_lines), .intr(intr2), .ack(pic_ack && cascade), .irq_num(num2), .vector(vec2));
    assign pic_ack = is_inta && !inta_second_q;         // the first of the two INTA cycles
    always_ff @(posedge clk) begin
        if (is_inta) begin
            inta_second_q <= !inta_second_q;
            if (!inta_second_q) inta_vec_q <= cascade ? vec2 : vec1;
        end
        if (cpu_reset) inta_second_q <= 1'b0;
    end

    // timer and speaker
    logic [7:0] pit_r;
    logic [1:0] p61_q;
    logic out2, refresh_toggle;
    pit8254 #(.CLK_HZ(CLK_HZ)) pit (.clk, .reset, .addr(io_addr[1:0]), .wr(io_wr && sel_pit), .rd(io_rd && sel_pit),
        .wdata(io_wdata), .rdata(pit_r), .gate2(p61_q[0]), .out0(irq_timer), .out2, .refresh_toggle);
    assign speaker = out2 & p61_q[1];

    logic [7:0] opl_status;
    adlib #(.CLK_HZ(CLK_HZ)) adlib (.clk, .reset, .wr(io_wr && sel_opl), .a0(io_addr[0]), .wdata(io_wdata),
        .status(opl_status), .snd(fm_snd), .sample(fm_sample));

    // Sound Blaster; its sound is added to the AdLib's at every AdLib sample
    logic signed [15:0] fm_snd;
    logic        fm_sample;
    logic [7:0]  sb_r, sb_dac;
    sblaster #(.CLK_HZ(CLK_HZ)) sb (.clk, .reset, .sel_dsp(sel_sb && !sel_opl), .sel_dma, .sel_page(sel_dpg),
        .a(io_addr[3:0]), .wr(io_wr), .rd(io_rd), .wdata(io_wdata), .rdata(sb_r), .irq(irq_sb),
        .dm_req, .dm_addr, .dm_rdata, .dm_ack, .dac(sb_dac));
    wire signed [16:0] snd_sum = fm_snd + $signed({~sb_dac[7], sb_dac[6:0], 6'b0});
    always_ff @(posedge clk) begin
        opl_sample <= fm_sample;
        if (fm_sample) opl_snd <= snd_sum[16] != snd_sum[15] ? {snd_sum[16], {15{!snd_sum[16]}}} : snd_sum[15:0];
    end

    // keyboard
    logic [7:0] kbd_r, sc_data, mouse_dx, mouse_dy;
    logic [2:0] mouse_btn;
    logic sc_valid, sc_ready, a20_set, a20_value, kbd_reset_req, mouse_valid;
    kbd_ch9350 #(.CLK_HZ(CLK_HZ), .HID_TABLE(HID_TABLE)) hid (.clk, .reset, .rx(kbd_rx),
        .sc_valid, .sc_data, .sc_ready, .mouse_valid, .mouse_btn, .mouse_dx, .mouse_dy);
    kbd8042 kbc (.clk, .reset, .a2(io_addr[2]), .wr(io_wr && sel_kbd), .rd(io_rd && sel_kbd),
        .wdata(io_wdata), .rdata(kbd_r), .sc_valid, .sc_data, .sc_ready, .irq1(irq_kbd),
        .a20_set, .a20_value, .a20_now(a20_q), .cpu_reset_req(kbd_reset_req));

    // SD card
    logic [7:0] spi_r;
    spi_port spi (.clk, .reset, .a0(io_addr[0]), .sel(is_io && sel_spi), .wr(io_wr && sel_spi), .rd(io_rd && sel_spi),
        .wdata(io_wdata), .rdata(spi_r), .io_wait, .sck(sd_sck), .mosi(sd_mosi), .miso(sd_miso), .cs_n(sd_cs_n));

    ega_planes planes (.clk, .reset, .sel_seq, .sel_gc, .a0(io_addr[0]), .wr(io_wr), .io_wdata, .io_rdata(pl_r),
        .req(is_pl), .we(bus_write), .addr({phys[15:1], 1'b0}), .be(mem_be), .wdata(cpu_dout), .rdata(pl_rdata), .ack(pl_ack),
        .px_req, .px_we, .px_addr, .px_wdata, .px_wmask, .px_rdata, .px_ack);
    assign attr_reset = io_rd && sel_3da;

    // video registers
    logic [4:0] crtc_idx_q;
    logic [7:0] crtc_r;
    logic [2:0] blank_s, vsync_s;
    always_comb case (crtc_idx_q)
        5'h0A: crtc_r = {2'b0, cursor_start};
        5'h0B: crtc_r = {3'b0, cursor_end};
        5'h0C: crtc_r = crtc_start[15:8];
        5'h0D: crtc_r = crtc_start[7:0];
        5'h0E: crtc_r = crtc_cursor[15:8];
        5'h0F: crtc_r = crtc_cursor[7:0];
        default: crtc_r = 8'h00;
    endcase

    always_comb begin
        io_rdata = 8'hFF;
        if (sel_pic1) io_rdata = pic1_r;
        if (sel_pic2) io_rdata = pic2_r;
        if (sel_pit)  io_rdata = pit_r;
        if (sel_kbd)  io_rdata = kbd_r;
        if (sel_p61)  io_rdata = {2'b00, out2, refresh_toggle, 2'b00, p61_q};
        if (sel_p92)  io_rdata = {6'b0, a20_q, 1'b0};
        if (sel_spi)  io_rdata = spi_r;
        if (sel_crtc) io_rdata = io_addr[0] ? crtc_r : {3'b0, crtc_idx_q};
        if (sel_mouse) io_rdata = io_addr[1] ? m_dy_lat : io_addr[0] ? m_dx_lat : {m_new_q, 4'b0, m_btn_q};
        if (sel_map)  io_rdata = io_addr[1] ? {map_q[map_sel_q][9], 6'b0, map_q[map_sel_q][8]}
                               : io_addr[0] ? map_q[map_sel_q][7:0] : {6'b0, map_sel_q};
        if (sel_sb || sel_dma || sel_dpg) io_rdata = sb_r;
        if (sel_opl)  io_rdata = opl_status;
        if (sel_vctl) io_rdata = vid_ctrl;
        if (sel_vga)  io_rdata = vio_rdata;
        if (sel_seq || sel_gc) io_rdata = pl_r;
        if (sel_3d8)  io_rdata = vid_mode;
        if (sel_3d9)  io_rdata = vid_color;
        if (sel_3da)  io_rdata = {4'hF, vsync_s[2], 2'b00, blank_s[2]};
    end

    // mouse: what it reports adds up until the BIOS reads port E4h, which latches the sums
    // for ports E5h and E6h and starts again from zero
    function automatic logic [7:0] sat_add(input logic [7:0] a, input logic [7:0] b);
        logic [8:0] sum;
        sum = {a[7], a} + {b[7], b};
        return sum[8] != sum[7] ? {sum[8], {7{!sum[8]}}} : sum[7:0];
    endfunction
    wire m_take = io_rd && sel_mouse && io_addr[1:0] == 2'b00;
    always_ff @(posedge clk) begin
        if (m_take) begin
            m_dx_lat <= m_dx_q; m_dy_lat <= m_dy_q;
            m_dx_q <= 8'd0; m_dy_q <= 8'd0; m_new_q <= 1'b0;
        end
        if (mouse_valid) begin
            m_dx_q <= sat_add(m_take ? 8'd0 : m_dx_q, mouse_dx);
            m_dy_q <= sat_add(m_take ? 8'd0 : m_dy_q, mouse_dy);
            m_btn_q <= mouse_btn; m_new_q <= 1'b1;
        end
        if (reset) begin m_dx_q <= 8'd0; m_dy_q <= 8'd0; m_btn_q <= 3'd0; m_new_q <= 1'b0; end
    end

    assign vio_wr = io_wr && sel_vga;
    assign vio_rd = io_rd && sel_vga;
    assign vio_addr = io_addr[3:0];
    assign vio_wdata = io_wdata;

    // CPU reset: the keyboard controller's reset line, port 92h bit 0, or a triple fault
    logic [4:0] rst_cnt_q;
    assign cpu_reset = reset || rst_cnt_q != 0;

    always_ff @(posedge clk) begin
        dbg_char_valid <= 1'b0;
        blank_s <= {blank_s[1:0], vid_blank};
        vsync_s <= {vsync_s[1:0], vid_vsync};
        if (rst_cnt_q != 0) rst_cnt_q <= rst_cnt_q - 5'd1;
        if (kbd_reset_req || (shutdown && rst_cnt_q == 0)) rst_cnt_q <= 5'd31;
        if (a20_set) a20_q <= a20_value;
        if (io_wr) begin
            if (sel_p61) p61_q <= io_wdata[1:0];
            if (sel_p92) begin a20_q <= io_wdata[1]; if (io_wdata[0]) rst_cnt_q <= 5'd31; end
            if (sel_dbg) begin dbg_char_valid <= 1'b1; dbg_char <= io_wdata; end
            if (sel_map) case (io_addr[1:0])
                2'd0: map_sel_q <= io_wdata[1:0];
                2'd1: map_q[map_sel_q][7:0] <= io_wdata;
                2'd2: map_q[map_sel_q][9:8] <= {io_wdata[7], io_wdata[0]};
                default: ;
            endcase
            if (sel_crtc && !io_addr[0]) crtc_idx_q <= io_wdata[4:0];
            if (sel_crtc && io_addr[0]) case (crtc_idx_q)
                5'h0A: cursor_start <= io_wdata[5:0];
                5'h0B: cursor_end <= io_wdata[4:0];
                5'h07: crtc_lc[8] <= io_wdata[4];
                5'h09: crtc_lc[9] <= io_wdata[6];
                5'h18: crtc_lc[7:0] <= io_wdata;
                5'h0C: crtc_start[15:8] <= io_wdata;
                5'h0D: crtc_start[7:0] <= io_wdata;
                5'h0E: crtc_cursor[15:8] <= io_wdata;
                5'h0F: crtc_cursor[7:0] <= io_wdata;
                default: ;
            endcase
            if (sel_vctl) vid_ctrl <= io_wdata;
            if (sel_3d8) vid_mode <= io_wdata;
            if (sel_3d9) vid_color <= io_wdata;
        end
        if (reset) begin
            for (int i = 0; i < 4; i++) map_q[i][9] <= 1'b0;
            a20_q <= 1'b0; p61_q <= 2'b00; rst_cnt_q <= '0; crtc_idx_q <= '0;
            crtc_lc <= '1; crtc_start <= '0; crtc_cursor <= '0; cursor_start <= 6'd13; cursor_end <= 5'd14;
            vid_mode <= 8'h29; vid_color <= 8'h00; vid_ctrl <= 8'h00;
        end
    end

    // ── CPU ready and data in ──
    assign ready = is_rom ? rom_ack_q : is_pl ? pl_ack : is_mem ? mem_ack : is_io ? io_done : 1'b1;
    always_comb begin
        if (is_rom)       cpu_din = rom_q;
        else if (is_pl)   cpu_din = pl_rdata;
        else if (is_mem)  cpu_din = mem_rdata;
        else if (is_inta) cpu_din = {8'h00, inta_second_q ? inta_vec_q : 8'hFF};
        else              cpu_din = io_word ? {io_rdata, io_lo_q} : {io_rdata, io_rdata};
    end
endmodule
