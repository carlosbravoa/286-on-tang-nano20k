set d [file normalize [file dirname [info script]]]
set s [file normalize "$d/../ref/SPK286"]
create_project -name fit_spk286 -dir "$d/impl" -pn GW2AR-LV18QN88C8/I7 -device_version C -force
foreach f {microcode/generated/spk286_microcode_pkg.sv microcode/generated/spk286_microcode_rom.sv microcode/generated/spk286_microcode_sync_rom.sv rtl/spk286_protected_pkg.sv rtl/spk286_tss_pkg.sv} { add_file "$s/$f" }
foreach f [lsort [glob "$s/rtl/*.sv"]] { if {![string match *_pkg.sv $f]} { add_file $f } }
add_file "$s/rtl/native/spk286_native.sv"
add_file "$d/fit_top.sv"
add_file "$d/fit.cst"
add_file "$d/fit.sdc"
set_option -top_module fit_top
set_option -verilog_std sysv2017
set_option -synthesis_tool gowinsynthesis
set_option -use_sspi_as_gpio 1
set_option -use_mspi_as_gpio 1
run all
