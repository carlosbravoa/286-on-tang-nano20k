// Simulation of the machine: RAM, an SD card on the SPI pins, a CH9350 keyboard on the UART.
//   sim [options]
//     --sd FILE          SD card image (read/write in memory; --save writes it back)
//     --cycles N         stop after N clock cycles (default 50 million)
//     --waits N          wait cycles of every RAM access (default 2)
//     --expect TEXT --type TEXT   when TEXT has appeared on the screen output, type the keys
//                        (\r = Enter). May be given several times, done in order.
//                        (\r Enter, \e Esc, \m mouse moves 20 right 8 down, \l left button, \u buttons up)
//     --after N          clock cycles to run after the last --type (default 3 million)
//     --screen           print the 80x25 text screen at the end
//     --peek HEXADDR     print 16 bytes of RAM at the end
//     --quiet            do not echo the characters the BIOS writes
//     --ppm FILE         (system build) write the last complete video frame as a picture
#ifdef SYSTEM
#include "Vpc286_system.h"
#include "Vpc286_system___024root.h"
typedef Vpc286_system Top;       // the whole system: SDRAM bridge and video included
#else
#include "Vpc286_core.h"
typedef Vpc286_core Top;         // the core alone, RAM answered directly (faster)
#endif
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

#ifndef RASTER_LINES
#define RASTER_LINES 525
#endif
static const double CLK_HZ = 25312500.0;
static std::vector<uint8_t> ram(8 << 20, 0);

// ── SD card (SPI mode, high capacity) ──
struct SdCard {
    std::vector<uint8_t> img;
    std::deque<uint8_t> out;
    uint8_t cmd[6]; int ncmd = 0;
    bool idle = true, acmd = false;
    int wstate = 0;      // 0 none, 1 wait token, 2 data
    uint32_t wlba = 0; int wcount = 0;
    int inbits = 0, outbits = 0; uint8_t inbyte = 0, outbyte = 0xFF;
    bool prev_sck = false;
    long reads = 0, writes = 0;

    uint8_t byte(uint8_t b) {                      // a byte arrived; returns what goes out next
        if (wstate == 1) { if (b == 0xFE) { wstate = 2; wcount = 0; } }
        else if (wstate == 2) {
            if (wcount < 512 && (size_t)wlba * 512 + wcount < img.size()) img[(size_t)wlba * 512 + wcount] = b;
            if (++wcount == 514) { wstate = 0; writes++; out.push_back(0x05); out.push_back(0x00); out.push_back(0x00); }
        } else if (ncmd > 0 || (b & 0xC0) == 0x40) {
            cmd[ncmd++] = b;
            if (ncmd == 6) { ncmd = 0; exec(); }
        }
        if (out.empty()) return 0xFF;
        uint8_t r = out.front(); out.pop_front(); return r;
    }
    void exec() {
        int c = cmd[0] & 0x3F;
        uint32_t arg = (cmd[1] << 24) | (cmd[2] << 16) | (cmd[3] << 8) | cmd[4];
        out.clear();
        out.push_back(0xFF);
        bool was_acmd = acmd; acmd = false;
        switch (c) {
            case 0: idle = true; out.push_back(0x01); break;
            case 8: out.push_back(0x01); out.push_back(0); out.push_back(0); out.push_back(1); out.push_back(0xAA); break;
            case 55: acmd = true; out.push_back(idle ? 0x01 : 0x00); break;
            case 41: if (was_acmd) { static int n = 0; if (++n >= 3) idle = false; out.push_back(idle ? 0x01 : 0x00); }
                     else out.push_back(0x05); break;
            case 58: out.push_back(0x00); out.push_back(0xC0); out.push_back(0xFF); out.push_back(0x80); out.push_back(0x00); break;
            case 16: out.push_back(0x00); break;
            case 17:
                out.push_back(0x00); out.push_back(0xFF); out.push_back(0xFE);
                for (int i = 0; i < 512; i++) { size_t a = (size_t)arg * 512 + i; out.push_back(a < img.size() ? img[a] : 0); }
                out.push_back(0x12); out.push_back(0x34); reads++;
                break;
            case 24: out.push_back(0x00); wstate = 1; wlba = arg; break;
            default: out.push_back(0x04); break;
        }
    }
    int miso = 1;
    void clock(bool sck, bool mosi, bool cs_n) {
        if (cs_n) { inbits = 0; outbits = 0; outbyte = 0xFF; miso = 1; prev_sck = sck; return; }
        if (sck && !prev_sck) {                    // rising: take a bit
            inbyte = (inbyte << 1) | (mosi ? 1 : 0);
            if (++inbits == 8) { inbits = 0; outbyte = byte(inbyte); outbits = 0; }
        } else if (!sck && prev_sck) {             // falling: show the next bit
            miso = (outbyte >> (7 - outbits)) & 1; outbits = (outbits + 1) & 7;
        }
        prev_sck = sck;
    }
};

