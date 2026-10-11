This PT_LOAD image is the external-memory sizing fixture (RA8EMU-755) for
`ra8_emulator sweep --elf`. It is a Cortex-M85 RA8 image linked at MRAM
`0x02000000`, built from `ext_stream.zig` with the FPU fixtures' startup and
link script.

It reads 64 KiB from the OSPI window at `0x80000000`, writes each word plus its
index to SDRAM at `0x68000000`, then reads the SDRAM back. The checksum and the
marker `0x5EE9C0DE` go to SRAM `0x22000100`, and the exported global
`ext_stream_done` is set to 1, so `--stop-sym ext_stream_done 1` ends a run
exactly when the traffic is done:

```sh
ra8_emulator sweep --elf tests/fixtures/sizing/ext_stream.elf --stop-sym ext_stream_done 1
```

The symbol table has to stay, so the image is not stripped. Rebuild with
Zig 0.17.0 from this directory:

```sh
M=cortex_m85
zig cc -target thumb-freestanding-eabihf -mcpu=$M -c ../fpu/startup.S -o startup.o
zig build-obj -target thumb-freestanding-eabihf -mcpu=$M -O ReleaseSmall -fno-stack-check -fno-compiler-rt -ffunction-sections ext_stream.zig -femit-bin=ext_stream.o
zig cc -target thumb-freestanding-eabihf -mcpu=$M -nostdlib -Wl,--build-id=none -Wl,--gc-sections -Wl,--strip-debug -Wl,-e,Reset_Handler -Wl,-z,max-page-size=4 -Wl,-T,../fpu/fpu.ld startup.o ext_stream.o -o ext_stream.elf
```

`tests/interfaces/cli/sweep/elf_test.zig` runs it on the slowest and fastest
configurations of the sweep matrix.
