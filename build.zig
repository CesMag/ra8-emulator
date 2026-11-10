//! The build for the RA8D2 board emulator.
//!
//! The emulator, CPU and disassembler use Zig. Only libc links to C;
//! nothing is exported back to C and there is no C ABI of our own.
//!
//!    zig build          the emulator into zig-out/bin
//!    zig build run      build and run it
//!    zig build test     the unit tests under tests/
//!    zig build gate     zig fmt --check, then the file and function length
//!                       checks in tools/gate.zig
//!
//! The Zig source is ten libraries and one application, each a build module
//! rooted at root.zig in its own directory (ADR 0004, AGENTS.md):
//!
//!    src/host/                ra8_host        the host OS: sockets, files, cameras
//!    src/snapshot/            ra8_snapshot    the snapshot format
//!    src/chip/                ra8_chip        the cores (core/) and the on-chip
//!                                             blocks (periph/)
//!    src/components/          ra8_components  off-chip parts and the plug layer
//!    src/board/               ra8_board       the board, its image loader and run policy
//!    src/session/             ra8_session     the embedding API and the debugger
//!    src/interfaces/render/   ra8_render      drawing and the image encoders
//!    src/interfaces/rpc/      ra8_rpc          the session over a wire
//!    src/interfaces/gdb/      ra8_gdb          the GDB remote server
//!    src/interfaces/usbip/    ra8_usbip        the USB/IP bridge
//!    src/interfaces/cli/      cli_app          ra8_emulator
//!    src/interfaces/gui/                       TypeScript web client
//!
//! src/root.zig re-exports libraries. Tests mirror source under tests/;
//! tests/all.zig and tests/all_host.zig collect them, with no inline tests.
//!
//! Zig 0.17.0, the version pinned in ra8-firmware .devcontainer/Dockerfile.
const std = @import("std");
const build_tests = @import("build_tests.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const peer_only = b.option(bool, "host-move-peer-only", "Build the internal native directory move peer") orelse false;

    const firmware = b.dependency("ra8_firmware", .{});
    const libs = libraries(b, target, optimize, firmware);
    // The umbrella over the libraries, reached as "ra8" by the tests and by
    // a build that embeds the emulator, so neither walks paths into src/.
    const emu = b.addModule("ra8", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    libs.importInto(emu);
    const cli = application(b, target, optimize, libs, firmware);

    const exe = b.addExecutable(.{
        .name = if (peer_only) "ra8_host_move_peer" else "ra8_emulator",
        .root_module = b.createModule(.{
            .root_source_file = b.path(if (peer_only) "src/interfaces/cli/host_move_main.zig" else "src/interfaces/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{ .{ .name = "cli_app", .module = cli }, .{ .name = "ra8_host", .module = libs.host } },
        }),
    });
    b.installArtifact(exe);
    const peers = testPeers(b, target, optimize, cli);
    const move_peer = if (peer_only) exe else peers[0];
    const lifecycle_peer = peers[1];

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run the emulator").dependOn(&run.step);

    // The gate is a program of its own: build.zig owns the formatter check,
    // tools/gate.zig owns the length checks, and the tests cover its scanner
    // through the same module the gate executable is built from.
    const gate_mod = toolModule(b, target, optimize, "tools/gate.zig");
    // tools/terms.zig is the terminology half, tested the same way.
    const terms_mod = toolModule(b, target, optimize, "tools/terms.zig");

    // tools/example/table.zig prints the RA8EMU-66 pass table; the tests read
    // its parser through the same module the executable is built from.
    const table_mod = toolModule(b, target, optimize, "tools/example/table.zig");
    // The hil config sits outside tools/example/, so it comes in as a module.
    table_mod.addImport("hil_conf", toolModule(b, target, optimize, "tools/hil/conf.zig"));
    const table = b.addRunArtifact(b.addExecutable(.{ .name = "example_table", .root_module = table_mod }));
    table.addPassthruArgs();
    b.step("examples", "Print the example pass table: -- EMULATOR DIR [INSTRUCTIONS]").dependOn(&table.step);

    usbipAttach(b, target, optimize);

    const imports: build_tests.Imports = .{ .filter = b.option([]const u8, "test-filter", "Compile only tests whose name contains this text"), .emu = emu, .cli = cli, .gate = gate_mod, .terms = terms_mod, .table = table_mod };
    // Two roots, one after the other under -j1, so peak memory is the larger suite's (RA8EMU-785).
    const tests = [_]*std.Build.Step.Compile{
        build_tests.compile(b, "ra8_tests", "tests/all.zig", target, optimize, imports, exe, move_peer, lifecycle_peer),
        build_tests.compile(b, "ra8_host_tests", "tests/all_host.zig", target, optimize, imports, exe, move_peer, lifecycle_peer),
    };
    build_tests.add(b, &tests, target, optimize, emu, &exe.step);

    b.step("gate", "Check formatting, file and function length, and terminology").dependOn(gate(b, target));
}

/// The two internal peers the tests spawn as real second processes.
fn testPeers(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, cli: *std.Build.Module) [2]*std.Build.Step.Compile {
    var peers: [2]*std.Build.Step.Compile = undefined;
    const mains = [_][]const u8{ "src/interfaces/cli/host_move_main.zig", "src/interfaces/cli/host_lifecycle_main.zig" };
    for (mains, 0..) |main_file, i| {
        peers[i] = b.addExecutable(.{
            .name = if (i == 0) "ra8_host_move_peer" else "ra8_host_lifecycle_peer",
            .root_module = b.createModule(.{ .root_source_file = b.path(main_file), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "cli_app", .module = cli }} }),
        });
    }
    return peers;
}

