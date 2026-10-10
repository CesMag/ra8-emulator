# AGENTS.md

House conventions for ra8-emulator. They win over habit, including habits
carried over from the C tree on `dev` and from ra8-firmware. Read this before
writing code here.

## Layout

ADR 0004 (knowledge base article RA8EMU-A-2) sets the layout. The chip is a
standalone library, the board library uses the chip plus pluggable
components, and the CLI and the GUI are separate applications over one
embedding API. Each library is a named build module. Code in one library
imports another by module name (`@import("ra8_chip")`), never by a relative
path that leaves its own directory. Zig refuses a file import outside a
module's root directory, so the compiler enforces these edges:

```
ra8_host        src/host/             std only: sockets, console, camera backends, host files
ra8_snapshot    src/snapshot/         std only: the snapshot format
ra8_chip        src/chip/             ra8_snapshot
ra8_components  src/components/       ra8_chip line interfaces, ra8_snapshot
ra8_board       src/board/            ra8_chip, ra8_components, ra8_snapshot
ra8_session     src/session/          ra8_board, ra8_chip, ra8_snapshot
ra8_render      src/interfaces/render/ ra8_session value types, ra8_widget
ra8_rpc         src/interfaces/rpc/   ra8_session, ra8_host
ra8_gdb         src/interfaces/gdb/   ra8_session, ra8_host
ra8_usbip       src/interfaces/usbip/ ra8_board, ra8_host
cli app         src/interfaces/cli/   the libraries, never the gui app
gui app         src/interfaces/gui/   the libraries and gui_sdl, never the cli app
tests/          one test file per source file, on the mirrored path
```

Nothing below the applications opens host files or devices. A component that
needs host data declares an interface (a frame source, a byte source, a
socket), and the application fills it from `ra8_host`. `src/root.zig` is the
`ra8` umbrella for tests and embedders. It holds module-name re-exports only:
no file paths, no CLI, no GUI. Scaffolding (hello windows, spikes) does not
stay in the tree or the build.

The tree moved to this layout in the order ADR 0004 gives (epic RA8EMU-985).
New code goes where the ADR puts it.

Inside a module, relative imports down or sideways in the same subtree are
fine. A `../` that leaves the subtree goes through the module root instead.

On-chip blocks keep one directory per block, named for the block
(`periph/gpt/`, `periph/sci/`, `periph/glcdc/`). A genuine singleton stays one
file (`nvic`, `clocks`, `registry`, `crc`), and a block gets its own directory
when it grows a second file. An off-chip part never sits in a controller's
directory: the GT911 is a component, not part of `i3c/`.

`tests/` mirrors the source on the same paths, all the way down:
`src/chip/periph/gpt/gpt_channel.zig` is tested by
`tests/chip/periph/gpt/gpt_channel_test.zig`.

There is no `@cImport` in the tree. SDL3's C API reaches the GUI through the
translate-c package in build.zig, and that is the only C boundary.

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

`tests/all.zig` is the test root and lists every test file, so `zig build test`
runs everything. A test file reaches the code under test through the `ra8`
module (`const crc = ra8.periph.crc;`), never through a relative path into
`src/`. A decl a test needs is `pub`; a fixture the test owns lives in the test
file.

## Idiomatic Zig, not C habits

Slices and fat pointers, never null-terminated strings or a pointer plus a
length, unless a real C boundary needs them, and SDL3 through translate-c is the only
such boundary. Constants are `pub const` grouped under a namespace struct, not
`K_`-prefixed macro constants and not an enum standing in for a bag of
unrelated numbers; enums are for real enumerations. Errors are error sets, not
sentinel returns.

## The build gate is light

`build.zig` carries `zig fmt --check`, simple file and function length
checks, and a terminology check (`tools/terms.zig`), and nothing else. This is deliberately not ra8-firmware's gate set: the
emulator is a tool, and a heavy gate here would cost more than it catches.

## Terminology

The emulator uses ra8-firmware's inclusive vocabulary: bus initiator for
anything that drives the fabric, controller and peripheral for SPI and I2C
roles, CS (chip select) for the select line, and COPI and CIPO for the data
lines. `zig build gate` fails on the old words (tools/terms.zig lists them), so
a hardware manual's name is reworded rather than copied.

## Commits and pull requests

One commit per slice, subject starting `#14 `, authored and committed as the
repository owner. Every slice gets its own branch and its own pull request,
rebase-merged the same session with the head branch deleted. A pull request is
indexable history, not a review queue, so nothing is left open. The pull
request body says what was run and what could not be.
