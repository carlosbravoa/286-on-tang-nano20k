#!/bin/sh
# Make build/egaNN.img: a card whose floppy boots the test picture of 16-colour mode NN (hex).
#   tests/mkegacard.sh 12
set -e
m=$1
case $m in 0D|0d) c=40; l=200;; 0E|0e) c=80; l=200;; 10) c=80; l=350;; 12) c=80; l=480;; esac
nasm $EXTRA -DMODE=0x$m -DCOLS=$c -DLINES=$l -f bin tests/egatest.asm -o build/ega$m.bin
cp build/floppy.img build/ega$m.flp
dd if=build/ega$m.bin of=build/ega$m.flp bs=1 seek=62 conv=notrunc status=none
python3 tools/mkcard.py build/ega$m.img --floppy build/ega$m.flp
