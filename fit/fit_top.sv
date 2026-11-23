// Fit experiment: SPK286 (through its 80286-pin adapter) on a GW2AR-18.
// Pins are folded into shift registers so the design fits the package and nothing is optimised away.
module fit_top (input logic clk, input logic rst, input logic si, output logic so);
    logic [31:0] in_q;
    logic [63:0] out_q;
    logic [23:0] a; logic [15:0] d_out;
    logic bhe_n, s1_n, s0_n, m_io, cod_inta_n, bus_oe, d_oe, lock_n, hlda, peack_n, halted, shutdown;
    spk286_native cpu (
        .clk(clk), .reset(in_q[31]), .timing_policy(2'b00),
        .a(a), .bhe_n(bhe_n), .s1_n(s1_n), .s0_n(s0_n), .m_io(m_io), .cod_inta_n(cod_inta_n), .bus_oe(bus_oe),
        .d_in(in_q[15:0]), .d_out(d_out), .d_oe(d_oe), .lock_n(lock_n),
        .ready_n(in_q[16]), .hold(in_q[17]), .hlda(hlda), .intr(in_q[18]), .nmi(in_q[19]),
        .pereq(1'b0), .busy_n(1'b1), .error_n(1'b1), .peack_n(peack_n), .halted(halted), .shutdown(shutdown));
    always_ff @(posedge clk) begin
        in_q <= rst ? 32'h8000_0000 : {in_q[30:0], si};
        out_q <= in_q[20] ? {a, d_out, bhe_n, s1_n, s0_n, m_io, cod_inta_n, bus_oe, d_oe, lock_n, hlda, peack_n, halted, shutdown, 12'b0}
                          : {out_q[62:0], 1'b0};
    end
    assign so = out_q[63];
endmodule