// ── keyboard: CH9350 frames on a UART ──
struct Keyboard {
    std::deque<uint8_t> bytes;
    double t = 0; int bit = -1; uint8_t cur = 0; long gap = 0;
    int serial = 0;
    const double bit_time = CLK_HZ / 115200.0;
    void report(uint8_t mod, uint8_t key) {
        uint8_t f[15] = {0x57, 0xAB, 0x88, 11, 0x10, mod, 0, key, 0, 0, 0, 0, 0, (uint8_t)serial++, 0};
        uint8_t s = 0; for (int i = 5; i < 14; i++) s += f[i];
        f[14] = s;
        for (uint8_t b : f) bytes.push_back(b);
        bytes.push_back(0); bytes.push_back(0xFE);         // marker: a pause (not sent)
    }
    uint8_t mbtn = 0;
    void mouse(uint8_t btn, int dx, int dy) {
        uint8_t f[11] = {0x57, 0xAB, 0x88, 7, 0x20, btn, (uint8_t)dx, (uint8_t)dy, 0, (uint8_t)serial++, 0};
        uint8_t s = 0; for (int i = 5; i < 10; i++) s += f[i];
        f[10] = s;
        for (uint8_t b : f) bytes.push_back(b);
        bytes.push_back(0); bytes.push_back(0xFE);
    }
    void type(const std::string& s) {
        for (char ch : s) {
            uint8_t mod = 0, key = 0;
            if (ch == 1) { mouse(mbtn, 20, 8); continue; }             // \m: the mouse moves right and down
            if (ch == 2) { mbtn = 1; mouse(mbtn, 0, 0); continue; }     // \l: left button down
            if (ch == 3) { mbtn = 0; mouse(mbtn, 0, 0); continue; }     // \u: buttons up
            static const char* sh = ")!@#$%^&*(";
            if (ch >= 4 && ch <= 7) key = 0x52 - (ch - 4);              // \U \D \L \R: arrow keys
            else
            if (ch >= 'a' && ch <= 'z') key = 4 + ch - 'a';
            else if (ch >= 'A' && ch <= 'Z') { key = 4 + ch - 'A'; mod = 2; }
            else if (ch >= '1' && ch <= '9') key = 0x1E + ch - '1';
            else if (ch == '0') key = 0x27;
            else if (ch == '\r' || ch == '\n') key = 0x28;
            else if (ch == ' ') key = 0x2C;
            else if (ch == '-') key = 0x2D; else if (ch == '=') key = 0x2E;
            else if (ch == '\\') key = 0x31; else if (ch == ';') key = 0x33;
            else if (ch == ':') { key = 0x33; mod = 2; }
            else if (ch == ',') key = 0x36; else if (ch == '.') key = 0x37; else if (ch == '/') key = 0x38;
            else if (ch == '>') { key = 0x37; mod = 2; } else if (ch == '<') { key = 0x36; mod = 2; }
            else if (ch == '*') { key = 0x25; mod = 2; } else if (ch == '?') { key = 0x38; mod = 2; }
            else if (ch == '_') { key = 0x2D; mod = 2; } else if (ch == '\x1b') key = 0x29;
            else if (strchr(sh, ch)) { int i = strchr(sh, ch) - sh; key = i ? 0x1D + i : 0x27; mod = 2; }
            else continue;
            if (mod) report(mod, 0);
            report(mod, key);
            report(mod, 0);
            if (mod) report(0, 0);
        }
    }
    bool idle() const { return bytes.empty() && bit < 0 && gap == 0; }
    int rx = 1;
    void tick() {                                          // once per clock
        if (gap > 0) { gap--; return; }
        if (bit < 0) {
            if (bytes.empty()) return;
            if (bytes.size() >= 2 && bytes[0] == 0 && bytes[1] == 0xFE && false) {}
            cur = bytes.front(); bytes.pop_front();
            if (cur == 0 && !bytes.empty() && bytes.front() == 0xFE) { bytes.pop_front(); gap = (long)(CLK_HZ * 0.004); return; }
            bit = 0; t = 0; rx = 0; return;
        }
        t += 1;
        if (t >= bit_time) {
            t -= bit_time; bit++;
            if (bit <= 8) rx = (cur >> (bit - 1)) & 1;
            else if (bit == 9) rx = 1;
            else bit = -1;
        }
    }
};

static void print_screen() {
    printf("+%s+\n", std::string(80, '-').c_str());
    for (int r = 0; r < 25; r++) {
        printf("|");
        for (int c = 0; c < 80; c++) { uint8_t ch = ram[0xB8000 + (r * 80 + c) * 2]; putchar(ch >= 32 && ch < 127 ? ch : ch ? '.' : ' '); }
        printf("|\n");
    }
    printf("+%s+\n", std::string(80, '-').c_str());
}

