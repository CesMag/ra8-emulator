# AGENTS.md

House conventions for ra8-emulator. They win over habit, including habits
carried over from the C tree on `dev` and from ra8-firmware. Read this before
writing code here.

## Layout

ADR 0004 (knowledge base article RA8EMU-A-2) sets the layout. The chip is a
standalone library, the board library uses the chip plus pluggable
components, and the CLI uses one embedding API. The browser GUI uses WebSocket RPC.
Each Zig library and the CLI application is a named build module.
Code in one module imports another by module name (`@import("ra8_chip")`),
never by a relative path that leaves its own directory. Zig refuses a file
import outside a module's root directory and a module name build.zig did not
give it, so the compiler enforces these edges. The table is what build.zig
declares:

```
ra8_host        src/host/               std only: sockets, console, camera backends, host files
ra8_snapshot    src/snapshot/           std only: the snapshot format
ra8_chip        src/chip/               ra8_snapshot
ra8_components  src/components/         ra8_chip, ra8_snapshot
ra8_board       src/board/              ra8_chip, ra8_components, ra8_snapshot
ra8_session     src/session/            ra8_board, ra8_chip, ra8_components
ra8_render      src/interfaces/render/  ra8_session (board composition and encoders)
ra8_rpc         src/interfaces/rpc/     ra8_session, ra8_components, ra8_host, ra8_rpc_wire
ra8_gdb         src/interfaces/gdb/     ra8_session, ra8_chip, ra8_host
ra8_usbip       src/interfaces/usbip/   ra8_board, ra8_chip, ra8_host
cli_app         src/interfaces/cli/     every library and ra8_rpc_wire
Angular PWA     src/interfaces/gui/     browser client of WebSocket RPC; no Zig module
tests/          one test file per source file, on the mirrored path
```

A module imports only modules below it, and only the adapters and the
applications import `ra8_host`. `ra8_rpc_wire` is ra8-firmware's wire library
(named `ra8_rpc` there). Every Zig module's root file is `root.zig` in its
own directory. The run policy (pacing, speed, soak) is `src/session/run/` and the
image loader is `src/board/image/`.

The CLI executable's entry file is `src/interfaces/cli/main.zig`
(ra8_emulator), which imports `cli_app` and `ra8_host`. The Angular PWA
workspace is `src/interfaces/gui/`, with the shared TypeScript SDK under
`client/`. The PWA reads and changes the machine through WebSocket RPC.
There is no native GUI executable, SDL module, or Zig GUI test suite.

Nothing below the applications opens host files or devices. A component that
needs host data declares an interface (a frame source, a byte source, a
socket), and the application fills it from `ra8_host`. `src/root.zig` is the
`ra8` umbrella for tests and embedders. It holds one re-export line per
library and nothing else: no file paths, no CLI, no GUI. Scaffolding (hello
windows, spikes) does not stay in the tree or the build.

The tree moved to this layout in the order ADR 0004 gives (epic RA8EMU-985).
New code goes where the ADR puts it.

Inside a module, relative imports down or sideways in the same subtree are
fine. A `../` that leaves the subtree goes through the module root instead.

On-chip blocks keep one directory per block, named for the block
(`periph/gpt/`, `periph/sci/`, `periph/glcdc/`). A genuine singleton stays one
file (`nvic`, `clocks`, `registry`, `crc`), and a block gets its own directory
when it grows a second file. An off-chip part never sits in a controller's
directory: the GT911 is a component, not part of `i3c/`.

A file's name does not repeat its directory's: `periph/canfd/tx_status.zig`,
not `periph/canfd/canfd_tx_status.zig`, and `host/sock/windows.zig`, not
`host/sock/sock_windows.zig`. The directory already says whose file it is. The one
file that carries the directory's name is the block's or the part's own
(`canfd/canfd.zig`). A name Zig keeps for itself gets a fuller one:
`canfd/error_flags.zig`, not `error.zig`.

`tests/` mirrors the source on the same paths, all the way down:
`src/chip/periph/gpt/channel.zig` is tested by
`tests/chip/periph/gpt/channel_test.zig`.

There is no `@cImport` in the tree and no SDL or translate-c dependency.

## Documentation and tickets

Tickets (`RA8EMU-N`) and the knowledge base (`RA8EMU-A-N`: design docs, ADRs
and engineering notes, with RA8EMU-A-1 as the index) live on the maintainer's
internal YouTrack instance. It is private: cloning this repository gives no
access to it. An agent without access treats those IDs as plain references.
It never tries to reach the maintainer's instance, guess its address, or look
the IDs up on some other YouTrack. It works from the code, the tests and this
file, and asks the maintainer when it needs a ticket's context. Cite tickets
and articles by ID, never by URL or host.

None of that belongs in the repository. It keeps only what code, tests or
tools read: README.md, this file, fixture provenance READMEs under
`tests/fixtures/`, and test goldens such as `tools/*_expected.md` and
`tests/chip/core/cpu/conformance/coverage.md`.

## One file, one purpose

