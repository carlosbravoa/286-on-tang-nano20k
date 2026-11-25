# PC link: driving the machine from another computer

The Tang Nano 20K's USB cable (the one used to flash it) also carries a serial port. A small
monitor in the FPGA (`rtl/monitor.sv`) listens on it, and `tools/pc286ctl.py` on the other
computer talks to it. With it you can:

- type on the machine's keyboard and move its mouse
- read its text screen, or save a picture of a graphics screen
- copy files and directories to and from its disk
- set its date and time
- read and write its memory, and press its reset button

The monitor is hardware beside the CPU, not a program in the machine. Keys, mouse, screen,
memory and reset work whatever the machine runs: DOS, a game, Windows. File transfer needs
DOS at its prompt.

## Setting up

Needs Python 3 on Linux; `put` and `get` also need `mkfs.fat` (dosfstools); `shot` to a
`.png` needs Pillow. The bitstream must be v0.2.0 or later (v0.3.0 for file transfer).

Plug the board in. It shows up as two serial ports; the machine is the second one, usually
`/dev/ttyUSB1`:

    tools/pc286ctl.py ping                        # "the machine answers"
    tools/pc286ctl.py --port /dev/ttyUSB3 ping    # another port
    export PC286_PORT=/dev/ttyUSB3                # or once for the session

The port is 115200 baud, 8N1. Your user must be allowed to open it (group `dialout` on most
systems). Only one program can use it at a time: close terminal programs first.

## Keys and text

    tools/pc286ctl.py type 'dir /w\r'             # type a line; \r is Enter
    tools/pc286ctl.py type 'cd \\games\\keen4\rkeen4e\r'
    tools/pc286ctl.py key f1                      # one key
    tools/pc286ctl.py key up up enter             # several, one after another
    tools/pc286ctl.py key ctrl-alt-del            # held together

In `type`: `\r` or `\n` Enter, `\e` Esc, `\t` Tab, `\b` Backspace, `\\` a backslash. Capitals
and symbols are typed with Shift, as on a US keyboard. `type` watches the BIOS' key queue and
waits when it is half full, so long texts are not lost.

Key names for `key`: `enter esc tab backspace space ctrl alt shift rshift caps f1`...`f12
up down left right home end pgup pgdn ins del`, and any single character.

The keys arrive as scancodes at the keyboard controller, exactly as from the real keyboard,
so games that read the keyboard port themselves see them too.

## The screen

    tools/pc286ctl.py screen                      # the whole text screen
    tools/pc286ctl.py screen 20 24                # rows 20 to 24 (from 0)
    tools/pc286ctl.py wait 'C:\>' 60              # until that text is there, at most 60 s
    tools/pc286ctl.py wait Ready 30 10 14         # look only in rows 10 to 14
    tools/pc286ctl.py shot keen.png               # a graphics screen (.ppm needs no Pillow)
    tools/pc286ctl.py log                         # what the BIOS prints at start, until Ctrl-C

`screen` reads video memory, so it shows what is on the monitor in text modes; in a graphics
mode it says so. `wait` ends with an error if the text does not come, which makes it the
building block of scripts:

    tools/pc286ctl.py reset
    tools/pc286ctl.py wait 'C:\>' 60 && tools/pc286ctl.py type 'win\r'

`shot` handles mode 13h (320x200, 256 colours) and the 16-colour modes 0Dh, 0Eh, 10h and
12h. It reads memory only: the colours are the BIOS' default ones, not a palette the program
has set, and the picture starts at the start of video memory, whatever the program scrolled
to. A 640x480 picture takes about half a minute.

## The mouse

    tools/pc286ctl.py mouse 40 -10                # 40 right, 10 up
    tools/pc286ctl.py mouse 0 0 1                 # left button down (2 right, 3 both)
    tools/pc286ctl.py click                       # left button down and up
    tools/pc286ctl.py click 2                     # right button

Movement is relative, as a real mouse reports it; the pointer's speed is the driver's affair.

## Files

With the machine at the DOS prompt:

    tools/pc286ctl.py put game.zip readme.txt C:/GAMES      # files
    tools/pc286ctl.py put mygame/ C:/GAMES                  # a directory: becomes C:\GAMES\MYGAME
    tools/pc286ctl.py get 'C:/GAMES/KEEN4/*.CK4' saves/     # DOS files (wildcards) to a directory here
    tools/pc286ctl.py serve disk.img                        # be drive B: with an image, until Ctrl-C

The last argument of `put` is the DOS directory; it is made if it is missing. Slashes may be
written either way (`C:/GAMES` saves quoting backslashes in the shell). `put` shows the last
lines of the screen when it is done: check there that DOS copied what you sent.

Speed: about 8 to 11 KB a second to the machine, 5 KB a second back. One megabyte takes
around two minutes going in.

