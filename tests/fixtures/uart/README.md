# UART fixtures

`uart_irq_echo.elf` (141968 bytes, sha256 `cf9134e09186aa0ab079b8576c52b0b5084ca63fbf12f2eb61e63e752fc5ce4f`) is the
`examples/ek_ra8d2/hw_validated/hil/uart_irq_echo` app from ra8-firmware
commit `39bf91816e348b10e585493d5b3500259c5487df`, built standalone with
Arm GNU Toolchain 13.3.rel1 and Zig 0.17.0:

```sh
cmake -G Ninja -S examples/ek_ra8d2/hw_validated/hil/uart_irq_echo -B build \
  -DCMAKE_TOOLCHAIN_FILE=$PWD/cmake/toolchain-ra8d2.cmake
cmake --build build
```

On the Zig core it prints `uart_irq_echo ready` on SCI8 after about 17,500
instructions, then echoes every byte it receives. Its option-setting segments (OFS, SAS, BPS, OTP) make it the session
load test image (RA8EMU-760), and `ctl events --until` (RA8EMU-757)
waits on its banner.
