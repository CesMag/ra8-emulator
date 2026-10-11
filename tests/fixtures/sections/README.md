# Section-table fixtures

`fault_crashlog_hil.elf` (138936 bytes, sha256 `96e6a425dbbf2287cd69c54b908f0fd9ce8d7d67aeff98a39c2d472daee14ef1`) is the
`examples/ek_ra8d2/hw_validated/hil/fault_crashlog_hil` app from ra8-firmware
commit `39bf91816e348b10e585493d5b3500259c5487df`, built standalone with
Arm GNU Toolchain 13.3.rel1 and Zig 0.17.0:

```sh
cmake -G Ninja -S examples/ek_ra8d2/hw_validated/hil/fault_crashlog_hil -B build \
  -DCMAKE_TOOLCHAIN_FILE=$PWD/cmake/toolchain-ra8d2.cmake
cmake --build build
```

It is the image with every section kind the memory-layout view places: code,
read-only, `.data` stored in MRAM and run in SRAM, `.bss`, and a `.noinit`
section at the top of SRAM (0x220FFF00). The section table test (RA8EMU-783)
checks it against `arm-none-eabi-objdump -h`.
