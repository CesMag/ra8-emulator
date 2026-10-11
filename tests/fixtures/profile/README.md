`call_tree.elf` is the RA8EMU-1143 profile fixture: a Cortex-M85 image
whose `Reset_Handler` loops `outer` (which calls `heavy`, three units of
spin) and `light` (one unit). The functions are exported so the image keeps
sized symbols under their plain names. `call_tree_cpu1.elf` is CPU1's half
(RA8EMU-955): `cpu1_outer` calls `cpu1_wide` (two units), and
`cpu1_narrow` (one unit) runs beside it.

Rebuild with Zig 0.17.0:

    zig build-obj -target thumb-freestanding-eabihf -mcpu=cortex_m85 -OReleaseSmall -fstrip call_tree.zig -femit-bin=call_tree.o
    zig cc -target thumb-freestanding-eabihf -mcpu=cortex_m85 -nostdlib -Wl,-e,Reset_Handler -Wl,-z,max-page-size=16 -T call_tree.ld call_tree.o -o call_tree.elf

The same two commands with `call_tree_cpu1` build CPU1's image.
