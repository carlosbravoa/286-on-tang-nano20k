#!/bin/sh
# Make build/gfxNN.img: a card whose floppy boots the test picture of video mode NN (hex).
#   tests/mkgfxcard.sh 13
set -e
m=$1
nasm -DMODE=0x$m -f bin tests/gfxtest.asm -o build/gfx$m.bin
cp build/floppy.img build/gfx$m.flp
dd if=build/gfx$m.bin of=build/gfx$m.flp bs=1 seek=62 conv=notrunc status=none
python3 tools/mkcard.py build/gfx$m.img --floppy build/gfx$m.flp
