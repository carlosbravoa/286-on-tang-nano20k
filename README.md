# 286 on the Tang Nano 20K

A PC with an 80286, built to fit a Sipeed Tang Nano 20K (GW2AR-18). It is not a copy of
the PC/AT: the CPU is real (SPK286), the rest is a small chipset of our own with the
ports PC software expects. The goal is DOS and games.

Status: work in progress. In simulation the machine boots FreeDOS from an SD card image
(floppy or hard disk). On the board it boots FreeDOS and runs games (Monkey Island, Lotus).

## The machine

| Part | How |
|---|---|
| CPU | [SPK286](https://github.com/aitorgomez-net/SPK286), unmodified, in `ref/SPK286`. Two of its blocks are left out of the build and replaced by stand-ins that fault (`rtl/cpu_trim`): the hardware task switch and LOADALL. That frees about 3,900 logic cells; `FULLCPU=1` builds the whole CPU |
| RAM | the board's 8 MB SDRAM: 640 KB, plain RAM at C0000-FBFFF, 6.75 MB above 1 MB; a 32 KB cache in block RAM in front of it (`rtl/sdram_bridge.sv`) |
| BIOS | our own (`bios/`), 16 KB in block RAM at FC000 |
| Video | text 40x25 and 80x25, CGA 320x200x4 and 640x200x2, VGA 320x200x256 (mode 13h) with the VGA palette, EGA/VGA 16 colours in four planes (modes 0Dh, 0Eh, 10h, 12h: write modes 0-3, set/reset, bit mask, functions, both read modes, start address, pixel panning, split screen, palette registers; `rtl/ega_planes.sv`); 640x480 at 60 Hz on HDMI, or 640x400 at 70 Hz as a VGA card sends it (`make bitstream LINES=449`) (`rtl/video.sv`) |
| Keyboard | CH9350 (or a Pico acting as one) on pin 53, as on the Atari816; turned into set 1 scancodes at ports 60h/64h |
| Mouse | the same CH9350; the driver (INT 33h) is in the BIOS |
| Disk | SD card on an SPI port (E0h/E1h); the BIOS reads and writes sectors itself |
| AdLib | OPL2 at 388h/389h ([JTOPL](https://github.com/jotego/jtopl), `rtl/jtopl`), mixed with the speaker into the HDMI sound |
| Sound Blaster | version 2.0 at 220h, IRQ 7, DMA 1: 8-bit sound, direct or through DMA (`rtl/sblaster.sv`, with the one DMA channel it needs); no recording, MIDI or compressed sound |
| Timer, interrupts, speaker | 8254 (channels 0 and 2), two 8259s, port 61h; the speaker is heard over HDMI |
| Memory window | D0000-DFFFF can show any four 16 KB pages of the 8 MB (ports ECh-EEh): the BIOS copies to and from extended memory with it (INT 15h AH=87h), expanded memory will use it |

There is no second processor: everything the machine needs is logic or x86 code in the BIOS.

Not there yet: expanded memory, a clock that keeps the date. In the 16-colour modes: no data
rotate; BIOS text there is 8x8 in the top 25 rows.
The planes take the top 256 KB of the SDRAM (6.75 MB of extended memory are left).

## SD card

    make card                                           # build/card.img, 128 MB
    make card CARD_MB=2016                              # up to 2 GB
    sudo dd if=build/card.img of=/dev/sdX bs=1M conv=fsync   # the whole card is overwritten

The image is drive C: with FreeDOS, the XMS driver (FDXMS286: DOS loads high, 618 KB free)
and everything in `dos-disk/` (not in git; one directory per program). It boots from C:.
It sets `BLASTER` and runs `MOUSE.COM` (`dos/mouse.asm`): the mouse driver is in the BIOS, but DOS
takes its interrupt vectors at start, and this has the BIOS put them back (INT 15h, AX=C2FFh).

Layout: sector 0 is the partition table (one FAT16 partition from sector 4032, up to 2 GB);
sector 64 can hold a floppy image, which is then drive A: and is booted first. C: is an
ordinary partition: it can be mounted on a PC to copy files.

    tools/mkhd.py build/hd.img --size-mb 64 --from FLOPPY.img --root dos-disk --xms FDXMS286.SYS
    tools/mkcard.py build/card.img --hd build/hd.img [--floppy FLOPPY.img]
    tools/fatimg.py build/card.img@4032 put FILE        # add a file to C: (@64: to A:)

Needs in `ref/dos/` (not in git): the FreeDOS 1.3 boot floppy and the FDXMS286 package.

## Directories

- `rtl/` the machine; `rtl/board/` what is specific to the Tang Nano 20K (clocks, SDRAM, HDMI:
  the blocks proven by the Atari816 project)
- `bios/` the BIOS (NASM)
- `sim/` the simulator (Verilator): RAM, an SD card and a CH9350 keyboard as models
- `tools/` card and hard disk images, a FAT tool, the keyboard table, the palette
- `tests/` small boot sectors that test one thing each (video modes, mouse, memory move)
- `board/` pins, timing constraints, the Gowin build script
- `fit/` the first measurements (SPK286 alone on this FPGA)
- `ref/` reference repositories and DOS images (not in git; see below)

## Building

Needs: Verilator 5, NASM, Python 3, the Gowin IDE (for the bitstream).

    git clone https://github.com/aitorgomez-net/SPK286 ref/SPK286
    make sim                 # the BIOS and the fast simulator (build/sim)
    make build/simsys        # the whole system with video (build/simsys), slower
    make bitstream           # Gowin: build/gowin/pc286/impl/pnr/pc286.fs
    make bitstream LINES=449 # the same with the 640x400 at 70 Hz raster

    build/sim --sd build/card.img --screen --expect 'A:\>' --type 'dir\r'
    build/simsys --sd build/card.img --cycles 9000000 --ppm frame.ppm

## Licences

Our own files: to be decided by the author. `rtl/board/sdram_nestang.v` is Apache-2.0
(nand2mario), `rtl/board/hdmi/` is MIT (hdl-util/hdmi), `rtl/jtopl/` is GPL-3.0 (Jose Tejada), SPK286 is MIT, the fonts come from the
SeaBIOS VGA BIOS (see `fonts/README.md`).
