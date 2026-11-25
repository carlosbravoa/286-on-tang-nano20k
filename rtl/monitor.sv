// Remote control of the machine, on the board's USB serial port (115200 8N1): a program on
// another computer (tools/pc286ctl.py) types keys, moves the mouse, reads and writes the
// RAM and presses reset. The machine itself knows nothing of it.
//
// A command is a letter and its bytes; every command is answered:
//   ?            who is there                       answer 87h (86h: a monitor without W)
//   K code       a key code (scancode set 1), as if the keyboard had sent it      'K'
//   M b dx dy    a mouse report: buttons, movement right and down (signed)        'M'
//   A hi mid lo  the address for r and w (23 bits; the EGA planes are at 7C0000h) 'A'
//   r n          read n+1 bytes; the address moves on                             the bytes
//   w byte       write a byte; the address moves on                               'w'
//   W n bytes    write n+1 bytes; the address moves on                            'W' at the end
//   R            reset the machine (not its RAM)                                  'R'
// The answers share the wire with the BIOS' text. A byte of an answer is sent as two:
// A0h + its high half, then B0h + its low half; the text never has bytes A0h-BFh (the
// system turns those into dots).
`timescale 1ns/1ps
module monitor #(parameter int CLK_HZ = 25_312_500, parameter int BAUD = 115200) (
    input  logic        clk,
    input  logic        reset,          // of the board; not the one this module makes
    input  logic        rx,
    output logic        tx_valid,       // a byte for the serial output
    output logic [7:0]  tx_data,
    input  logic        tx_ready,
    output logic        sc_valid,       // key code
    output logic [7:0]  sc_data,
    input  logic        sc_ready,
    output logic        mouse_valid,    // one cycle
    output logic [2:0]  mouse_btn,
    output logic [7:0]  mouse_dx, mouse_dy,
    output logic        m_req,          // a byte of RAM, read or written
    output logic        m_we,
    output logic [22:0] m_addr,
    output logic [7:0]  m_wdata,
    input  logic [7:0]  m_rdata,
    input  logic        m_ack,
    output logic        machine_reset
);
    // ── serial input ──
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

    // ── commands ──
    typedef enum logic [2:0] {IDLE, ARGS, KEY, MEM, MEMEND, SEND_HI, SEND_LO, BLOCK} state_t;
    state_t      st_q;
    logic [7:0]  cmd_q, out_q, left_q;
    logic [1:0]  nargs_q;
    logic [23:0] arg_q;
    logic [7:0]  rst_q;
    logic        more_q;            // after the answer: the next byte of a read
    assign sc_valid = st_q == KEY;
    assign sc_data  = arg_q[7:0];
    assign m_req    = st_q == MEM;
    assign m_we     = cmd_q == "w" || cmd_q == "W";
    assign m_wdata  = arg_q[7:0];
    assign tx_valid = st_q == SEND_HI || st_q == SEND_LO;
    assign tx_data  = st_q == SEND_HI ? {4'hA, out_q[7:4]} : {4'hB, out_q[3:0]};
    assign machine_reset = rst_q != 0;
    assign mouse_btn = arg_q[18:16];
    assign mouse_dx  = arg_q[15:8];
    assign mouse_dy  = arg_q[7:0];

    wire [23:0] arg = {arg_q[15:0], byte_q};
    always_ff @(posedge clk) begin
        mouse_valid <= 1'b0;
        if (rst_q != 0) rst_q <= rst_q - 8'd1;
        case (st_q)
            IDLE: ;
            ARGS: if (byte_valid) begin
                arg_q <= arg; nargs_q <= nargs_q - 2'd1;
                if (nargs_q == 2'd1) begin
                    out_q <= cmd_q; more_q <= 1'b0; st_q <= SEND_HI;
                    case (cmd_q)
                        "K": st_q <= KEY;
                        "M": mouse_valid <= 1'b1;
                        "A": m_addr <= arg[22:0];
                        "r": begin left_q <= byte_q; st_q <= MEM; end
                        "W": begin left_q <= byte_q; st_q <= BLOCK; end
                        default: st_q <= MEM;                       // w
                    endcase
                end
            end
            KEY: if (sc_ready) st_q <= SEND_HI;
            MEM: if (m_ack) st_q <= MEMEND;
            MEMEND: begin
                m_addr <= m_addr + 23'd1; st_q <= SEND_HI;
                if (cmd_q == "r") begin out_q <= m_rdata; more_q <= left_q != 0; left_q <= left_q - 8'd1; end
                if (cmd_q == "W") begin left_q <= left_q - 8'd1; if (left_q != 0) st_q <= BLOCK; end
            end
            BLOCK: if (byte_valid) begin arg_q[7:0] <= byte_q; st_q <= MEM; end
            SEND_HI: if (tx_ready) st_q <= SEND_LO;
            SEND_LO: if (tx_ready) st_q <= more_q ? MEM : IDLE;
            default: st_q <= IDLE;
        endcase
        // a new command, also while a key waits to be taken (the keyboard may be switched off)
        if (byte_valid && (st_q == IDLE || st_q == KEY)) begin
            cmd_q <= byte_q; out_q <= byte_q; more_q <= 1'b0; st_q <= IDLE;
            case (byte_q)
                "?": begin out_q <= 8'h87; st_q <= SEND_HI; end
                "R": begin rst_q <= '1; st_q <= SEND_HI; end
                "K", "r", "w", "W": begin nargs_q <= 2'd1; st_q <= ARGS; end
                "M", "A": begin nargs_q <= 2'd3; st_q <= ARGS; end
                default: ;
            endcase
        end
        if (reset) begin st_q <= IDLE; rst_q <= '0; end
    end
endmodule
