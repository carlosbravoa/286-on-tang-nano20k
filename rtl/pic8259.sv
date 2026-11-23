// 8259A interrupt controller, the part PC software uses: ICW1-4, mask, EOI (specific and
// non-specific), IRR/ISR read, edge triggered, fixed priority. No AEOI, poll or rotation.
`timescale 1ns/1ps
module pic8259 (
    input  logic       clk,
    input  logic       reset,
    input  logic       a0,
    input  logic       wr,          // one-cycle write strobe
    input  logic [7:0] wdata,
    output logic [7:0] rdata,
    input  logic [7:0] irq,         // request lines, active high
    output logic       intr,
    input  logic       ack,         // one cycle: accept the request shown on irq_num
    output logic [2:0] irq_num,     // highest pending request (7 when none: spurious)
    output logic [7:0] vector
);
    logic [7:0] irq_d, edge_q, isr_q, imr_q;
    logic [4:0] base_q;
    logic [1:0] icw_step_q;         // 0 = operating, 1..3 = expecting ICW2..4
    logic       icw4_q, read_isr_q;

    wire [7:0] pending = edge_q & irq & ~imr_q;

    function automatic logic [3:0] first(input logic [7:0] v);  // {found, index}
        for (int i = 0; i < 8; i++) if (v[i]) return {1'b1, 3'(i)};
        return 4'b0111;
    endfunction
    wire [3:0] pend_first = first(pending);
    wire [3:0] isr_first  = first(isr_q);

    assign irq_num = pend_first[2:0];
    assign intr    = pend_first[3] && (!isr_first[3] || pend_first[2:0] < isr_first[2:0]);
    assign vector  = {base_q, irq_num};
    assign rdata   = a0 ? imr_q : (read_isr_q ? isr_q : (edge_q & irq));

    always_ff @(posedge clk) begin
        irq_d  <= irq;
        edge_q <= (edge_q | (irq & ~irq_d)) & irq;      // a request that goes away is dropped
        if (ack && pend_first[3]) begin
            isr_q[irq_num]  <= 1'b1;
            edge_q[irq_num] <= 1'b0;
        end
        if (wr) begin
            if (!a0 && wdata[4]) begin                   // ICW1
                icw_step_q <= 2'd1; icw4_q <= wdata[0];
                imr_q <= 8'h00; isr_q <= 8'h00; edge_q <= 8'h00; read_isr_q <= 1'b0;
            end else if (a0 && icw_step_q != 0) begin
                case (icw_step_q)
                    2'd1: begin base_q <= wdata[7:3]; icw_step_q <= 2'd2; end
                    2'd2: icw_step_q <= icw4_q ? 2'd3 : 2'd0;
                    default: icw_step_q <= 2'd0;
                endcase
            end else if (a0) imr_q <= wdata;             // OCW1
            else if (!wdata[3]) begin                    // OCW2
                if (wdata[5]) begin                      // EOI
                    if (wdata[6]) isr_q[wdata[2:0]] <= 1'b0;
                    else if (isr_first[3]) isr_q[isr_first[2:0]] <= 1'b0;
                end
            end else if (wdata[1]) read_isr_q <= wdata[0];  // OCW3
        end
        if (reset) begin
            edge_q <= 8'h00; isr_q <= 8'h00; imr_q <= 8'hFF; base_q <= 5'd1;
            icw_step_q <= 2'd0; icw4_q <= 1'b0; read_isr_q <= 1'b0; irq_d <= 8'h00;
        end
    end
endmodule
