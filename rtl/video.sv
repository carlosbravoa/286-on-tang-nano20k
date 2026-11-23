// Video: a 640x400 picture in the middle of a 640x480 at 60 Hz raster.
//   text      80x25 or 40x25 cells of 8x16 pixels, cells at B8000h           (3D8h bit 1 = 0)
//   CGA       320x200 in 4 colours or 640x200 in 2, at B8000h / BA000h       (3D8h bit 1 = 1)
//   mode 13h  320x200 in 256 colours, one byte a pixel at A0000h             (vid_ctrl bit 0)
// 200-line modes show every line twice. Video memory is ordinary RAM: a line (or a row of
// text) is read, 16 bytes at a time, into a line buffer shortly before it is shown (cpu clock side) and shown
// from there (pixel clock side). Every colour goes through the VGA palette (3C6h-3C9h).
// cx/cy come from the HDMI transmitter; rgb is its pixel for cx/cy.
`timescale 1ns/1ps
module video #(parameter FONT_HEX = "fonts/vga8x16.hex") (
    // pixel side
    input  logic        clk_pix,
    input  logic [9:0]  cx, cy,         // 800 x 525 raster, picture at 0..639, 0..479
    output logic [23:0] rgb,
    output logic        hsync, vsync,   // for the HDMI transmitter (negative polarity)
    output logic        blank,          // outside the picture
    output logic        vretrace,
    // cpu side
    input  logic        clk,
    input  logic        reset,
    input  logic [15:0] crtc_start, crtc_cursor,
    input  logic [5:0]  cursor_start,
    input  logic [4:0]  cursor_end,
    input  logic [7:0]  vid_mode,       // 3D8h: 0 80 columns, 1 graphics, 2 mono palette, 3 on, 4 640 wide, 5 blink
    input  logic [7:0]  vid_color,      // 3D9h: 3-0 background/border, 4 bright, 5 palette
    input  logic [7:0]  vid_ctrl,       // bit 0: mode 13h
    input  logic        vio_wr, vio_rd, // ports 3C0h-3CFh
    input  logic [3:0]  vio_addr,
    input  logic [7:0]  vio_wdata,
    output logic [7:0]  vio_rdata,
    output logic        vf_req,         // read 16 bytes of RAM (vf_addr is a multiple of 16)
    output logic [22:0] vf_addr,
    input  logic [127:0] vf_rdata,
    input  logic        vf_ack
);
    localparam int TOP = 40;            // first line of the picture
    wire g13   = vid_ctrl[0];
    wire gfx   = g13 || vid_mode[1];
    wire cga2  = vid_mode[4];
    wire col80 = vid_mode[0];

    // ── raster position three pixels ahead (the pipeline below is three stages) ──
    wire        wrap = cx >= 10'd797;
    wire [9:0]  hx = wrap ? cx - 10'd797 : cx + 10'd3;
    wire [9:0]  hy = !wrap ? cy : (cy == 10'd524 ? 10'd0 : cy + 10'd1);
    wire [9:0]  ty = hy - 10'(TOP);
    wire        in_y = hy >= 10'(TOP) && hy < 10'(TOP + 400);
    wire        in_x = hx < 10'd640;
    wire [4:0]  row = ty[8:4];
    wire [3:0]  scan = ty[3:0];
    wire [7:0]  gline = ty[8:1];        // graphics line 0..199

    always_ff @(posedge clk_pix) begin
        hsync    <= !(cx >= 10'd656 && cx < 10'd752);
        vsync    <= !(cy >= 10'd490 && cy < 10'd492);
        blank    <= !(cx < 10'd640 && cy >= 10'(TOP) && cy < 10'(TOP + 400));
        vretrace <= cy >= 10'd486 && cy < 10'd494;
    end

    // ── ask for the next unit (a text row or a graphics line): unit 0 before the picture,
    //    unit n+1 when unit n starts ──
    logic       fetch_tgl;
    logic [7:0] fetch_unit;
    logic [5:0] frame_cnt;
    wire        unit_start = gfx ? !ty[0] : scan == 4'd0;
    wire [7:0]  unit = gfx ? gline : {3'b0, row};
    wire [7:0]  unit_last = gfx ? 8'd199 : 8'd24;
    always_ff @(posedge clk_pix) begin
        if (hx == 10'd0) begin
            if (hy == 10'd8) begin fetch_unit <= 8'd0; fetch_tgl <= ~fetch_tgl; end
            else if (in_y && unit_start && unit < unit_last) begin fetch_unit <= unit + 8'd1; fetch_tgl <= ~fetch_tgl; end
            if (hy == 10'd0) frame_cnt <= frame_cnt + 6'd1;
        end
    end

    // ── line buffers: two rows of 80 cells; two lines of 80 words ──
    logic [15:0] textbuf [0:255];
    logic [31:0] gbuf [0:255];
    logic        tb_we, gb_we;
    logic [7:0]  tb_waddr, gb_waddr;
    logic [15:0] tb_wdata, cell_q;
    logic [31:0] gb_wdata, gword_q;
    wire  [6:0]  tcol = col80 ? hx[9:3] : {1'b0, hx[9:4]};
    wire  [6:0]  gcol = g13 ? hx[9:3] : {2'b0, hx[9:5]};
    always_ff @(posedge clk) if (tb_we) textbuf[tb_waddr] <= tb_wdata;
    always_ff @(posedge clk) if (gb_we) gbuf[gb_waddr] <= gb_wdata;
    always_ff @(posedge clk_pix) cell_q  <= textbuf[{row[0], tcol}];
    always_ff @(posedge clk_pix) gword_q <= gbuf[{gline[0], gcol}];

    // ── fetch (cpu clock) ──
    logic [2:0]  tgl_s;
    logic [1:0]  fst_q;                 // 0 idle, 1 read, 2 store (low half), 3 store high half
    logic [6:0]  word_q, last_q;
    logic [15:0] off_q;                 // byte offset of the unit in its segment
    logic        seg_a_q, gfx_q, buf_q;
    wire  [7:0]  u = fetch_unit;
    wire  [15:0] text_cell = crtc_start + (col80 ? {3'b0, u, 6'b0} + {5'b0, u, 4'b0} : {4'b0, u, 5'b0} + {6'b0, u, 3'b0});
    wire  [15:0] cga_off   = {2'b0, u[0], 13'b0} + {3'b0, u[7:1], 6'b0} + {5'b0, u[7:1], 4'b0};
    wire  [15:0] g13_off   = {u, 8'b0} + {2'b0, u, 6'b0};
    wire  [13:0] cur_word  = off_q[15:2] + 14'(word_q);              // the word wanted now
    wire  [31:0] data      = vf_rdata[{cur_word[1:0], 5'b0} +: 32];   // stays until the next read
    wire  [7:0]  idx_lo = {word_q, 1'b0} - {7'b0, off_q[1]};         // text: cell number of the low half
    wire  [7:0]  idx_hi = idx_lo + 8'd1;
    wire         last_word = word_q == last_q;
    wire  [1:0]  next = last_word ? 2'd0 : cur_word[1:0] == 2'd3 ? 2'd1 : 2'd2;   // after this word
    assign vf_req  = fst_q == 2'd1;
    assign vf_addr = seg_a_q ? {7'h0A, cur_word[13:2], 4'b0} : {8'h17, cur_word[12:2], 4'b0};   // A0000h or B8000h
    always_ff @(posedge clk) begin
        tgl_s <= {tgl_s[1:0], fetch_tgl};
        tb_we <= 1'b0; gb_we <= 1'b0;
        case (fst_q)
            2'd0: if (tgl_s[2] != tgl_s[1]) begin
                      gfx_q <= gfx; seg_a_q <= g13; buf_q <= u[0]; word_q <= '0; fst_q <= 2'd1;
                      off_q  <= g13 ? g13_off : gfx ? cga_off : {text_cell[14:0], 1'b0};
                      last_q <= g13 ? 7'd79 : gfx ? 7'd19 : 7'd40;
                  end
            2'd1: if (vf_ack) fst_q <= 2'd2;
            2'd2: if (gfx_q) begin
                      gb_we <= 1'b1; gb_waddr <= {buf_q, word_q}; gb_wdata <= data;
                      word_q <= word_q + 7'd1;
                      fst_q <= next;
                  end else begin
                      tb_we <= !idx_lo[7] && idx_lo < 8'd80; tb_waddr <= {buf_q, idx_lo[6:0]}; tb_wdata <= data[15:0];
                      fst_q <= 2'd3;
                  end
            default: begin
                      tb_we <= idx_hi < 8'd80; tb_waddr <= {buf_q, idx_hi[6:0]}; tb_wdata <= data[31:16];
                      word_q <= word_q + 7'd1;
                      fst_q <= next;
                  end
        endcase
        if (reset) fst_q <= 2'd0;
    end

    // ── the palette (VGA DAC): 256 colours of 3 x 6 bits ──
    //   3C8h write index, 3C7h read index, 3C9h data (red, green, blue in turn), 3C6h mask (not kept)
    logic [17:0] dac [0:255];
    logic [17:0] dac_cpu_q, dac_pix_q;
    logic [7:0]  dac_widx_q, dac_ridx_q, pal_index;
    logic [1:0]  dac_wph_q, dac_rph_q;
    logic [11:0] dac_rg_q;
    wire dac_data_wr = vio_wr && vio_addr == 4'h9;
    wire dac_commit  = dac_data_wr && dac_wph_q == 2'd2;
    always_ff @(posedge clk) begin
        if (dac_commit) dac[dac_widx_q] <= {dac_rg_q, vio_wdata[5:0]};
        dac_cpu_q <= dac[dac_ridx_q];
    end
    always_ff @(posedge clk_pix) dac_pix_q <= dac[pal_index];
    always_ff @(posedge clk) begin
        if (vio_wr && vio_addr == 4'h8) begin dac_widx_q <= vio_wdata; dac_wph_q <= 2'd0; end
        if (vio_wr && vio_addr == 4'h7) begin dac_ridx_q <= vio_wdata; dac_rph_q <= 2'd0; end
        if (dac_data_wr) begin
            if (dac_wph_q == 2'd0) dac_rg_q[11:6] <= vio_wdata[5:0];
            if (dac_wph_q == 2'd1) dac_rg_q[5:0]  <= vio_wdata[5:0];
            dac_wph_q <= dac_wph_q == 2'd2 ? 2'd0 : dac_wph_q + 2'd1;
            if (dac_wph_q == 2'd2) dac_widx_q <= dac_widx_q + 8'd1;
        end
        if (vio_rd && vio_addr == 4'h9) begin
            dac_rph_q <= dac_rph_q == 2'd2 ? 2'd0 : dac_rph_q + 2'd1;
            if (dac_rph_q == 2'd2) dac_ridx_q <= dac_ridx_q + 8'd1;
        end
        if (reset) begin dac_wph_q <= 2'd0; dac_rph_q <= 2'd0; end
    end
    always_comb case (vio_addr)
        4'h6: vio_rdata = 8'hFF;
        4'h7: vio_rdata = 8'h03;
        4'h8: vio_rdata = dac_widx_q;
        4'h9: vio_rdata = {2'b00, dac_rph_q == 2'd0 ? dac_cpu_q[17:12] : dac_rph_q == 2'd1 ? dac_cpu_q[11:6] : dac_cpu_q[5:0]};
        default: vio_rdata = 8'hFF;
    endcase

    // ── pixels ──
    logic [7:0] font [0:4095];
    initial $readmemh(FONT_HEX, font);
    logic [7:0]  font_q, attr2_q, gidx2_q;
    logic [4:0]  hx1_q;
    logic [2:0]  sub2_q;
    logic [3:0]  scan1_q;
    logic        vis1_q, vis2_q, vis3_q, cur1_q, cur2_q;
    wire  [15:0] cellnum = crtc_start + (col80 ? {5'b0, row, 6'b0} + {7'b0, row, 4'b0} + {9'b0, hx[9:3]}
                                               : {6'b0, row, 5'b0} + {8'b0, row, 3'b0} + {10'b0, hx[9:4]});
    wire         blink_on = frame_cnt[5];
    wire         cursor_on = !cursor_start[5] && frame_cnt[4];

    // stage 1 -> 2: the pixel of a graphics mode, as a palette index
    logic [7:0] gbyte, gidx;
    logic [1:0] c2;
    always_comb begin
        gbyte = g13 ? gword_q[{hx1_q[2:1], 3'b0} +: 8] : gword_q[{hx1_q[4:3], 3'b0} +: 8];
        c2    = gbyte[{~hx1_q[2:1], 1'b0} +: 2];
        if (g13) gidx = gbyte;
        else if (cga2) gidx = gbyte[3'd7 - hx1_q[2:0]] ? {4'b0, vid_color[3:0]} : 8'h00;
        else if (c2 == 2'd0) gidx = {4'b0, vid_color[3:0]};
        else if (vid_mode[2]) gidx = {4'b0, vid_color[4], c2 == 2'd1 ? 3'd3 : c2 == 2'd2 ? 3'd4 : 3'd7};
        else gidx = {4'b0, vid_color[4], c2, vid_color[5]};
    end
    // stage 2 -> 3: the palette index of the pixel
    always_comb begin
        logic fg;
        logic [3:0] bgc;
        fg  = font_q[3'd7 - sub2_q];
        bgc = vid_mode[5] ? {1'b0, attr2_q[6:4]} : attr2_q[7:4];
        if (vid_mode[5] && attr2_q[7] && blink_on) fg = 1'b0;
        if (cur2_q) fg = 1'b1;
        pal_index = gfx ? gidx2_q : {4'b0, fg ? attr2_q[3:0] : bgc};
    end

    always_ff @(posedge clk_pix) begin
        // stage 1: the cell / the word are in cell_q, gword_q
        hx1_q   <= hx[4:0];
        scan1_q <= scan;
        vis1_q  <= in_x && in_y && vid_mode[3];
        cur1_q  <= cellnum == crtc_cursor && cursor_on &&
                   {1'b0, scan} >= cursor_start[4:0] && {1'b0, scan} <= cursor_end;
        // stage 2: the font byte
        font_q  <= font[{cell_q[7:0], scan1_q}];
        attr2_q <= cell_q[15:8];
        sub2_q  <= col80 ? hx1_q[2:0] : hx1_q[3:1];
        gidx2_q <= gidx;
        vis2_q  <= vis1_q;
        cur2_q  <= cur1_q;
        // stage 3: the palette's answer is in dac_pix_q
        vis3_q  <= vis2_q;
    end
    assign rgb = !vis3_q ? 24'h000000 : {dac_pix_q[17:12], dac_pix_q[17:16], dac_pix_q[11:6], dac_pix_q[11:10], dac_pix_q[5:0], dac_pix_q[5:4]};
endmodule
