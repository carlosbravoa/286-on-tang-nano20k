// Between the machine and the SDRAM controller (gw2ar_sdram).
// Two clients: the video line fetch (first) and the CPU (16-bit accesses).
// Reads are kept so that what follows costs no SDRAM access:
//   code    16 bytes at a time (a burst of four words from an address that is a multiple of 16)
//   data    the 32-bit word that was read
// A write goes to the SDRAM and to the data word if it is that one; kept code that is written
// to is forgotten. Video reads 16 bytes at a time; they stay in vf_rdata until its next read.
`timescale 1ns/1ps
module sdram_bridge (
    input  logic        clk,
    input  logic        reset,
    // CPU
    input  logic        mem_req,
    input  logic        mem_fetch,      // the read is code
    input  logic        mem_we,
    input  logic [23:0] mem_addr,
    input  logic [1:0]  mem_be,
    input  logic [15:0] mem_wdata,
    output logic [15:0] mem_rdata,
    output logic        mem_ack,
    // video: 16 bytes from vf_addr (a multiple of 16)
    input  logic        vf_req,
    input  logic [22:0] vf_addr,
    output logic [127:0] vf_rdata,
    output logic        vf_ack,
    // SDRAM controller: req held until complete, then low for a cycle
    output logic        sd_req,
    output logic        sd_read, sd_write,
    output logic        sd_burst,       // with sd_read: four words, in sd_brdata
    output logic [22:0] sd_addr,
    output logic [31:0] sd_wdata,
    output logic [3:0]  sd_wmask,
    input  logic [31:0] sd_rdata,
    input  logic [127:0] sd_brdata,
    input  logic        sd_complete,
    output logic        sd_refresh
);
    typedef enum logic [1:0] {IDLE, BUSY, DONE} state_t;
    state_t st_q;
    logic        owner_video_q;
    logic        sel_q;                 // which half of the word that comes back the CPU wants
    logic        c_valid_q, d_valid_q;
    logic [18:0] c_tag_q;               // code: 16 bytes
    logic [127:0] c_data_q;
    logic [20:0] d_tag_q;               // data: 4 bytes
    logic [31:0] d_data_q;
    logic [8:0]  ref_q;

    wire above   = mem_addr[23];                      // nothing above 8 MB
    wire c_hit   = c_valid_q && c_tag_q == mem_addr[22:4];
    wire d_hit   = d_valid_q && d_tag_q == mem_addr[22:2];
    wire cpu_new = mem_req && !mem_ack;
    wire [3:0] cpu_mask = mem_addr[1] ? {mem_be, 2'b00} : {2'b00, mem_be};
    assign sd_refresh = ref_q[8];

    always_ff @(posedge clk) begin
        mem_ack <= 1'b0; vf_ack <= 1'b0;
        ref_q <= ref_q + 9'd1;
        case (st_q)
            IDLE: begin
                if (vf_req && !vf_ack) begin
                    owner_video_q <= 1'b1; sd_addr <= vf_addr; sd_read <= 1'b1; sd_write <= 1'b0; sd_burst <= 1'b1;
                    sd_req <= 1'b1; st_q <= BUSY;
                end else if (cpu_new && above) begin
                    mem_ack <= 1'b1; mem_rdata <= 16'hFFFF;
                end else if (cpu_new && !mem_we && c_hit) begin
                    mem_ack <= 1'b1; mem_rdata <= c_data_q[{mem_addr[3:1], 4'b0} +: 16];
                end else if (cpu_new && !mem_we && d_hit) begin
                    mem_ack <= 1'b1; mem_rdata <= mem_addr[1] ? d_data_q[31:16] : d_data_q[15:0];
                end else if (cpu_new) begin
                    owner_video_q <= 1'b0;
                    sd_read <= !mem_we; sd_write <= mem_we; sd_burst <= !mem_we && mem_fetch;
                    sd_addr <= !mem_we && mem_fetch ? {mem_addr[22:4], 4'b0} : {mem_addr[22:2], 2'b00};
                    sel_q   <= mem_addr[1];
                    sd_wdata <= {mem_wdata, mem_wdata}; sd_wmask <= cpu_mask;
                    sd_req <= 1'b1; st_q <= BUSY;
                    if (mem_we) begin                    // keep what is kept true
                        if (c_hit) c_valid_q <= 1'b0;    // a write into the code that is kept: forget it
                        for (int i = 0; i < 4; i++)
                            if (cpu_mask[i] && d_hit) d_data_q[i*8 +: 8] <= i[0] ? mem_wdata[15:8] : mem_wdata[7:0];
                    end
                end
            end
            BUSY: if (sd_complete) begin
                sd_req <= 1'b0; st_q <= DONE;
                if (owner_video_q) begin vf_rdata <= sd_brdata; vf_ack <= 1'b1; end
                else begin
                    if (sd_burst) begin                  // the CPU gets its word from what is kept, next
                        c_valid_q <= 1'b1; c_tag_q <= sd_addr[22:4]; c_data_q <= sd_brdata;
                    end else begin
                        mem_ack <= 1'b1;
                        mem_rdata <= sel_q ? sd_rdata[31:16] : sd_rdata[15:0];
                        if (sd_read) begin d_valid_q <= 1'b1; d_tag_q <= sd_addr[22:2]; d_data_q <= sd_rdata; end
                    end
                end
            end
            default: st_q <= IDLE;
        endcase
        if (reset) begin
            st_q <= IDLE; sd_req <= 1'b0; sd_read <= 1'b0; sd_write <= 1'b0; sd_burst <= 1'b0;
            c_valid_q <= 1'b0; d_valid_q <= 1'b0; mem_ack <= 1'b0; vf_ack <= 1'b0;
        end
    end
endmodule
