#!/usr/bin/env python3
"""Write the default VGA palette (256 colours of 6-bit red, green, blue) as a NASM include.

  mkvgapal.py > bios/vgapal.inc

0-15 the CGA colours, 16-31 greys, 32-247 three brightnesses of three saturations of 24 hues,
248-255 black.
"""
cga = [(0, 0, 0), (0, 0, 42), (0, 42, 0), (0, 42, 42), (42, 0, 0), (42, 0, 42), (42, 21, 0), (42, 42, 42),
       (21, 21, 21), (21, 21, 63), (21, 63, 21), (21, 63, 63), (63, 21, 21), (63, 21, 63), (63, 63, 21), (63, 63, 63)]
grey = [0, 5, 8, 11, 14, 17, 20, 24, 28, 32, 36, 40, 45, 50, 56, 63]
ramps = [[0, 16, 31, 47, 63], [31, 39, 47, 55, 63], [45, 49, 54, 58, 63],
         [0, 7, 14, 21, 28], [14, 17, 21, 24, 28], [20, 22, 24, 26, 28],
         [0, 4, 8, 12, 16], [8, 10, 12, 14, 16], [11, 12, 13, 15, 16]]
pal = list(cga) + [(g, g, g) for g in grey]
for r in ramps:
    lo, hi = r[0], r[4]
    up = [(r[i], lo, hi) for i in range(4)]                 # blue to magenta
    hues = up + [(hi, lo, r[4 - i]) for i in range(4)]      # magenta to red
    hues += [(hi, r[i], lo) for i in range(4)]              # red to yellow
    hues += [(r[4 - i], hi, lo) for i in range(4)]          # yellow to green
    hues += [(lo, hi, r[i]) for i in range(4)]              # green to cyan
    hues += [(lo, r[4 - i], hi) for i in range(4)]          # cyan to blue
    pal += hues
pal += [(0, 0, 0)] * (256 - len(pal))
assert len(pal) == 256
print("; the default VGA palette: made by tools/mkvgapal.py")
for i in range(0, 256, 4):
    print("        db " + ", ".join("%d,%d,%d" % c for c in pal[i:i + 4]))
