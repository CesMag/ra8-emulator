<!--
Copyright (c) 2026 Brighton Sikarskie
SPDX-License-Identifier: MIT
-->

# ra8_emulator

Runs the real, unmodified firmware `.elf` (the same image that flashes to an
EK-RA8D2) on emulated Cortex-M85 and Cortex-M33 cores over a modelled RA8
peripheral space. A pass here means the flashed firmware drove the hardware
the way the silicon expects. For the RA8P1, which has no board on the bench,
this is how its firmware gets proven.

It is three things in one repository: an emulator you run from the command
line, a debugger for the firmware it runs, and a Zig library other programs
embed. The execution engine, CPU core and disassembler are Zig, and no C
library is linked beyond libc. The browser frontend uses TypeScript.

## Install

Zig **0.17.0** is the only compiler needed.

```sh
# linux x86_64; swap the triple for aarch64-linux, x86_64-macos or aarch64-macos
curl -fsSLO https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz
sha256sum zig-x86_64-linux-0.17.0.tar.xz
# 1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
tar xf zig-x86_64-linux-0.17.0.tar.xz -C "$HOME/.local"
export PATH="$HOME/.local/zig-x86_64-linux-0.17.0:$PATH"
```

```sh
zig build                       # zig-out/bin/ra8_emulator
zig build gate                  # zig fmt --check, file and function length, terms
```

## Emulator

```sh
ra8_emulator app.elf                         # RA8D2 is the default part
ra8_emulator app.elf --part ra8p1            # the RA8P1, with its NPU
ra8_emulator app.elf --cpu1 cpu1.elf         # run both cores
ra8_emulator app.elf --ms 2000 --frame-out panel.png
```

The end-of-run report covers the cores, every peripheral the image touched,
and anything it reached that is mapped but not modelled. Run it with no
arguments to list every option.

## Debugger

```sh
ra8_emulator app.elf --debug                 # interactive, at the terminal
ra8_emulator app.elf --debug-script run.gdb  # play a script, print the transcript
ra8_emulator app.elf --gdb 3333              # serve gdb, each core a thread
```

`--cpu1` brings up the second core in any of them, and `core 1` selects it.
An ordinary run takes breakpoints and dumps too: `--break-sym`, `--watch`,
`--dump-regs` and `--dump-mem`. `serve` and `ctl` run a session in one
process and drive it from another, locally or over TCP. The TCP RPC listener
accepts both raw RPC and WebSocket clients:

```sh
zig-out/bin/ra8_emulator serve --listen tcp:127.0.0.1:4567 app.elf
# Optional per-user discovery and hosted GDB for IDE clients:
zig-out/bin/ra8_emulator serve --discover --listen tcp:127.0.0.1:4567 app.elf
```

The Angular PWA workspace is `src/interfaces/gui/`; its TypeScript RPC client
is already available in `src/interfaces/gui/client/`. The native Zig/SDL GUI
has been retired on `dev`; its reference implementation remains on the
`BSIKAR/time-travel` branch. The PWA application is still to be implemented.


## Rebuilt-ELF replay

`ra8_emulator history --root DIR replay-elf SESSION --elf REBUILT.elf [--json]`
opens the history read-only. Exit 0 requires at least one matching root-line
checkpoint, exit 3 reports the first divergence, and exit 1 reports an error
such as `NoRootCheckpoints`, `BuildMismatch`, `ModelMismatch`, or an
`UnsupportedRoot...` configuration. Only the ELF identity is overridden.
The recorded Git commit, source/compiler/dependency-manifest fingerprint,
snapshot version and original snapshot image identity must remain valid.
Historical roots with zero commit or placeholder metadata remain decodable,
but cannot authorize this comparison and are never rewritten.

Replay applies the recorded board-profile text through the existing profile
parser. It currently supports the served RA8P1 defaults: virtual RTC pace,
default RTC start, idle skip, gradient initial camera, and no additional root
memory/grid/attach/fault/input/vsync/loop-skip configuration. Other root
settings are rejected before image loading or replay host preparation.
Single- and dual-core root-line checkpoints at round openings are compared.
CPU0 uses the rebuilt ELF; CPU1 uses its recorded root bytes offline, with
both image identities checked before rebuilt-image or host preparation.
The normal scheduler preserves CPU1 reset hold and firmware release. Both
cores' registers, private/shared memory and board state are compared;
divergence PCs and symbols belong to the reported core. Branch-line replay
and a rebuilt CPU1 image remain unsupported. CPU0 ELF-loaded read-only
bytes and load-time copies are masked only in CPU0 memory, so writes to those
addresses, including RAM code and flash programming, remain unchecked.
CPU1 memory has no image exclusions. Served dual recordings must supply
both images at creation (`serve --cpu1`, or `Served.openInitial`); attaching
CPU1 after a history root is frozen fails with `HistoryAlreadyRooted`.
Existing histories are never upgraded or rewritten to add CPU1.

## Library

Zig packages can depend on this repository and import its `ra8` module:

```zig
// build.zig.zon
.dependencies = .{ .ra8_emulator = .{ .path = "../ra8-emulator" } },

// build.zig
const ra8 = b.dependency("ra8_emulator", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("ra8", ra8.module("ra8"));
```

The harness owns the ELF bytes, CPU0, the board and the display wiring:

```zig
const ra8 = @import("ra8");

var emulator = try ra8.session.harness.open(allocator, io, .{
    .elf_path = "zig-out/image/ra8_ui.elf",
    .input_script = "flows/shell.input",
});
defer emulator.deinit();

const session = emulator.session();
try session.waitSettled(2_000_000_000);
var frame = try session.frame(allocator);
defer frame.deinit(allocator);
```

Taps aim at widgets the firmware publishes on ra8_widget's debug tree, by name,
and can target one part of a widget: a cell of a segmented control or nav bar,
a list row, a pager's previous or next control, or a point inside it:

```zig
try session.tapWidget(allocator, .cpu0, 500_000_000, "settings_button");
try session.tapWidgetPart(allocator, .cpu0, 900_000_000, "shell.tabs", .{ .cell = 2 });
try session.tapWidgetPart(allocator, .cpu0, 1_300_000_000, "apps.list", .{ .row = 0 });
try session.tapWidgetPart(allocator, .cpu0, 1_700_000_000, "chrome.bars.pager", .next);
```

`Options.device` defaults to `ra8p1`; `settle_window_ns` defaults to 50 ms.
Frames are native panel-resolution grayscale bytes owned by the caller.
