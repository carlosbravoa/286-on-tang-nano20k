// Video: a 640x400 picture. LINES chooses the raster:
//   525   640x480 at 60 Hz, the picture in the middle (lines 40-439)
//   449   640x400 at 70 Hz, what a VGA card sends in these modes: programs that time
//         themselves on the retrace run as they should
//   text      80x25 or 40x25 cells of 8x16 pixels, cells at B8000h           (3D8h bit 1 = 0)
//   CGA       320x200 in 4 colours or 640x200 in 2, at B8000h / BA000h       (3D8h bit 1 = 1)
//   mode 13h  320x200 in 256 colours, one byte a pixel at A0000h             (vid_ctrl bit 0)
//   planes    16 colours from four planes (EGA/VGA), see ega_planes.sv         (vid_ctrl bit 1)
//             bit 2 = 640 wide (else 320); bits 4-3 = lines: 0 200, 1 350, 2 480 (480: only
//             with LINES = 525). The picture starts at the CRTC start address. A pixel's
//             four bits choose one of the 16 attribute palette registers (3C0h).
//             Register 13h there moves the picture left by 0-7 pixels; below the CRTC's
//             line compare the picture starts again from address 0, not moved (split screen).
// 200-line modes show every line twice. Video memory is ordinary RAM: a line (or a row of
// text) is read, 16 bytes at a time, into a line buffer shortly before it is shown (cpu clock side) and shown
// from there (pixel clock side). Every colour goes through the VGA palette (3C6h-3C9h).
// cx/cy come from the HDMI transmitter; rgb is its pixel for cx/cy.
`timescale 1ns/1ps
module video #(parameter FONT_HEX = "fonts/vga8x16.hex", parameter int LINES = 525) (
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
    input  logic [9:0]  crtc_lc,
    input  logic [7:0]  crtc_off,       // planar modes: words from one line to the next (CRTC 13h)
    input  logic [5:0]  cursor_start,
    input  logic [4:0]  cursor_end,
    input  logic [7:0]  vid_mode,       // 3D8h: 0 80 columns, 1 graphics, 2 mono palette, 3 on, 4 640 wide, 5 blink
    input  logic [7:0]  vid_color,      // 3D9h: 3-0 background/border, 4 bright, 5 palette
    input  logic [7:0]  vid_ctrl,       // bit 0: mode 13h; 1: planes, 2: 640 wide, 4-3: lines
    input  logic        attr_reset,     // 3DAh was read: 3C0h takes an index next
    input  logic        vio_wr, vio_rd, // ports 3C0h-3CFh
    input  logic [3:0]  vio_addr,
    input  logic [7:0]  vio_wdata,
    output logic [7:0]  vio_rdata,
    output logic        vf_req,         // read 16 bytes of RAM (vf_addr is a multiple of 16)
    output logic [22:0] vf_addr,
    input  logic [127:0] vf_rdata,
    input  logic        vf_ack
);
    localparam int TOP = LINES == 449 ? 0 : 40;                 // first line of the picture
    localparam int VS  = LINES == 449 ? 412 : 490;              // vertical sync, two lines
    wire g13   = vid_ctrl[0];
    wire planar = vid_ctrl[1];
    wire pwide  = vid_ctrl[2];
    wire p350   = planar && vid_ctrl[4:3] == 2'd1;
    wire p480   = planar && vid_ctrl[4:3] == 2'd2;
    wire gfx   = g13 || vid_mode[1] || planar;
    // where the picture is: 400 lines, or 350, or all 480
    wire [9:0] top    = p480 ? 10'd0 : p350 ? 10'd65 : 10'(TOP);
    wire [9:0] height = p480 ? 10'd480 : p350 ? 10'd350 : 10'd400;
    wire [9:0] pre    = top == 0 ? 10'(LINES - 32) : top - 10'd32;   // the first unit is asked for here
    wire cga2  = vid_mode[4];
    wire col80 = vid_mode[0];

    // ── raster position three pixels ahead (the pipeline below is three stages) ──
    wire        wrap = cx >= 10'd797;
    wire [9:0]  hx = wrap ? cx - 10'd797 : cx + 10'd3;
    wire [9:0]  hy = !wrap ? cy : (cy == 10'(LINES - 1) ? 10'd0 : cy + 10'd1);
    wire [9:0]  ty = hy - top;
    wire        in_y = hy >= top && hy < top + height;
    wire        in_x = hx < 10'd640;
    wire [4:0]  row = ty[8:4];
    wire [3:0]  scan = ty[3:0];
    wire [8:0]  gline = (p350 || p480) ? ty[8:0] : {1'b0, ty[8:1]};   // graphics line
    // split screen: the first graphics line of the lower part (line compare counts raster lines)
    wire [9:0]  split = (p350 || p480) ? crtc_lc + 10'd1 : {1'b0, crtc_lc[9:1]} + 10'd1;
    wire        below = planar && {1'b0, gline} >= split;
    logic [2:0] pan_q;
    wire [3:0]  pan  = !planar || below ? 4'd0 : pwide ? {1'b0, pan_q} : {pan_q, 1'b0};
    wire [9:0]  hxp  = hx + 10'(pan);                                  // the pixel shown at hx

    always_ff @(posedge clk_pix) begin
        hsync    <= !(cx >= 10'd656 && cx < 10'd752);
        vsync    <= (cy >= 10'(VS) && cy < 10'(VS + 2)) == (LINES == 449);    // positive with 400 lines
        blank    <= !(cx < 10'd640 && cy >= 10'(TOP) && cy < 10'(TOP + 400));
        vretrace <= cy >= 10'(VS - 4) && cy < 10'(VS + 4);
    end

    // ── ask for the next unit (a text row or a graphics line): unit 0 before the picture,
    //    unit n+1 when unit n starts ──
    logic       fetch_tgl;
    logic [8:0] fetch_unit;
    logic [5:0] frame_cnt;
    wire        unit_start = (p350 || p480) ? 1'b1 : gfx ? !ty[0] : scan == 4'd0;
    wire [8:0]  unit = gfx ? gline : {4'b0, row};
    wire [8:0]  unit_last = p480 ? 9'd479 : p350 ? 9'd349 : gfx ? 9'd199 : 9'd24;
    always_ff @(posedge clk_pix) begin
        if (hx == 10'd0) begin
            if (hy == pre) begin fetch_unit <= 9'd0; fetch_tgl <= ~fetch_tgl; end
            else if (in_y && unit_start && unit < unit_last) begin fetch_unit <= unit + 9'd1; fetch_tgl <= ~fetch_tgl; end
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
    wire  [6:0]  gcol = planar ? (pwide ? hxp[9:3] : {1'b0, hxp[9:4]}) : g13 ? hx[9:3] : {2'b0, hx[9:5]};
    always_ff @(posedge clk) if (tb_we) textbuf[tb_waddr] <= tb_wdata;
    always_ff @(posedge clk) if (gb_we) gbuf[gb_waddr] <= gb_wdata;
    always_ff @(posedge clk_pix) cell_q  <= textbuf[{row[0], tcol}];
    always_ff @(posedge clk_pix) gword_q <= gbuf[{gline[0], gcol}];

    // ── fetch (cpu clock) ──
    logic [2:0]  tgl_s;
    logic [1:0]  fst_q;                 // 0 idle, 1 read, 2 store (low half), 3 store high half
    logic [6:0]  word_q, last_q;
    logic [15:0] off_q;                 // byte offset of the unit in its segment
    logic        seg_a_q, gfx_q, buf_q, pl_q;
    wire  [7:0]  u = fetch_unit[7:0];
    wire         f_below   = {1'b0, fetch_unit} >= split;
    // planar: the lines are fetched in order, so the offset of a line is the one before plus the
    // line length (CRTC 13h; games with a picture wider than the screen set it)
    logic [15:0] lbase_q;
    wire  [15:0] lbase     = fetch_unit == 9'd0 || {1'b0, fetch_unit} == split ? 16'd0 : lbase_q;
    wire  [15:0] pl_off    = (f_below ? 16'd0 : crtc_start) + lbase;
    wire  [15:0] text_cell = crtc_start + (col80 ? {3'b0, u, 6'b0} + {5'b0, u, 4'b0} : {4'b0, u, 5'b0} + {6'b0, u, 3'b0});
    wire  [15:0] cga_off   = {2'b0, u[0], 13'b0} + {3'b0, u[7:1], 6'b0} + {5'b0, u[7:1], 4'b0};
    wire  [15:0] g13_off   = {u, 8'b0} + {2'b0, u, 6'b0};
    wire  [15:0] cur_word  = (pl_q ? off_q : {2'b0, off_q[15:2]}) + 16'(word_q);   // the word wanted now
    wire  [31:0] data      = vf_rdata[{cur_word[1:0], 5'b0} +: 32];   // stays until the next read
    wire  [7:0]  idx_lo = {word_q, 1'b0} - {7'b0, off_q[1]};         // text: cell number of the low half
    wire  [7:0]  idx_hi = idx_lo + 8'd1;
    wire         last_word = word_q == last_q;
    wire  [1:0]  next = last_word ? 2'd0 : cur_word[1:0] == 2'd3 ? 2'd1 : 2'd2;   // after this word
    assign vf_req  = fst_q == 2'd1;
    assign vf_addr = pl_q ? {5'h1F, cur_word[15:2], 4'b0}             // the planes, A0000h or B8000h
                   : seg_a_q ? {7'h0A, cur_word[13:2], 4'b0} : {8'h17, cur_word[12:2], 4'b0};
    always_ff @(posedge clk) begin
        tgl_s <= {tgl_s[1:0], fetch_tgl};
        tb_we <= 1'b0; gb_we <= 1'b0;
        case (fst_q)
            2'd0: if (tgl_s[2] != tgl_s[1]) begin
                      lbase_q <= lbase + {7'b0, crtc_off, 1'b0};
                      gfx_q <= gfx; seg_a_q <= g13; pl_q <= planar; buf_q <= u[0]; word_q <= '0; fst_q <= 2'd1;
                      off_q  <= planar ? pl_off : g13 ? g13_off : gfx ? cga_off : {text_cell[14:0], 1'b0};
                      last_q <= planar ? (pwide ? 7'd80 : 7'd40) : g13 ? 7'd79 : gfx ? 7'd19 : 7'd40;
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
    // the attribute palette: 3C0h takes an index, then the value (16 registers of 6 bits)
    logic [5:0] attr [0:15];
    logic [4:0] attr_idx_q;
    logic       attr_ff_q;
    always_ff @(posedge clk) begin
        if (vio_wr && vio_addr == 4'h0) begin
            attr_ff_q <= !attr_ff_q;
            if (!attr_ff_q) attr_idx_q <= vio_wdata[4:0];
            else if (!attr_idx_q[4]) attr[attr_idx_q[3:0]] <= vio_wdata[5:0];
            else if (attr_idx_q == 5'h13) pan_q <= vio_wdata[2:0];
        end
        if (attr_reset || reset) attr_ff_q <= 1'b0;
        if (reset) pan_q <= '0;
    end
    always_comb case (vio_addr)
        4'h0: vio_rdata = {3'b001, attr_idx_q};
        4'h1: vio_rdata = {2'b00, attr[attr_idx_q[3:0]]};
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
    wire  [2:0] pbit = ~(pwide ? hx1_q[2:0] : hx1_q[3:1]);     // planes: bit 7 is the left pixel
    logic [1:0] c2;
    always_comb begin
        gbyte = g13 ? gword_q[{hx1_q[2:1], 3'b0} +: 8] : gword_q[{hx1_q[4:3], 3'b0} +: 8];
        c2    = gbyte[{~hx1_q[2:1], 1'b0} +: 2];
        if (planar) gidx = {2'b00, attr[{gword_q[5'd24 + pbit], gword_q[5'd16 + pbit], gword_q[5'd8 + pbit], gword_q[{2'b00, pbit}]}]};
        else if (g13) gidx = gbyte;
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
        hx1_q   <= hxp[4:0];
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
