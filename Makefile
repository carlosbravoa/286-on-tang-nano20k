# 286 on the Tang Nano 20K.
#   make sim            build the simulator (build/sim) and the BIOS
#   make boot           boot the test card image in the simulator
#   make card           the SD card image, with what is in dos-disk/
#   make bitstream      Gowin build for the Tang Nano 20K (never flashes); LINES=449: 640x400 at 70 Hz
S := ref/SPK286
# The CPU without the hardware task switch (rtl/cpu_trim has a stand-in that faults).
# NOLOADALL=1 leaves LOADALL out as well (Microsoft's HIMEM.SYS needs it); FULLCPU=1 builds
# the whole SPK286.
ifndef FULLCPU
CPU_OUT := $(addprefix $(S)/rtl/spk286_,task_switch_service.sv tss_service.sv tss_descriptor_service.sv task_segment_service.sv)
CPU_IN  := rtl/cpu_trim/spk286_task_switch_service.sv
ifdef NOLOADALL
CPU_OUT += $(S)/rtl/spk286_loadall_service.sv
CPU_IN  += rtl/cpu_trim/spk286_loadall_service.sv
endif
endif
CPU := $(S)/microcode/generated/spk286_microcode_pkg.sv $(S)/microcode/generated/spk286_microcode_rom.sv \
       $(S)/microcode/generated/spk286_microcode_sync_rom.sv $(S)/rtl/spk286_protected_pkg.sv $(S)/rtl/spk286_tss_pkg.sv \
       $(filter-out %_pkg.sv $(CPU_OUT),$(wildcard $(S)/rtl/*.sv)) $(CPU_IN)
SYS := rtl/video.sv rtl/sdram_bridge.sv rtl/uart_tx_fifo.sv rtl/pc286_system.sv
RTL := rtl/pic8259.sv rtl/pit8254.sv rtl/kbd8042.sv rtl/kbd_ch9350.sv rtl/spi_port.sv $(wildcard rtl/jtopl/*.v) rtl/adlib.sv rtl/sblaster.sv rtl/ega_planes.sv rtl/pc286_core.sv
BIOS_SRC := $(wildcard bios/*.asm)

sim: build/sim build/bios16.hex build/hid_table.hex

build/bios.bin: $(BIOS_SRC)
	@mkdir -p build
	nasm $(NASMFLAGS) -f bin bios/bios.asm -o $@ -l build/bios.lst

build/bios16.hex: build/bios.bin
	od -An -v -tx2 -w2 $< > $@

build/hid_table.hex: tools/mkhidtable.py
	@mkdir -p build
	python3 $< $@

build/sim: $(RTL) $(CPU) sim/sim_main.cpp build/bios16.hex build/hid_table.hex
	verilator --cc --exe --build -j 8 -O3 --x-assign fast --no-timing --x-initial fast -Wno-fatal -Wno-WIDTH -Wno-UNUSED \
	    -Wno-PINMISSING -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-DECLFILENAME -Wno-UNDRIVEN -Wno-SYNCASYNCNET \
	    -I$(S)/rtl --top-module pc286_core -Mdir build/obj -o ../sim \
	    $(CPU) $(RTL) sim/sim_main.cpp -CFLAGS "-O3 -march=native" > build/verilator.log 2>&1 || (tail -40 build/verilator.log; false)

VFLAGS := --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast --no-timing -Wno-fatal -Wno-WIDTH -Wno-UNUSED \
	    -Wno-PINMISSING -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-DECLFILENAME -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -I$(S)/rtl

# the whole system (bridge to the SDRAM, video): slower, makes pictures
build/simsys: $(RTL) $(SYS) $(CPU) sim/sim_main.cpp build/bios16.hex build/hid_table.hex
	verilator $(VFLAGS) --top-module pc286_system -Mdir build/obj_sys -o ../simsys \
	    $(CPU) $(RTL) $(SYS) sim/sim_main.cpp -CFLAGS "-O3 -march=native -DSYSTEM" > build/verilator_sys.log 2>&1 || (tail -40 build/verilator_sys.log; false)

bitstream: build/bios16.hex build/hid_table.hex
	FULLCPU=$(FULLCPU) NOLOADALL=$(NOLOADALL) LINES=$(LINES) QT_QPA_PLATFORM=offscreen $(HOME)/Documents/gowin/IDE/bin/gw_sh.sh board/build.tcl > build/gowin.log 2>&1 || (grep ERROR build/gowin.log; false)
	@grep -A4 "Resource Usage Summary" -m1 build/gowin/pc286/impl/pnr/pc286.rpt.txt | tail -3

# The SD card image: C: with FreeDOS, the XMS driver and everything in dos-disk/ (not in git:
# put your programs there, a directory each). It boots from C:.
#   sudo dd if=build/card.img of=/dev/sdX bs=1M conv=fsync
FDBOOT := ref/dos/144m/x86BOOT.img
XMS := ref/dos/xms/fdxms286/BIN/FDXMS286.SYS
card:
	@mkdir -p dos-disk
	nasm -f bin dos/mouse.asm -o build/MOUSE.COM
	python3 tools/mkhd.py build/hd.img --size-mb $(or $(CARD_MB),128) --from $(FDBOOT) --xms $(XMS) --root dos-disk
	python3 tools/mkcard.py build/card.img --hd build/hd.img

boot: sim build/card.img
	build/sim --sd build/card.img --screen $(ARGS)

clean:
	rm -rf build
.PHONY: sim boot clean bitstream card
