`tone.elf` is the RA8EMU-650 fixture, the end-to-end check for `--audio-out`
(RA8EMU-570). It is a freestanding Cortex-M85 image linked at MRAM
`0x02000000`, written in Zig, so it needs no C and no Arm GCC.

`tone.zig` cancels SSIE0's module stop (MSTPCRC bit 8), then brings SSIE0
up with the handshake ra8_ssie.c uses. It waits for
SSISR.IIRQ, programs SSICR, then sets TEN. The stream is 16-bit data
(DWL 001b), two words a frame (FRM 00b), right justified (PDTA 1). It sends
ten periods of a square wave with the same level on both channels: 24 frames
at +0x4000, then 24 at -0x4000. At a 48 kHz `--audio-rate` that is 1 kHz for
10 ms. It ends by writing `0x70E0C0DE` at SRAM `0x22000100`.

`tests/interfaces/cli/audio_tone_test.zig` embeds this exact ELF, runs it on
the Zig core with the `--audio-out` recorder armed, and checks the WAV:
480 frames, 24-frame half periods (1000 Hz at 48000), and no silence.

Rebuild with Zig 0.17.0:

```sh
zig build-exe -target thumb-freestanding-eabi -mcpu=cortex_m85 -O ReleaseSmall \
  -fno-stack-check -fstrip -fno-compiler-rt -fno-entry -z max-page-size=4 \
  --script tone.ld tone.zig -femit-bin=tone.elf
```

The same check from the CLI:

```sh
ra8_emulator tone.elf --cpu zig --instructions 200000 --audio-out tone.wav
```
