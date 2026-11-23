// Keyboard and mouse from a CH9350 (or a Pico acting as one): UART, 115200 8N1.
//   57 AB 88 len type ... serial sum   type 10/11: keyboard report (modifiers, 0, six keys)
//                                      type 2x:    mouse report (buttons, dx, dy, wheel)
// Key reports are turned into PC scancodes (set 1): make and break codes, the E0 prefix,
// and the repeat of a held key (0.5 s, then 15 a second), as a PC keyboard sends them.
`timescale 1ns/1ps
module kbd_ch9350 #(parameter int CLK_HZ = 25_312_500, parameter int BAUD = 115200,
                    parameter HID_TABLE = "build/hid_table.hex") (
    input  logic       clk,
    input  logic       reset,
    input  logic       rx,
    output logic       sc_valid,
    output logic [7:0] sc_data,
    input  logic       sc_ready,
    output logic       mouse_valid,     // one cycle per mouse report
    output logic [2:0] mouse_btn,
    output logic [7:0] mouse_dx, mouse_dy
);
    // ── UART receiver ──
    localparam int DIV = CLK_HZ / BAUD;
    logic [2:0]  rx_s;
    logic [15:0] ucnt_q;
    logic [3:0]  ubit_q;            // 0 = idle, 1 = start, 2..9 = data, 10 = stop
    logic [7:0]  ush_q, byte_q;
    logic        byte_valid;
    always_ff @(posedge clk) begin
        rx_s <= {rx_s[1:0], rx};
        byte_valid <= 1'b0;
        if (ubit_q == 0) begin
            if (!rx_s[2]) begin ubit_q <= 4'd1; ucnt_q <= 16'(DIV / 2); end
        end else if (ucnt_q == 0) begin
            ucnt_q <= 16'(DIV - 1);
            if (ubit_q == 1) ubit_q <= rx_s[2] ? 4'd0 : 4'd2;
            else if (ubit_q == 10) begin ubit_q <= 4'd0; if (rx_s[2]) begin byte_q <= ush_q; byte_valid <= 1'b1; end end
            else begin ush_q <= {rx_s[2], ush_q[7:1]}; ubit_q <= ubit_q + 4'd1; end
        end else ucnt_q <= ucnt_q - 16'd1;
        if (reset) begin ubit_q <= 4'd0; rx_s <= 3'b111; end
    end

    // ── frames ──
    logic [2:0] fst_q;              // 0 idle, 1 AB, 2 cmd, 3 len, 4 data
    logic [4:0] flen_q, fidx_q;
    logic [7:0] fcmd_q, ftype_q, fsum_q;
    logic [7:0] new_mod_q, new_key_q [6];
    logic [7:0] m_btn_q, m_dx_q, m_dy_q;
    logic       report_q;           // a good keyboard report is in new_*
    wire report_cmd = fcmd_q == 8'h88 || fcmd_q == 8'h83;
    always_ff @(posedge clk) begin
        report_q <= 1'b0; mouse_valid <= 1'b0;
        if (byte_valid) case (fst_q)
            3'd0: if (byte_q == 8'h57) fst_q <= 3'd1;
            3'd1: fst_q <= byte_q == 8'hAB ? 3'd2 : byte_q == 8'h57 ? 3'd1 : 3'd0;
            3'd2: begin fcmd_q <= byte_q; fst_q <= 3'd3; end
            3'd3: begin flen_q <= byte_q[4:0]; fidx_q <= '0; fsum_q <= '0;
                        fst_q <= (byte_q != 0 && byte_q <= 8'd16) ? 3'd4 : 3'd0; end
            default: begin
                fidx_q <= fidx_q + 5'd1;
                if (fidx_q == 0) ftype_q <= byte_q;
                else if (fidx_q + 5'd1 != flen_q) fsum_q <= fsum_q + byte_q;
                if (fidx_q == 1) begin new_mod_q <= byte_q; m_btn_q <= byte_q; end
                if (fidx_q == 2) m_dx_q <= byte_q;
                if (fidx_q == 3) m_dy_q <= byte_q;
                if (fidx_q >= 3 && fidx_q <= 8) new_key_q[fidx_q - 3] <= byte_q;
                if (fidx_q + 5'd1 == flen_q) begin       // the sum is with or without the type byte
                    fst_q <= 3'd0;
                    if (report_cmd && (byte_q == fsum_q || byte_q == 8'(fsum_q + ftype_q))) begin
                        if (ftype_q[7:1] == 7'h08 && flen_q >= 5'd10) report_q <= 1'b1;
                        if (ftype_q[7:4] == 4'h2 && flen_q >= 5'd5) begin
                            mouse_valid <= 1'b1; mouse_btn <= m_btn_q[2:0]; mouse_dx <= m_dx_q; mouse_dy <= m_dy_q;
                        end
                    end
                end
            end
        endcase
        if (reset) fst_q <= 3'd0;
    end

    // ── report -> make / break codes ──
    logic [7:0] table_rom [0:255];
    initial $readmemh(HID_TABLE, table_rom);
    logic [7:0] tbl_addr, tbl_q;
    always_ff @(posedge clk) tbl_q <= table_rom[tbl_addr];

    logic [7:0] cur_mod_q, cur_key_q [6], pend_mod_q, pend_key_q [6];
    logic       pend_q;
    logic [2:0] st_q;               // 0 idle, 1 scan, 2 lookup, 3 emit prefix, 4 emit code
    logic [4:0] step_q;             // 0-7 modifiers, 8-13 released keys, 14-19 pressed keys
    logic       brk_q;
    logic [7:0] rep_key_q;          // the key that repeats (0 = none)
    logic [24:0] rep_cnt_q;
    logic       rep_fire_q;

    // 16-entry scancode FIFO
    logic [7:0] fifo [0:15];
    logic [4:0] wp_q, rp_q;
    wire fifo_full  = (wp_q ^ rp_q) == 5'b10000;
    wire fifo_room2 = (wp_q - rp_q) <= 5'd14;
    assign sc_valid = wp_q != rp_q;
    assign sc_data  = fifo[rp_q[3:0]];
    logic       push;
    logic [7:0] push_data;
    always_ff @(posedge clk) begin
        if (push && !fifo_full) begin fifo[wp_q[3:0]] <= push_data; wp_q <= wp_q + 5'd1; end
        if (sc_valid && sc_ready) rp_q <= rp_q + 5'd1;
        if (reset) begin wp_q <= '0; rp_q <= '0; end
    end

    function automatic logic in_set(input logic [7:0] k, input logic [7:0] s [6]);
        return k == s[0] || k == s[1] || k == s[2] || k == s[3] || k == s[4] || k == s[5];
    endfunction

    wire [2:0] ki = 3'(step_q >= 5'd14 ? step_q - 5'd14 : step_q - 5'd8);
    logic       hit;                // this step produces a code
    logic [7:0] hit_usage;
    logic       hit_brk;
    always_comb begin
        hit = 1'b0; hit_usage = 8'h00; hit_brk = 1'b0;
        if (step_q < 5'd8) begin
            hit = cur_mod_q[step_q[2:0]] != pend_mod_q[step_q[2:0]];
            hit_usage = {5'b11100, step_q[2:0]}; hit_brk = cur_mod_q[step_q[2:0]];
        end else if (step_q < 5'd14) begin
            hit = cur_key_q[ki] >= 8'd4 && !in_set(cur_key_q[ki], pend_key_q);
            hit_usage = cur_key_q[ki]; hit_brk = 1'b1;
        end else begin
            hit = pend_key_q[ki] >= 8'd4 && !in_set(pend_key_q[ki], cur_key_q);
            hit_usage = pend_key_q[ki];
        end
    end

    localparam int REP_DELAY = CLK_HZ / 2, REP_RATE = CLK_HZ / 15;
    always_ff @(posedge clk) begin
        push <= 1'b0;
        if (report_q) begin pend_mod_q <= new_mod_q; pend_key_q <= new_key_q; pend_q <= 1'b1; end
        if (rep_key_q != 0) begin
            if (rep_cnt_q == 0) begin rep_fire_q <= 1'b1; rep_cnt_q <= 25'(REP_RATE); end
            else rep_cnt_q <= rep_cnt_q - 25'd1;
        end
        case (st_q)
            3'd0: if (pend_q && !report_q) begin pend_q <= 1'b0; step_q <= '0; st_q <= 3'd1; end
                  else if (rep_fire_q) begin
                      rep_fire_q <= 1'b0;
                      if (rep_key_q != 0) begin tbl_addr <= rep_key_q; brk_q <= 1'b0; step_q <= 5'd31; st_q <= 3'd2; end
                  end
            3'd1: if (step_q == 5'd20) begin
                      cur_mod_q <= pend_mod_q; cur_key_q <= pend_key_q; st_q <= 3'd0;
                      if (rep_key_q != 0 && !in_set(rep_key_q, pend_key_q)) rep_key_q <= 8'h00;
                  end else if (hit) begin
                      tbl_addr <= hit_usage; brk_q <= hit_brk; st_q <= 3'd2;
                      if (step_q >= 5'd14) begin rep_key_q <= hit_usage; rep_cnt_q <= 25'(REP_DELAY); rep_fire_q <= 1'b0; end
                  end else step_q <= step_q + 5'd1;
            3'd2: st_q <= 3'd3;                          // table read
            3'd3: if (tbl_q[6:0] == 0) st_q <= 3'd5;
                  else if (!tbl_q[7]) st_q <= 3'd4;
                  else if (fifo_room2) begin push <= 1'b1; push_data <= 8'hE0; st_q <= 3'd4; end
            3'd4: if (!fifo_full && !push) begin push <= 1'b1; push_data <= {brk_q, tbl_q[6:0]}; st_q <= 3'd5; end
            default: begin
                if (step_q == 5'd31) st_q <= 3'd0;       // a repeat
                else begin step_q <= step_q + 5'd1; st_q <= 3'd1; end
            end
        endcase
        if (reset) begin
            st_q <= 3'd0; pend_q <= 1'b0; cur_mod_q <= '0; rep_key_q <= '0; rep_fire_q <= 1'b0;
            for (int i = 0; i < 6; i++) cur_key_q[i] <= 8'h00;
        end
    end
endmodule