static std::string unescape(const char* s) {
    std::string r;
    for (; *s; s++) {
        if (*s == '\\' && s[1] == 'r') { r += '\r'; s++; }
        else if (*s == '\\' && s[1] == 'e') { r += '\x1b'; s++; }
        else if (*s == '\\' && s[1] == 'm') { r += '\x01'; s++; }
        else if (*s == '\\' && s[1] == 'l') { r += '\x02'; s++; }
        else if (*s == '\\' && s[1] == 'u') { r += '\x03'; s++; }
        else if (*s == '\\' && s[1] == 'U') { r += '\x04'; s++; }
        else if (*s == '\\' && s[1] == 'D') { r += '\x05'; s++; }
        else if (*s == '\\' && s[1] == 'L') { r += '\x06'; s++; }
        else if (*s == '\\' && s[1] == 'R') { r += '\x07'; s++; }
        else if (*s == '\\' && s[1] == '\\') { r += '\\'; s++; }
        else r += *s;
    }
    return r;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    long max_cycles = 50000000, after = 3000000; int waits = 2; bool screen = false, quiet = false;
    const char* sdfile = nullptr; const char* save = nullptr; const char* ppm = nullptr;
    std::vector<std::pair<std::string, std::string>> script;
    std::string pending_expect; std::vector<long> peeks;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--sd") sdfile = argv[++i];
        else if (a == "--save") save = argv[++i];
        else if (a == "--ppm") ppm = argv[++i];
        else if (a == "--peek") peeks.push_back(strtol(argv[++i], 0, 16));
        else if (a == "--cycles") max_cycles = atol(argv[++i]);
        else if (a == "--after") after = atol(argv[++i]);
        else if (a == "--waits") waits = atoi(argv[++i]);
        else if (a == "--screen") screen = true;
        else if (a == "--quiet") quiet = true;
        else if (a == "--expect") pending_expect = unescape(argv[++i]);
        else if (a == "--type") script.push_back({pending_expect, unescape(argv[++i])});
    }
    SdCard sd; Keyboard kb;
    if (sdfile) {
        FILE* f = fopen(sdfile, "rb");
        if (!f) { perror(sdfile); return 1; }
        fseek(f, 0, SEEK_END); sd.img.resize(ftell(f)); fseek(f, 0, SEEK_SET);
        if (fread(sd.img.data(), 1, sd.img.size(), f) != sd.img.size()) return 1;
        fclose(f);
    }
    Top* top = new Top;
    top->reset = 1; top->kbd_rx = 1; top->sd_miso = 1;
#ifdef SYSTEM
    long st_busy = 0, st_wr = 0, st_burst = 0, st_rd = 0, st_rom = 0, st_mem = 0, st_acks = 0, st_io = 0; bool sd_prev = false;
    std::vector<uint8_t> frame(640 * 480 * 3, 0), shown(640 * 480 * 3, 0);
    int cx = 0, cy = 0, sdwait = 0; bool complete = false;
    // the debug text comes out of the serial port: read it back
    int u_bit = -1; double u_t = 0; uint8_t u_byte = 0;
    const double u_time = CLK_HZ / 115200.0;