Limits:

- Names must be 8.3 (`GAME.ZIP`, not `my-long-name.tar.gz`); `put` refuses others, and
  leaves them out inside a directory, saying so.
- The machine must be at a DOS prompt ending in `>`; the tool checks, types the command and
  waits for the prompt to come back.
- One `put` carries at most about 500 MB, one `get` about 30 MB.
- Not from inside Windows: leave it first.

### How it works

The BIOS has a second floppy drive, B:, with no hardware behind it. When DOS reads or writes
it, the BIOS leaves the request (read or write, first sector, count, where the caller's
memory is) in its data area and waits. The tool polls that place through the monitor, copies
the sectors straight into or out of the machine's memory, and marks the request done. So:

- `serve IMAGE` is the whole mechanism: any FAT image is drive B: while it runs, and DOS can
  use it like a floppy (`dir b:`, `copy`, run programs from it). Writes go into the image.
- `put` builds an image with your files (a 1.44 MB floppy if they fit, otherwise a FAT16 disk
  as big as needed), types `copy` or `xcopy` at the prompt, and serves until the prompt is
  back. `get` serves an empty image, types the `copy`, and takes the files out of it.
- When nothing serves it, B: answers "not ready" at once.

The places are in `bios/disk.asm` (`d_remote`) and `bios/bios.asm` (`E_REMOTE`...).

## Date and time

    tools/pc286ctl.py clock                           # this computer's date and time
    tools/pc286ctl.py clock 1994-06-01 20:30:00       # or any other

The machine has no clock chip and no battery. The BIOS keeps the time of day as its tick
count and the date in its data area, moves the date on at midnight, and answers the usual
clock calls (INT 1Ah, AH=02h to 05h), so DOS reads both when it starts. They live through a
reset, not through power off: run `clock` once after plugging the board in.

A DOS that is already running keeps its own date, so at the DOS prompt `clock` also types
the `date` command; anywhere else it says that DOS will have the date at its next start.
DOS' own `DATE` and `TIME` commands set the BIOS' clock too. Needs the bitstream after v0.3.0.

## Memory and reset

    tools/pc286ctl.py peek 40:17 2                # 2 bytes at 0040:0017 (also plain hex: 417)
    tools/pc286ctl.py poke B8000 48 1F            # write bytes (hex)
    tools/pc286ctl.py save 100000 65536 hma.bin   # memory to a file
    tools/pc286ctl.py load 80000 code.bin         # a file to memory
    tools/pc286ctl.py reset                       # the reset button; memory is kept

Addresses are 23 bits: 000000-0FFFFF the first megabyte, 100000-7BFFFF extended memory,
7C0000-7FFFFF the four planes of the 16-colour modes (the four bytes of one place side by
side). Only RAM is seen: not the ROM, not I/O ports, not the CPU's registers. The CPU keeps
running while you look.

## With the simulator

The same tool drives the simulated machine, which is how the tests use it:

    build/simsys --sd build/card.img --waits 4 --pty build/pty &
    tools/pc286ctl.py --port build/pty --timeout 300 screen

The simulator is some hundred times slower than the board, hence the long timeout.

## When it does not work

| What you see | Why |
|---|---|
| `Device or resource busy` | another program has the port, or the system is still probing it just after plugging in: try again in a few seconds |
| `no answer from the machine` | wrong port (try `/dev/ttyUSB0`), or a bitstream older than v0.2.0 |
| `something answers, but not the monitor` | another device is on that port |
| `the machine has an older monitor` | file transfer needs the v0.3.0 bitstream |
| `the machine is not at the DOS prompt` | a program is running, or the prompt does not end in `>` |
| `DOS does not come back to its prompt` | DOS is asking something (the screen is shown): answer it with `type` |
| DOS says `drive not ready` for B: | nothing is serving it: `put`, `get` or `serve` must be running |

## The wire

For those who want to talk to the monitor from their own program. A command is a letter and
its bytes; every command is answered.

| Command | Does | Answer |
|---|---|---|
| `?` | who is there | 87h (86h: a monitor without `W`) |
| `K` code | a key code (scancode set 1) | `K` |
| `M` buttons dx dy | a mouse report; dx right, dy down, signed bytes | `M` |
| `A` hi mid lo | set the address for `r`, `w`, `W` | `A` |
| `r` n | read n+1 bytes; the address moves on | the bytes |
| `w` byte | write one byte; the address moves on | `w` |
| `W` n bytes... | write n+1 bytes; the address moves on | `W` after the last |
| `R` | reset the machine (not its RAM, not the monitor) | `R` |

The answers share the wire with the text the BIOS prints. Each answer byte is sent as two:
A0h plus its high half, then B0h plus its low half. The BIOS' text never contains bytes
A0h-BFh (they are sent as dots), so the two cannot be confused.
