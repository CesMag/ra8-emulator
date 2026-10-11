`tz_nsc_cgc_usb.elf` (Secure) and `tz_nsc_cgc_usb_ns.elf` (Non-secure) are the
two halves of ra8-firmware's TrustZone example
(`examples/ek_ra8d2/hil_needs_revalidation/tz_nsc_cgc_usb`), built at
ra8-firmware `6196bf4` (RA8FW-626 boot profile + RA8FW-691 GOT in MRAM) and
stripped of debug sections. They are the RA8EMU-293 fixture: one run loads
both, the Secure boot BLXNSes into the Non-secure image, and the Non-secure
side calls the three NSC CGC veneers through their SG stubs and gets back.

The Non-secure image reports through `.ns_bss` globals (addresses from
`arm-none-eabi-nm tz_nsc_cgc_usb_ns.elf`):

| Symbol                        | Address    | Done value                      |
|-------------------------------|------------|---------------------------------|
| `g_tz_nsc_cgc_usb_init_step`  | 0x3210DE0C | 4 (all three veneers returned)  |
| `g_tz_nsc_cgc_usb_match`      | 0x3210DE10 | climbing                        |
| `g_tz_nsc_cgc_usb_mismatch`   | 0x3210DE14 | 0                               |
| `g_tz_nsc_cgc_usb_clock_hz`   | 0x3210DE18 | 1000000000 (CPUCLK0)            |

The same check from the CLI:

```sh
ra8_emulator tz_nsc_cgc_usb.elf --ns tz_nsc_cgc_usb_ns.elf --cpu zig \
  --instructions 3000000 --dump-sym g_tz_nsc_cgc_usb_init_step
```

Rebuild from ra8-firmware with Arm GNU 13.3.rel1 on `PATH`:

```sh
zig build arm
arm-none-eabi-strip -g -o tz_nsc_cgc_usb.elf zig-out/arm/tz_nsc_cgc_usb.elf
arm-none-eabi-strip -g -o tz_nsc_cgc_usb_ns.elf zig-out/arm/tz_nsc_cgc_usb_ns.elf
```

If the image is rebuilt, re-read the four addresses above and update
`tests/interfaces/cli/tz_pair_test.zig`.

`cpu1_pingpong_ipc.elf` and `cpu1_pingpong_ipc_cpu1.elf` are the two-core
RA8EMU-507 fixture, built from ra8-firmware `7806ccf` and stripped of debug
sections. The Secure CPU0 image includes its Non-secure half at the RA8 IDAU's
`0x1208_0000` alias. `tests/chip/core/second/zig/run_test.zig` runs both cores,
proves CPU0 reaches that target, and checks that the externally reported CFSR,
HFSR and SFSR words all remain clear.

Rebuild them with the same toolchain and command above, then strip both files:

```sh
arm-none-eabi-strip -g -o cpu1_pingpong_ipc.elf zig-out/arm/cpu1_pingpong_ipc.elf
arm-none-eabi-strip -g -o cpu1_pingpong_ipc_cpu1.elf \
  zig-out/arm/cpu1_pingpong_ipc_cpu1.elf
```
