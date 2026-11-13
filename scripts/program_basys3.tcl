# SPDX-License-Identifier: MIT OR Apache-2.0
# program_basys3.tcl
#
# Batch (no GUI) JTAG programming of a Basys 3 with the SoC bitstream built
# by scripts/build_soc.tcl. Launches/connects to the local hw_server,
# programs xc7a35t_0, and reports startup status. Pair with a BTNC reset
# afterward; SW15 selects status LEDs, SW14 enables STDP writeback.
#
# Usage (from anywhere):
#   vivado -mode batch -source scripts/program_basys3.tcl

set repo_root [file normalize [file join [file dirname [info script]] ..]]
set bit_file  [file join $repo_root vivado_projects spikenaut_soc output spikenaut_soc.bit]

if {![file exists $bit_file]} {
    puts "== ERROR: bitstream not found: $bit_file"
    puts "== run scripts/build_soc.tcl first"
    exit 1
}

open_hw_manager
connect_hw_server
open_hw_target

set devs [get_hw_devices]
puts "== hw devices: $devs"

set target ""
foreach d $devs {
    if {[string match -nocase "*xc7a35t*" $d]} { set target $d; break }
}
if {$target eq "" && [llength $devs] == 1} { set target [lindex $devs 0] }
if {$target eq ""} {
    puts "== ERROR: no xc7a35t device found"
    exit 1
}

puts "== programming $target with $bit_file"
current_hw_device $target
refresh_hw_device $target
set_property PROGRAM.FILE $bit_file $target
program_hw_devices $target
refresh_hw_device $target

# startup status HIGH == DONE asserted (bitstream configured and running)
puts "== programming complete; verify DONE LED and LED0 heartbeat on the board"

close_hw_target
disconnect_hw_server localhost:3121
close_hw_manager
puts "== program_basys3.tcl done"
