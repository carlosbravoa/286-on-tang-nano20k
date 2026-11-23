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
// The Sound Blaster reads single bytes (a plain SDRAM read; the SDRAM always has what was written).
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
    // sound: one byte
    input  logic        dm_req,
    input  logic [22:0] dm_addr,
    output logic [7:0]  dm_rdata,
    output logic        dm_ack,
    // the EGA planes: one 32-bit word, read or written (px_addr = word number in their 256 KB)
    input  logic        px_req,
    input  logic        px_we,
    input  logic [15:0] px_addr,
    input  logic [31:0] px_wdata,
    input  logic [3:0]  px_wmask,
    output logic [31:0] px_rdata,
    output logic        px_ack,
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
    logic        owner_video_q, owner_dma_q, owner_px_q;
    logic        lk_q;                  // the cache's answer for the present request is in
    logic [10:0] clr_q;
    logic [8:0]  ref_q;
    assign sd_refresh = ref_q[8];
    assign sd_burst   = sd_read && !owner_dma_q && !owner_px_q;

    wire above   = mem_addr[23];                      // nothing above 8 MB
    wire cpu_new = mem_req;             // a request ends in the clock of its mem_ack

    // ── the cache ──
    logic [127:0] line;                 // the line at mem_addr[14:4], a clock later
    logic [8:0]   tag;                  // which line that is: {kept, address 22:15}
    wire hit   = tag[8] && tag[7:0] == mem_addr[22:15];
    wire take  = cpu_new && lk_q && !above;
    wire free   = st_q == IDLE || st_q == DONE;       // sd_req is low: the next access can start
    wire vid_go = free && vf_req && !vf_ack;
    wire dma_go = free && !vid_go && dm_req && !dm_ack;
    wire px_go  = free && !vid_go && !dma_go && px_req && !px_ack;
    wire can_go = free && !vid_go && !dma_go && !px_go;
    wire rd_go  = take && !mem_we && !hit && can_go;  // read the line from the SDRAM
    wire wr_go  = take && mem_we && can_go;
    wire fill   = st_q == BUSY && sd_complete && !owner_video_q && !owner_dma_q && !owner_px_q && sd_read;
    wire clear  = st_q == CLEAR;
    // The answer goes to the CPU in the same clock: a kept read takes two clocks in all.
    assign mem_ack   = cpu_new && (above || (lk_q && (mem_we ? can_go : hit)));
    assign mem_rdata = above ? 16'hFFFF : line[{mem_addr[3:1], 4'b0} +: 16];

    cache_ram #(.W(9)) tags (.clk, .we(fill || clear), .wa(clear ? clr_q : sd_addr[14:4]),
        .wd(clear ? 9'd0 : {1'b1, sd_addr[22:15]}), .ra(mem_addr[14:4]), .rd(tag));
    for (genvar i = 0; i < 16; i++) begin : lane
        wire upd = wr_go && hit && mem_addr[3:1] == 3'(i / 2) && mem_be[i % 2];
        cache_ram bytes (.clk, .we(fill || upd), .wa(fill ? sd_addr[14:4] : mem_addr[14:4]),
            .wd(fill ? sd_brdata[i*8 +: 8] : mem_wdata[(i % 2)*8 +: 8]),
            .ra(mem_addr[14:4]), .rd(line[i*8 +: 8]));
    end

    always_ff @(posedge clk) begin
        vf_ack <= 1'b0; dm_ack <= 1'b0; px_ack <= 1'b0;
        ref_q <= ref_q + 9'd1;
        // the answer is in a clock after the request, if the cache was not written meanwhile
        lk_q <= cpu_new && !mem_ack && !fill && !clear;
        case (st_q)
            IDLE, DONE: begin
                st_q <= IDLE;
                if (vid_go) begin
                    owner_video_q <= 1'b1; owner_dma_q <= 1'b0; owner_px_q <= 1'b0;
                    sd_addr <= vf_addr; sd_read <= 1'b1; sd_write <= 1'b0;
                    sd_req <= 1'b1; st_q <= BUSY;
                end else if (dma_go) begin
                    owner_video_q <= 1'b0; owner_dma_q <= 1'b1; owner_px_q <= 1'b0;
                    sd_addr <= {dm_addr[22:2], 2'b00}; sd_read <= 1'b1; sd_write <= 1'b0;
                    sd_req <= 1'b1; st_q <= BUSY;
                end else if (px_go) begin               // the planes are the top 256 KB of the SDRAM
                    owner_video_q <= 1'b0; owner_dma_q <= 1'b0; owner_px_q <= 1'b1;
                    sd_addr <= {5'h1F, px_addr, 2'b00}; sd_read <= !px_we; sd_write <= px_we;
                    sd_wdata <= px_wdata; sd_wmask <= px_wmask;
                    sd_req <= 1'b1; st_q <= BUSY;
                end else if (rd_go || wr_go) begin
                    owner_video_q <= 1'b0; owner_dma_q <= 1'b0; owner_px_q <= 1'b0;
                    sd_read <= !mem_we; sd_write <= mem_we;
                    sd_addr <= mem_we ? {mem_addr[22:2], 2'b00} : {mem_addr[22:4], 4'b0};
                    sd_wdata <= {mem_wdata, mem_wdata};
                    sd_wmask <= mem_addr[1] ? {mem_be, 2'b00} : {2'b00, mem_be};
                    sd_req <= 1'b1; st_q <= BUSY;
                end
            end
            BUSY: if (sd_complete) begin
                sd_req <= 1'b0; st_q <= DONE;
                if (owner_video_q) begin vf_rdata <= sd_brdata; vf_ack <= 1'b1; end
                if (owner_px_q) begin px_rdata <= sd_rdata; px_ack <= 1'b1; end
                if (owner_dma_q) begin dm_rdata <= sd_rdata[dm_addr[1:0]*8 +: 8]; dm_ack <= 1'b1; end
            end                                          // a CPU read: the line is now kept, see 'fill'
            CLEAR: begin                                 // after reset: nothing is kept
                clr_q <= clr_q + 11'd1;
                if (clr_q == '1) st_q <= IDLE;
            end
        endcase
        if (reset) begin
            st_q <= CLEAR; clr_q <= '0; lk_q <= 1'b0;
            sd_req <= 1'b0; sd_read <= 1'b0; sd_write <= 1'b0; owner_dma_q <= 1'b0; dm_ack <= 1'b0; owner_px_q <= 1'b0; px_ack <= 1'b0;
            vf_ack <= 1'b0;
        end
    end
endmodule
