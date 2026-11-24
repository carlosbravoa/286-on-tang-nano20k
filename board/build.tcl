# Gowin build of the 286 machine for the Tang Nano 20K.
#   QT_QPA_PLATFORM=offscreen gw_sh.sh board/build.tcl      (or: make bitstream)
# Needs LM_LICENSE_FILE for place and route. Run "make sim" first: it builds the BIOS.
set root [file normalize [file dirname [info script]]/..]
set spk  "$root/ref/SPK286"
create_project -name pc286 -dir "$root/build/gowin" -pn GW2AR-LV18QN88C8/I7 -device_version C -force

foreach f {microcode/generated/spk286_microcode_pkg.sv microcode/generated/spk286_microcode_rom.sv
           microcode/generated/spk286_microcode_sync_rom.sv rtl/spk286_protected_pkg.sv rtl/spk286_tss_pkg.sv} {
    add_file "$spk/$f"
}
# The CPU without the hardware task switch, unless FULLCPU=1; NOLOADALL=1 leaves LOADALL out
# as well (see rtl/cpu_trim)
set full [expr {[info exists ::env(FULLCPU)] && $::env(FULLCPU) ne ""}]
set noload [expr {[info exists ::env(NOLOADALL)] && $::env(NOLOADALL) ne ""}]
set left_out {spk286_task_switch_service.sv spk286_tss_service.sv
              spk286_tss_descriptor_service.sv spk286_task_segment_service.sv}
set stand_in {spk286_task_switch_service.sv}
if {$noload} { lappend left_out spk286_loadall_service.sv; lappend stand_in spk286_loadall_service.sv }
foreach f [lsort [glob "$spk/rtl/*.sv"]] {
    if {[string match *_pkg.sv $f]} continue
    if {!$full && [lsearch $left_out [file tail $f]] >= 0} continue
    add_file $f
}
if {!$full} { foreach f $stand_in { add_file "$root/rtl/cpu_trim/$f" } }
foreach f [lsort [glob "$root/rtl/jtopl/*.v"]] { add_file $f }
foreach f {pic8259 pit8254 kbd8042 kbd_ch9350 spi_port adlib sblaster ega_planes pc286_core video sdram_bridge uart_tx_fifo pc286_system} {
    add_file "$root/rtl/$f.sv"
}
foreach f [lsort [glob "$root/rtl/board/hdmi/*.sv"]] { add_file $f }
add_file "$root/rtl/board/sdram_nestang.v"
add_file "$root/rtl/board/gw2ar_sdram.sv"
add_file "$root/rtl/board/plls.v"
# the raster: "make bitstream LINES=449" for 640x400 at 70 Hz (default 525: 640x480 at 60 Hz)
set lines 525
if {[info exists ::env(LINES)] && $::env(LINES) ne ""} { set lines $::env(LINES) }
file mkdir "$root/build/gowin"
set fh [open "$root/build/gowin/video_mode_pkg.sv" w]
puts $fh "package video_mode; localparam int LINES = $lines; endpackage"
close $fh
add_file "$root/build/gowin/video_mode_pkg.sv"
add_file "$root/rtl/board/tang_top.sv"
add_file "$root/board/tang_nano_20k.cst"
add_file "$root/board/tang_nano_20k.sdc"

# memory contents: $readmemh looks in the project directory
file mkdir "$root/build/gowin/pc286"
file copy -force "$root/build/bios16.hex" "$root/build/hid_table.hex" "$root/fonts/vga8x16.hex" "$root/build/gowin/pc286/"

set_option -top_module tang_top
set_option -verilog_std sysv2017
set_option -synthesis_tool gowinsynthesis
set_option -use_mspi_as_gpio 1
set_option -use_ready_as_gpio 1
set_option -use_done_as_gpio 1
set_option -use_i2c_as_gpio 1
set_option -use_cpu_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -place_option 1
run all
