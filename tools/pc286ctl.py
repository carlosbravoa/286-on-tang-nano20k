#!/usr/bin/env python3
"""Remote control of the 286 machine over the board's USB serial port (rtl/monitor.sv).

  pc286ctl.py [--port DEV] [--timeout SECONDS] COMMAND ...

  ping                   is the machine there?
  type TEXT              type it (\\r Enter, \\e Esc, \\t Tab, \\b Backspace, \\\\ a backslash)
  key NAME ...           press keys: enter esc f1 up pgdn del ...; together with a dash: ctrl-alt-del
  screen [FIRST [LAST]]  print the text screen (or only those rows, counted from 0)
  wait TEXT [SECONDS [FIRST [LAST]]]   wait until TEXT is on the text screen (default 30 s),
                         or in those rows of it
  shot FILE.ppm          picture of a graphics screen (mode 13h or the 16-colour modes), in the
                         BIOS' colours and from the start of video memory; .png with Pillow
  mouse DX DY [BUTTONS]  move the mouse right and down; buttons 1 left, 2 right
  click [BUTTONS]        press and let go
  peek ADDR [LENGTH]     show RAM (ADDR in hex, or SEG:OFF)
  poke ADDR BYTE ...     write RAM (bytes in hex)
  save ADDR LENGTH FILE  RAM to a file
  load ADDR FILE         a file to RAM
  reset                  the reset button (RAM is kept)
  log [SECONDS]          show the text the BIOS sends (default: until Ctrl-C)

The port is --port, else $PC286_PORT, else /dev/ttyUSB1. With the simulator:
  build/simsys --sd CARD.img --pty build/pty ... &   then   --port build/pty --timeout 300
Only RAM can be read: not the ROM, not the video registers.
"""
import os, select, sys, termios, time

SET1 = {}
for i, c in enumerate("1234567890-="): SET1[c] = 0x02 + i
for i, c in enumerate("qwertyuiop[]"): SET1[c] = 0x10 + i
for i, c in enumerate("asdfghjkl;'`"): SET1[c] = 0x1E + i
for i, c in enumerate("\\zxcvbnm,./"): SET1[c] = 0x2B + i
SET1.update({' ': 0x39, '\r': 0x1C, '\n': 0x1C, '\x1b': 0x01, '\t': 0x0F, '\b': 0x0E})
SHIFTED = dict(zip('!@#$%^&*()_+{}:"~|<>?', "1234567890-=[];'`\\,./"))
NAMES = {'enter': 0x1C, 'esc': 0x01, 'tab': 0x0F, 'backspace': 0x0E, 'space': 0x39, 'ctrl': 0x1D, 'alt': 0x38,
         'shift': 0x2A, 'rshift': 0x36, 'caps': 0x3A, 'f11': 0x57, 'f12': 0x58,
         'up': 0xE048, 'down': 0xE050, 'left': 0xE04B, 'right': 0xE04D, 'home': 0xE047, 'end': 0xE04F,
         'pgup': 0xE049, 'pgdn': 0xE051, 'ins': 0xE052, 'del': 0xE053}
for i in range(10): NAMES['f%d' % (i + 1)] = 0x3B + i
EGA = [(0, 0, 0), (0, 0, 170), (0, 170, 0), (0, 170, 170), (170, 0, 0), (170, 0, 170), (170, 85, 0), (170, 170, 170),
       (85, 85, 85), (85, 85, 255), (85, 255, 85), (85, 255, 255), (255, 85, 85), (255, 85, 255), (255, 255, 85), (255, 255, 255)]

