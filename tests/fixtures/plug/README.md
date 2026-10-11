`gauge_poll.elf` is the RA8EMU-212 hot-plug fixture: a Cortex-M85 RA8 image
linked at MRAM `0x02000000` that polls the MAX17048 fuel gauge forever.

Each poll is one address-only write to `0x36` on RIIC channel 1 (the board's
sensor line, `0x4025E100`): START, the address byte, then STOP. The firmware
counts what came back in four SRAM words at `0x22000100`:

| Offset | Word    | Meaning                                          |
|--------|---------|--------------------------------------------------|
| 0x0    | polls   | probes finished                                  |
| 0x4    | acks    | probes the gauge acknowledged                    |
| 0x8    | nacks   | probes nothing acknowledged                      |
| 0xC    | changes | times the answer flipped between ack and nack    |

`tests/board/gauge_replug_test.zig` boots it on the Zig core, unplugs the
gauge through the session partway through the run and plugs it back later,
then checks these counts against the session's event stream.

The source is Zig, so the repository carries no C. Rebuild with Zig 0.17.0:

```sh
zig build-obj -target thumb-freestanding-eabihf -mcpu=cortex_m85 -O ReleaseSmall -fno-stack-check -fstrip -fno-compiler-rt -ffunction-sections gauge_poll.zig -femit-bin=gauge_poll.o
zig cc -target thumb-freestanding-eabihf -mcpu=cortex_m85 -nostdlib -Wl,--build-id=none -Wl,--gc-sections -Wl,-s -Wl,-e,Reset_Handler -Wl,-z,max-page-size=4 -Wl,-T,plug.ld gauge_poll.o -o gauge_poll.elf
```