#endif
    std::string log; size_t step = 0, searched = 0; long stop_at = -1, wc = 0, cycles = 0;
    for (; cycles < max_cycles; cycles++) {
        if (cycles == 8) top->reset = 0;
        top->kbd_rx = kb.rx; top->sd_miso = sd.miso;
        bool dbg_valid = false; char dbg_ch = 0;
#ifdef SYSTEM
        // SDRAM controller: a 32-bit word per request (four in a burst read), 'complete' held until the request goes
        if (top->sd_req) st_busy++;
        { auto* r = top->rootp;
          if (r->pc286_system__DOT__core__DOT__is_rom) st_rom++;
          else if (r->pc286_system__DOT__core__DOT__is_mem) { st_mem++; if (r->pc286_system__DOT__mem_ack) st_acks++; }
          else if (r->pc286_system__DOT__core__DOT__is_io) st_io++; }
        if (top->sd_req && !sd_prev) { if (top->sd_write) st_wr++; else if (top->sd_burst) st_burst++; else st_rd++; }
        sd_prev = top->sd_req;
        if (!top->sd_req) { complete = false; sdwait = 0; }
        else if (!complete && ++sdwait > waits + (top->sd_burst ? 4 : 0)) {
            complete = true;
            uint32_t a = top->sd_addr & 0x7FFFFC;
            if (top->sd_burst) for (int w = 0; w < 4; w++) {           // four words; the column does not carry
                uint32_t b = (a & ~0x3FFu) | ((a + w * 4) & 0x3FF);
                top->sd_brdata[w] = ram[b] | (ram[b + 1] << 8) | (ram[b + 2] << 16) | ((uint32_t)ram[b + 3] << 24);
            }
            if (top->sd_write) { for (int i = 0; i < 4; i++) if (top->sd_wmask & (1 << i)) ram[a + i] = top->sd_wdata >> (8 * i); }
            top->sd_rdata = ram[a] | (ram[a + 1] << 8) | (ram[a + 2] << 16) | ((uint32_t)ram[a + 3] << 24);
        }
        top->sd_complete = complete;
        top->cx = cx; top->cy = cy;
        top->clk = 0; top->clk_pix = 0;
        top->eval();
        if (cx < 640 && cy < 480) { uint8_t* p = &frame[(cy * 640 + cx) * 3]; p[0] = top->rgb >> 16; p[1] = top->rgb >> 8; p[2] = top->rgb; }
        top->clk = 1; top->clk_pix = 1;
        top->eval();
        if (++cx == 800) { cx = 0; if (++cy == RASTER_LINES) { cy = 0; shown = frame; } }
        if (u_bit < 0) { if (!top->dbg_tx) { u_bit = 0; u_t = u_time * 1.5; u_byte = 0; } }
        else if ((u_t -= 1) <= 0) {
            u_t += u_time;
            if (u_bit < 8) u_byte |= top->dbg_tx << u_bit++;
            else { u_bit = -1; dbg_valid = true; dbg_ch = u_byte; }
        }
#else
        // outputs are settled after the last rising edge: answer the RAM request, then clock
        top->vid_blank = (cycles % 800) >= 640 || (cycles % 420000) >= 384000;   // roughly a 640x480 raster
        top->vid_vsync = (cycles % 420000) >= 392000 && (cycles % 420000) < 393600;
        bool req = top->mem_req, ack = req && wc >= waits;
        top->mem_ack = ack;
        if (ack) {
            uint32_t a = top->mem_addr;
            if (a < ram.size()) {
                top->mem_rdata = ram[a] | (ram[a + 1] << 8);
                if (top->mem_we) {
                    if (top->mem_be & 1) ram[a] = top->mem_wdata & 0xFF;
                    if (top->mem_be & 2) ram[a + 1] = top->mem_wdata >> 8;
                }
            } else top->mem_rdata = 0xFFFF;
        }
        wc = (req && !ack) ? wc + 1 : 0;
        top->clk = 0;
        top->eval();
        top->clk = 1;
        top->eval();
        dbg_valid = top->dbg_char_valid; dbg_ch = top->dbg_char;
        top->vio_rdata = 0xFF;
#endif
        sd.clock(top->sd_sck, top->sd_mosi, top->sd_cs_n);
        kb.tick();
        if (dbg_valid) {
            char ch = dbg_ch;
            log += ch;
            if (!quiet) { putchar(ch); fflush(stdout); }
            if (step < script.size() && log.find(script[step].first, searched) != std::string::npos) {
                searched = log.size();
                kb.type(script[step].second);
                step++;
            }
        }
        if (step == script.size() && !script.empty() && stop_at < 0 && kb.idle()) stop_at = cycles + after;
        if (stop_at >= 0 && cycles >= stop_at) break;
    }
    printf("\n[%ld cycles = %.2f s of machine time; SD: %ld reads, %ld writes%s]\n", cycles, cycles / CLK_HZ,
           sd.reads, sd.writes, top->halted ? "; CPU halted" : "");
    for (long a : peeks) { printf("%06lX:", a); for (int i = 0; i < 16; i++) printf(" %02X", ram[a + i]); printf("\n"); }
    if (screen) print_screen();
#ifdef SYSTEM
    printf("[CPU: %.1f%% of the time in RAM accesses (%ld, %.2f cycles each), %.1f%% ROM, %.1f%% I/O, %.1f%% no bus access]\n",
           100.0 * st_mem / cycles, st_acks, st_acks ? (double)st_mem / st_acks : 0.0, 100.0 * st_rom / cycles, 100.0 * st_io / cycles,
           100.0 * (cycles - st_mem - st_rom - st_io) / cycles);
    printf("[RAM: waiting %.1f%% of the time; %ld 16-byte reads (video and code), %ld data reads, %ld writes]\n",
           100.0 * st_busy / cycles, st_burst, st_rd, st_wr);
    if (ppm) { FILE* f = fopen(ppm, "wb"); fprintf(f, "P6 640 480 255\n"); fwrite(shown.data(), 1, shown.size(), f); fclose(f); }
#endif
    if (save && sdfile) { FILE* f = fopen(save, "wb"); fwrite(sd.img.data(), 1, sd.img.size(), f); fclose(f); }
    delete top;
    return 0;
}