/// The libraries that are build modules of their own (ADR 0004 section 1,
/// RA8EMU-1031). Each is rooted in its own directory, so Zig refuses an
/// import that leaves it, and is given exactly the modules it may import:
/// only ones below it, and the host only where the ADR allows it.
const Libraries = struct {
    host: *std.Build.Module,
    snapshot: *std.Build.Module,
    chip: *std.Build.Module,
    components: *std.Build.Module,
    board: *std.Build.Module,
    session: *std.Build.Module,
    render: *std.Build.Module,
    rpc: *std.Build.Module,
    gdb: *std.Build.Module,
    usbip: *std.Build.Module,

    /// Every library, under its own name, into `module`.
    fn importInto(self: Libraries, module: *std.Build.Module) void {
        inline for (@typeInfo(Libraries).@"struct".field_names) |name| module.addImport("ra8_" ++ name, @field(self, name));
    }
};

fn libraries(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, firmware: *std.Build.Dependency) Libraries {
    const host = library(b, target, optimize, "ra8_host", "src/host/root.zig", &.{});
    const snapshot = library(b, target, optimize, "ra8_snapshot", "src/snapshot/root.zig", &.{});
    const chip = library(b, target, optimize, "ra8_chip", "src/chip/root.zig", &.{.{ .name = "ra8_snapshot", .module = snapshot }});
    const components = library(b, target, optimize, "ra8_components", "src/components/root.zig", &.{
        .{ .name = "ra8_chip", .module = chip },
        .{ .name = "ra8_snapshot", .module = snapshot },
    });
    const board = library(b, target, optimize, "ra8_board", "src/board/root.zig", &.{
        .{ .name = "ra8_chip", .module = chip },
        .{ .name = "ra8_components", .module = components },
        .{ .name = "ra8_snapshot", .module = snapshot },
    });
    const session = library(b, target, optimize, "ra8_session", "src/session/root.zig", &.{
        .{ .name = "ra8_board", .module = board },
        .{ .name = "ra8_chip", .module = chip },
        .{ .name = "ra8_components", .module = components },
    });
    const render = library(b, target, optimize, "ra8_render", "src/interfaces/render/root.zig", &.{
        .{ .name = "ra8_session", .module = session },
    });
    const rpc = library(b, target, optimize, "ra8_rpc", "src/interfaces/rpc/root.zig", &.{
        .{ .name = "ra8_session", .module = session },
        .{ .name = "ra8_components", .module = components },
        .{ .name = "ra8_host", .module = host },
        .{ .name = "ra8_board", .module = board },
        .{ .name = "ra8_chip", .module = chip },
        .{ .name = "ra8_rpc_wire", .module = firmware.module("ra8_rpc") },
    });
    const gdb = library(b, target, optimize, "ra8_gdb", "src/interfaces/gdb/root.zig", &.{
        .{ .name = "ra8_session", .module = session },
        .{ .name = "ra8_chip", .module = chip },
        .{ .name = "ra8_host", .module = host },
    });
    // The host listener (RA8EMU-1156) serves a session's gdb port, so it
    // drives the remote protocol through ra8_gdb without importing the CLI.
    rpc.addImport("ra8_gdb", gdb);
    rpc.addOptions("history_build", @import("tools/history_build.zig").options(b));
    const usbip = library(b, target, optimize, "ra8_usbip", "src/interfaces/usbip/root.zig", &.{
        .{ .name = "ra8_board", .module = board },
        .{ .name = "ra8_chip", .module = chip },
        .{ .name = "ra8_host", .module = host },
    });
    return .{ .host = host, .snapshot = snapshot, .chip = chip, .components = components, .board = board, .session = session, .render = render, .rpc = rpc, .gdb = gdb, .usbip = usbip };
}