class Link:
    def __init__(self, port, timeout):
        self.fd = os.open(port, os.O_RDWR | os.O_NOCTTY)
        a = termios.tcgetattr(self.fd)
        a[0] = a[1] = a[3] = 0                              # raw
        a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        a[4] = a[5] = termios.B115200
        a[6][termios.VMIN] = 0; a[6][termios.VTIME] = 0
        termios.tcsetattr(self.fd, termios.TCSANOW, a)
        termios.tcflush(self.fd, termios.TCIFLUSH)
        self.timeout = timeout; self.text = bytearray(); self.high = None

    def recv(self, n, timeout=None):
        """n bytes of answers; the BIOS' text that comes along goes to self.text"""
        out = bytearray(); end = time.time() + (timeout or self.timeout)
        while len(out) < n:
            left = end - time.time()
            if left <= 0 or not select.select([self.fd], [], [], left)[0]:
                raise SystemExit('no answer from the machine (%d of %d bytes)' % (len(out), n))
            for b in os.read(self.fd, 4096):
                if b & 0xF0 == 0xA0: self.high = b & 15
                elif b & 0xF0 == 0xB0 and self.high is not None: out.append(self.high << 4 | b & 15); self.high = None
                else: self.text.append(b)
        return bytes(out)

    def cmd(self, data, n=1):
        os.write(self.fd, bytes(data)); return self.recv(n)

    def ping(self):
        if self.cmd(b'?') != b'\x86': raise SystemExit('something answers, but not the monitor')

    def seek(self, addr): self.cmd(bytes([ord('A'), addr >> 16 & 0x7F, addr >> 8 & 0xFF, addr & 0xFF]))

    def read(self, addr, n):
        self.seek(addr); out = bytearray()
        while len(out) < n:
            k = min(256, n - len(out)); out += self.cmd(bytes([ord('r'), k - 1]), k)
        return bytes(out)

    def write(self, addr, data):
        self.seek(addr)
        for b in data: self.cmd(bytes([ord('w'), b]))

    def code(self, c, up=False):
        if c > 0xFF: self.cmd(b'K\xE0')
        self.cmd(bytes([ord('K'), (c & 0x7F) | (0x80 if up else 0)]))

    def room(self):
        """wait until the BIOS' key queue (16 places) is less than half full"""
        while True:
            head, tail = self.read(0x41A, 4)[0::2]
            if (tail - head) % 32 < 16: return
            time.sleep(0.01)

    def type(self, text):
        for ch in text:
            shift = ch in SHIFTED or ch.isupper()
            c = SET1.get(SHIFTED.get(ch, ch.lower()))
            if c is None: raise SystemExit('no key for %r' % ch)
            self.room()
            if shift: self.code(0x2A)
            self.code(c); self.code(c, True)
            if shift: self.code(0x2A, True)

    def key(self, name):
        codes = []
        for k in name.lower().split('-'):
            c = NAMES.get(k) or (SET1.get(k) if len(k) == 1 else None)
            if c is None: raise SystemExit('no key called %r' % k)
            codes.append(c)
        self.room()
        for c in codes: self.code(c)
        for c in reversed(codes): self.code(c, True)

    def mouse(self, dx, dy, btn):
        while True:
            x = max(-127, min(127, dx)); y = max(-127, min(127, dy))
            self.cmd(bytes([ord('M'), btn & 7, x & 0xFF, y & 0xFF]))
            dx -= x; dy -= y
            if not dx and not dy: return

    def screen(self, first=0, last=None):
        bda = self.read(0x449, 0x3C)
        mode, cols, start, rows = bda[0], bda[1], bda[5] | bda[6] << 8, bda[0x3B] + 1
        if mode > 3 and mode != 7: raise SystemExit('the screen is in graphics mode %02Xh: use shot' % mode)
        last = rows - 1 if last is None else min(last, rows - 1)
        d = self.read(0xB8000 + start + first * cols * 2, (last - first + 1) * cols * 2)
        return [bytes(c if c else 32 for c in d[r * cols * 2:(r + 1) * cols * 2:2]).decode('cp437').rstrip()
                for r in range(last - first + 1)]

    def shot(self, name):
        mode = self.read(0x449, 1)[0]
        if mode == 0x13:
            w, h = 320, 200; d = self.read(0xA0000, 64000)
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            import mkvgapal                                  # the colours the BIOS sets; a program's own are not known
            pal = [tuple(v * 255 // 63 for v in c) for c in mkvgapal.pal]
            px = [pal[b] for b in d]
        elif mode in (0x0D, 0x0E, 0x10, 0x12):
            w, h = {0x0D: (320, 200), 0x0E: (640, 200), 0x10: (640, 350), 0x12: (640, 480)}[mode]
            d = self.read(0x7C0000, w // 8 * h * 4); px = []       # four planes a byte each, side by side
            for i in range(0, len(d), 4):
                for bit in range(7, -1, -1):
                    px.append(EGA[sum((d[i + p] >> bit & 1) << p for p in range(4))])
        else: raise SystemExit('mode %02Xh: no picture of that one (text: use screen)' % mode)
        raw = bytes(v for p in px for v in p)
        if name.lower().endswith('.png'):
            from PIL import Image
            Image.frombytes('RGB', (w, h), raw).save(name)
        else:
            with open(name, 'wb') as f: f.write(b'P6 %d %d 255\n' % (w, h) + raw)
        print('%s: %dx%d, mode %02Xh' % (name, w, h, mode))

def addr(s):
    if ':' in s: seg, off = s.split(':'); return int(seg, 16) * 16 + int(off, 16)
    return int(s, 16)

def unescape(s):
    for a, b in (('\\\\', '\0'), ('\\r', '\r'), ('\\n', '\r'), ('\\e', '\x1b'), ('\\t', '\t'), ('\\b', '\b'), ('\0', '\\')): s = s.replace(a, b)
    return s

def main():
    a = sys.argv[1:]; port = os.environ.get('PC286_PORT', '/dev/ttyUSB1'); timeout = 2.0
    while a and a[0].startswith('--'):
        if a[0] == '--port': port = a[1]
        elif a[0] == '--timeout': timeout = float(a[1])
        else: raise SystemExit(__doc__)
        a = a[2:]
    if not a: raise SystemExit(__doc__)
    c, a = a[0], a[1:]
    m = Link(port, timeout)
    if c == 'log':
        end = time.time() + float(a[0]) if a else None
        try:
            while end is None or time.time() < end:
                if select.select([m.fd], [], [], 0.2)[0]:
                    sys.stdout.write(bytes(b for b in os.read(m.fd, 4096) if b & 0xE0 != 0xA0).decode('cp437')); sys.stdout.flush()
        except KeyboardInterrupt: pass
        return
    m.ping()
    if c == 'ping': print('the machine answers')
    elif c == 'type': m.type(unescape(' '.join(a)))
    elif c == 'key':
        for k in a: m.key(k)
    elif c == 'screen': print('\n'.join(m.screen(*[int(x) for x in a])))
    elif c == 'wait':
        end = time.time() + (float(a[1]) if len(a) > 1 else 30)
        while not any(a[0] in line for line in m.screen(*[int(x) for x in a[2:]])):
            if time.time() > end: raise SystemExit('%r did not appear' % a[0])
            time.sleep(0.2)
    elif c == 'shot': m.shot(a[0])
    elif c == 'mouse': m.mouse(int(a[0]), int(a[1]), int(a[2]) if len(a) > 2 else 0)
    elif c == 'click': b = int(a[0]) if a else 1; m.mouse(0, 0, b); time.sleep(0.05); m.mouse(0, 0, 0)
    elif c == 'peek':
        s = addr(a[0]); d = m.read(s, int(a[1], 0) if len(a) > 1 else 16)
        for i in range(0, len(d), 16):
            row = d[i:i + 16]
            print('%06X: %-48s %s' % (s + i, row.hex(' '), ''.join(chr(b) if 32 <= b < 127 else '.' for b in row)))
    elif c == 'poke': m.write(addr(a[0]), bytes(int(x, 16) for x in a[1:]))
    elif c == 'save':
        with open(a[2], 'wb') as f: f.write(m.read(addr(a[0]), int(a[1], 0)))
    elif c == 'load': m.write(addr(a[0]), open(a[1], 'rb').read())
    elif c == 'reset': m.cmd(b'R'); print('reset')
    else: raise SystemExit(__doc__)

main()
