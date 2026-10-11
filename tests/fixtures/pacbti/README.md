This PT_LOAD image is the built firmware fixture for the PACBTI boot
regression. It is a Cortex-M85 RA8 image linked at MRAM `0x02000000`. The reset
handler enables secure privileged `BTI_EN` and `PAC_EN`, then calls `main`.

`pacbti_smoke.S` is the code Arm GNU Toolchain 13.3.1 emits for a small `main`
that indirectly calls `worker` when built with
`-mcpu=cortex-m85 -mbranch-protection=standard -Os`, kept as assembly so the
repository carries no C. It has `PACBTI` in `main`, `BTI` at the indirect
target `worker`, and `AUT` before returning to reset.

Rebuild with Zig 0.17.0:

```sh
zig cc -target thumb-freestanding-eabihf -mcpu=cortex_m85 -c startup.S -o startup.o
zig cc -target thumb-freestanding-eabihf -mcpu=cortex_m85 -c pacbti_smoke.S -o pacbti_smoke.o
zig cc -target thumb-freestanding-eabihf -mcpu=cortex_m85 -nostdlib -Wl,--build-id=none -Wl,-e,Reset_Handler -Wl,-z,max-page-size=4 -Wl,-T,pacbti.ld startup.o pacbti_smoke.o -o pacbti_smoke.elf
```

The linked code stores `0x247` at SRAM `0x22000000` only after `PACBTI`, `BTI`,
and authenticated `AUT` all execute. The emulator test embeds this exact ELF,
loads its PT_LOAD segments, boots it through the Zig core, and checks the
stored marker.
