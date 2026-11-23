// Between the machine and the SDRAM controller (gw2ar_sdram).
// Two clients: the video line fetch (first) and the CPU (16-bit accesses).
//
// A cache in block RAM keeps what was read: 2048 lines of 16 bytes (32 KB), one line per
// place (the line of address A is kept at A[14:4]). A read looks there first; if the line is
// not there, the 16 bytes are read from the SDRAM in one burst and kept. A write goes to the
// SDRAM and, if its line is kept, into the cache as well, so the cache is always true. The
// CPU is told at once that a write is done and goes on while the SDRAM takes it; reads the
// cache can answer are answered meanwhile (also during a video read).
// Video reads 16 bytes at a time; they stay in vf_rdata until its next read.
`timescale 1ns/1ps
module cache_ram #(parameter int W = 8, parameter int A = 11) (
    input  logic         clk,
    input  logic         we,
    input  logic [A-1:0] wa,
    input  logic [W-1:0] wd,
    input  logic [A-1:0] ra,
    output logic [W-1:0] rd
);
    logic [W-1:0] mem [0:(1 << A) - 1];
    always_ff @(posedge clk) begin
        if (we) mem[wa] <= wd;
        rd <= mem[ra];
    end
endmodule

module sdram_bridge (
    input  logic        clk,
    input  logic        reset,
    // CPU
    input  logic        mem_req,
    input  logic        mem_fetch,      // the read is code (not used: all reads are alike)
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
    typedef enum logic [1:0] {IDLE, BUSY, DONE, CLEAR} state_t;
    state_t st_q;
    logic        owner_video_q;
    logic        lk_q;                  // the cache's answer for the present request is in
    logic [10:0] clr_q;
    logic [8:0]  ref_q;
    assign sd_refresh = ref_q[8];
    assign sd_burst   = sd_read;

    wire above   = mem_addr[23];                      // nothing above 8 MB
    wire cpu_new = mem_req && !mem_ack;

    // ── the cache ──
    logic [127:0] line;                 // the line at mem_addr[14:4], a clock later
    logic [8:0]   tag;                  // which line that is: {kept, address 22:15}
    wire hit   = tag[8] && tag[7:0] == mem_addr[22:15];
    wire take  = cpu_new && lk_q && !above;
    wire vid_go = st_q == IDLE && vf_req && !vf_ack;
    wire can_go = st_q == IDLE && !vid_go;
    wire rd_hit = take && !mem_we && hit;
    wire rd_go  = take && !mem_we && !hit && can_go;  // read the line from the SDRAM
    wire wr_go  = take && mem_we && can_go;
    wire fill   = st_q == BUSY && sd_complete && !owner_video_q && sd_read;
    wire clear  = st_q == CLEAR;

    cache_ram #(.W(9)) tags (.clk, .we(fill || clear), .wa(clear ? clr_q : sd_addr[14:4]),
        .wd(clear ? 9'd0 : {1'b1, sd_addr[22:15]}), .ra(mem_addr[14:4]), .rd(tag));
    for (genvar i = 0; i < 16; i++) begin : lane
        wire upd = wr_go && hit && mem_addr[3:1] == 3'(i / 2) && mem_be[i % 2];
        cache_ram bytes (.clk, .we(fill || upd), .wa(fill ? sd_addr[14:4] : mem_addr[14:4]),
            .wd(fill ? sd_brdata[i*8 +: 8] : mem_wdata[(i % 2)*8 +: 8]),
            .ra(mem_addr[14:4]), .rd(line[i*8 +: 8]));
    end

    always_ff @(posedge clk) begin
        mem_ack <= 1'b0; vf_ack <= 1'b0;
        ref_q <= ref_q + 9'd1;
        // the answer is in a clock after the request, if the cache was not written meanwhile
        lk_q <= cpu_new && !fill && !clear && !(rd_hit || wr_go);
        if (cpu_new && above) begin mem_ack <= 1'b1; mem_rdata <= 16'hFFFF; end
        if (rd_hit) begin mem_ack <= 1'b1; mem_rdata <= line[{mem_addr[3:1], 4'b0} +: 16]; end
        case (st_q)
            IDLE: begin
                if (vid_go) begin
                    owner_video_q <= 1'b1;
                    sd_addr <= vf_addr; sd_read <= 1'b1; sd_write <= 1'b0;
                    sd_req <= 1'b1; st_q <= BUSY;
                end else if (rd_go || wr_go) begin
                    owner_video_q <= 1'b0;
                    sd_read <= !mem_we; sd_write <= mem_we;
                    sd_addr <= mem_we ? {mem_addr[22:2], 2'b00} : {mem_addr[22:4], 4'b0};
                    sd_wdata <= {mem_wdata, mem_wdata};
                    sd_wmask <= mem_addr[1] ? {mem_be, 2'b00} : {2'b00, mem_be};
                    sd_req <= 1'b1; st_q <= BUSY;
                    if (mem_we) mem_ack <= 1'b1;         // the CPU goes on
                end
            end
            BUSY: if (sd_complete) begin
                sd_req <= 1'b0; st_q <= DONE;
                if (owner_video_q) begin vf_rdata <= sd_brdata; vf_ack <= 1'b1; end
            end                                          // a CPU read: the line is now kept, see 'fill'
            DONE: st_q <= IDLE;
            CLEAR: begin                                 // after reset: nothing is kept
                clr_q <= clr_q + 11'd1;
                if (clr_q == '1) st_q <= IDLE;
            end
        endcase
        if (reset) begin
            st_q <= CLEAR; clr_q <= '0; lk_q <= 1'b0;
            sd_req <= 1'b0; sd_read <= 1'b0; sd_write <= 1'b0;
            mem_ack <= 1'b0; vf_ack <= 1'b0;
        end
    end
endmodule
