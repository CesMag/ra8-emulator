`call_tree.zig` is CPU0's half of a known call tree: `Reset_Handler` loops
`outer` (which calls `heavy`, three units of spin) and `light` (one unit).
`call_tree_cpu1.zig` is CPU1's half: `cpu1_outer` calls `cpu1_wide` (two
units), and `cpu1_narrow` (one unit) runs beside it. `work.zig` holds the
unit of spin both use.

The test step builds both images from this source (tests/fixtures/guests.zig,
RA8EMU-955) and tests/interfaces/cli/folded_guest_test.zig runs them on both
cores with `--profile-folded`.

`call_tree.elf` is the committed CPU0 image RA8EMU-1143's writeFolded tests
embed. The functions are exported so it keeps sized symbols under their
plain names. Rebuild with Zig 0.17.0:

    zig build-obj -target thumb-freestanding-eabihf -mcpu=cortex_m85 -OReleaseSmall -fstrip call_tree.zig -femit-bin=call_tree.o
    zig cc -target thumb-freestanding-eabihf -mcpu=cortex_m85 -nostdlib -Wl,-e,Reset_Handler -Wl,-z,max-page-size=16 -T call_tree.ld call_tree.o -o call_tree.elf