/// One library module, importable by its name from this build and from a
/// build that depends on this package.
fn library(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, name: []const u8, root: []const u8, imports: []const std.Build.Module.Import) *std.Build.Module {
    return b.addModule(name, .{ .root_source_file = b.path(root), .target = target, .optimize = optimize, .link_libc = true, .imports = imports });
}

/// The CLI owns one module shared by its executable and tests.
fn application(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, libs: Libraries, firmware: *std.Build.Dependency) *std.Build.Module {
    const cli = b.createModule(.{ .root_source_file = b.path("src/interfaces/cli/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    libs.importInto(cli);
    cli.addImport("ra8_rpc_wire", firmware.module("ra8_rpc"));
    return cli;
}

/// A tools/ program's module, shared by its executable and its tests.
fn toolModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, path: []const u8) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize });
}

/// The light gate AGENTS.md promises and nothing more: `zig fmt --check` over
/// everything we write, then a file and function length check over the same
/// paths. Anything heavier belongs in ra8-firmware, not in a tool.
fn gate(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step {
    const paths = [_][]const u8{ "build.zig", "build_tests.zig", "src", "tests", "tools" };

    var fmt_paths: [paths.len]std.Build.LazyPath = undefined;
    for (paths, &fmt_paths) |path, *lazy| lazy.* = b.path(path);
    const fmt = b.addFmt(.{ .paths = &fmt_paths, .check = true });

    const checker = b.addExecutable(.{
        .name = "gate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gate.zig"),
            .target = target,
            .optimize = .debug,
        }),
    });
    const run = b.addRunArtifact(checker);
    run.has_side_effects = true;
    for (paths) |path| run.addArg(path);
    run.step.dependOn(&fmt.step);
    run.step.dependOn(terms(b, target));
    return &run.step;
}

/// tools/terms.zig over everything we write.
fn terms(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step {
    const paths: []const []const u8 = &.{ "build.zig", "build_tests.zig", "build.zig.zon", "src", "tests", "tools", "README.md", "AGENTS.md" };
    const checker = b.addExecutable(.{
        .name = "terms",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/terms.zig"),
            .target = target,
            .optimize = .debug,
        }),
    });
    const run = b.addRunArtifact(checker);
    run.has_side_effects = true;
    for (paths) |path| run.addArg(path);
    return &run.step;
}

/// tools/usbip_attach.zig attaches `--usbip PORT` the way usbip does and
/// checks the descriptor and the vendor loopback (RA8EMU-75 slice 5c).
fn usbipAttach(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const usbip_mod = b.createModule(.{
        .root_source_file = b.path("tools/usbip_attach.zig"),
        .target = target,
        .optimize = optimize,
    });
    usbip_mod.addImport("usbip_client", b.createModule(.{ .root_source_file = b.path("src/interfaces/usbip/client.zig") }));
    const usbip = b.addRunArtifact(b.addExecutable(.{ .name = "usbip_attach", .root_module = usbip_mod }));
    usbip.addPassthruArgs();
    b.step("usbip-attach", "Attach --usbip PORT and check it end to end: -- PORT").dependOn(&usbip.step);
}