A file holds one thing, the way a Kotlin class or a DTO gets its own file. A
peripheral block, the bus, the ELF reader, the command line: each is its own
file. Files and functions stay short; split before a file sprawls. Abstraction
is good, over-abstraction is bad: add a seam when a second caller needs it, not
in anticipation of one.

## No inline tests

A `test` block at the bottom of a source file is wrong here. Tests live in
`tests/` mirroring the source path, one file per module:

```
src/chip/periph/crc.zig   ->  tests/chip/periph/crc_test.zig
src/board/image/elf.zig  ->  tests/board/image/elf_test.zig
```

`tests/all.zig` and `tests/all_host.zig` are the test roots and between them
list every test file (`ra8_tests` and `ra8_host_tests`). A test file reaches
a library through the `ra8` module (`const crc = ra8.chip.periph.crc;`) and an
CLI application's files through `cli_app`
(`const cli = @import("cli_app").cli;`), never through a relative path into
`src/`. A decl a test needs is `pub`; a fixture the test owns lives in the test
file.

## Idiomatic Zig, not C habits

Slices and fat pointers, never null-terminated strings or a pointer plus a
length, unless a real host ABI boundary needs them. Constants are `pub const` grouped under a namespace struct, not
`K_`-prefixed macro constants and not an enum standing in for a bag of
unrelated numbers; enums are for real enumerations. Errors are error sets, not
sentinel returns.

## Build and test gate

The merge gate separates compilation and suite execution to fit the
per-command execution cap (~15-minute / 860-second sandbox cap).
Monolithic `zig build test -j1` is prohibited because the full suite has outgrown
single-command execution limits.

Rules per PR (each command gets its own window):

1. Fast validation: `zig fmt --check build.zig build_tests.zig src tests tools`, `zig build gate -j1`, `zig build -j1`. For TypeScript SDK changes, run its typecheck, build, and tests.
2. Targeted suites: run `zig build ra8_tests -j1 -Dtest-filter=chip.periph.crc_test` (or `ra8_host_tests` for host tests), replacing the filter with each changed file's qualified test name. Keep the suite roots so sibling fixtures remain in the module boundary. Use the corresponding `-exe` step to separate compilation from execution when needed.
3. Build each suite separately: `zig build ra8_host_tests-exe -j1` and `zig build ra8_tests-exe -j1`. Run each installed binary directly with `bash tools/test_batch.sh zig-out/bin/NAME /tmp/NAME.log`. Do not use `-Dtest-filter` for these builds. The runner uses `ulimit -v 3000000` and an 800-second timeout. Log attempts append. Rerun interrupted suites from their start; an absent terminal marker or `CUT` is incomplete, never green.
4. Run `zig build consumer-smoke -j1` and `bash tests/tools/test_batch_test.sh` separately. Keep the corpus golden comparisons (`tools/dualcore_corpus.sh`, `tools/modules_corpus.sh`, `tools/fault_corpus.sh`, and `tools/plug_corpus.sh`) as separate commands.
5. Coverage net: a full batched sweep (steps 3+4) on the latest `main` at least once per 90-minute monitor window, run by the monitor or emu-core. A failed or incomplete sweep halts merges until triaged or completed.

`zig build gate` carries `zig fmt --check`, simple file and function length
checks (longest file 400 lines, longest function 80 lines), and a terminology check
(`tools/terms.zig`), and nothing else.

## Terminology

The emulator uses ra8-firmware's inclusive vocabulary: bus initiator for
anything that drives the fabric, controller and peripheral for SPI and I2C
roles, CS (chip select) for the select line, and COPI and CIPO for the data
lines. `zig build gate` fails on the old words (tools/terms.zig lists them), so
a hardware manual's name is reworded rather than copied.

## Commits and pull requests

One commit per slice, with a concise descriptive subject, authored and committed as the
repository owner. Every slice gets its own branch and its own pull request,
rebase-merged the same session with the head branch deleted. A pull request is
indexable history, not a review queue, so nothing is left open. The pull
request body says what was run and what could not be.

## Local environment note (this Linux sandbox only; kept uncommitted)

Zig 0.17 test binaries linked with glibc panic `integer overflow` at startup
and then hang on this box. Zero repo code is involved: `zig test -lc` on an
empty file reproduces it, the same file without `-lc` passes, musl test
binaries run clean, and glibc main binaries run fine. It is a toolchain plus
sandbox interaction, not a bug in this tree.

To run tests here, build them against musl instead:
`zig build <suite>-exe -Dtarget=x86_64-linux-musl -j1`, then run via
`tools/test_batch.sh` as usual. Validated 2026-10-13: ra8_tests COMPLETE
(7673 passed, 8 skipped, 0 failed), consumer-smoke via
`cd tests/consumer && zig build run -Dtarget=x86_64-linux-musl -j1`,
test_batch self-test passed, and the host suite fully covered (1532/1539 OK
in the capped unfiltered run plus the last 7 in targeted filtered runs).
This box has 2 vCPUs, so the unfiltered host run needs a few seconds past
test_batch's 800s cap; a single unfiltered under-800s PASS belongs on a
faster machine.
