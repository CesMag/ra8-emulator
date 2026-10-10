//! The build for the RA8D2 board emulator.
//!
//! One language, one build. The emulator is Zig, CPU and disassembler
//! included; no C library is linked beyond libc, nothing here is exported
//! back to C and there is no C ABI of our own.
//!
//!   zig build         the emulator into zig-out/bin
//!   zig build run     build and run it
//!   zig build test    the unit tests under tests/
//!   zig build gate    zig fmt --check, then the file and function length
//!                     checks in tools/gate.zig
//!   zig build -Dgui   also ra8_gui, the debugger shell in an SDL window;
//!                     SDL is a lazy dependency, fetched and built only
//!                     with -Dgui
//!
//! The source is ten libraries and two applications, each a build module
//! rooted at root.zig in its own directory (ADR 0004, AGENTS.md):
//!
//!   src/host/               ra8_host        the host OS: sockets, files, cameras
//!   src/snapshot/           ra8_snapshot    the snapshot format
//!   src/chip/               ra8_chip        the cores (core/) and the on-chip
//!                                           blocks (periph/)
//!   src/components/         ra8_components  off-chip parts and the plug layer
//!   src/board/              ra8_board       the board, its image loader and run policy
//!   src/session/            ra8_session     the embedding API and the debugger
//!   src/interfaces/render/  ra8_render      drawing and the image encoders
//!   src/interfaces/rpc/     ra8_rpc         the session over a wire
//!   src/interfaces/gdb/     ra8_gdb         the GDB remote server
//!   src/interfaces/usbip/   ra8_usbip       the USB/IP bridge
//!   src/interfaces/cli/     cli_app         ra8_emulator, which never links SDL
//!   src/interfaces/gui/     gui_app         ra8_gui, built under -Dgui
//!
//! src/root.zig is the `ra8` umbrella over the libraries. Tests live in
//! tests/ on mirrored paths, never in a `test` block at the bottom of a
//! source file; tests/all.zig and tests/all_host.zig are the roots that pull
//! them in.
//!
//! Zig 0.17.0, the version pinned in ra8-firmware .devcontainer/Dockerfile.
const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const gui = b.option(bool, "gui", "Fetch SDL3 and build ra8_gui and the GUI tests") orelse false;

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
    const apps = applications(b, target, optimize, libs, firmware);

    const exe = b.addExecutable(.{
        .name = "ra8_emulator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/interfaces/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{ .{ .name = "cli_app", .module = apps.cli }, .{ .name = "ra8_host", .module = libs.host } },
        }),
    });
    b.installArtifact(exe);

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

    // tools/example_table.zig prints the RA8EMU-66 pass table; the tests read
    // its parser through the same module the executable is built from.
    const table_mod = toolModule(b, target, optimize, "tools/example_table.zig");
    const table = b.addRunArtifact(b.addExecutable(.{ .name = "example_table", .root_module = table_mod }));
    table.addPassthruArgs();
    b.step("examples", "Print the example pass table: -- EMULATOR DIR [INSTRUCTIONS]").dependOn(&table.step);

    usbipAttach(b, target, optimize);
    const sdl_mod = sdlModule(b, target, optimize, apps.gui, libs.render, gui);
    const gui_exe = if (sdl_mod) |mod| guiExe(b, target, optimize, apps.gui, libs.host, mod) else null;
    guiTest(b, target, optimize, emu, gui, sdl_mod, gui_exe);

    const imports: TestImports = .{ .emu = emu, .cli = apps.cli, .gui = apps.gui, .widget = firmware.module("ra8_widget"), .gate = gate_mod, .terms = terms_mod, .table = table_mod };
    // Two roots, compiled one after the other under -j1, so the peak memory of
    // a test build is the larger half's (RA8EMU-785).
    const tests = [_]*std.Build.Step.Compile{
        testBinary(b, "ra8_tests", "tests/all.zig", target, optimize, imports, exe),
        testBinary(b, "ra8_host_tests", "tests/all_host.zig", target, optimize, imports, exe),
    };
    unitTests(b, &tests, target, optimize, emu, &exe.step);

    b.step("gate", "Check formatting, file and function length, and terminology").dependOn(gate(b, target));
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
        .{ .name = "ra8_widget", .module = firmware.module("ra8_widget") },
        .{ .name = "ra8_widget_host", .module = firmware.module("ra8_widget_host") },
    });
    const rpc = library(b, target, optimize, "ra8_rpc", "src/interfaces/rpc/root.zig", &.{
        .{ .name = "ra8_session", .module = session },
        .{ .name = "ra8_components", .module = components },
        .{ .name = "ra8_host", .module = host },
        .{ .name = "ra8_rpc_wire", .module = firmware.module("ra8_rpc") },
    });
    const gdb = library(b, target, optimize, "ra8_gdb", "src/interfaces/gdb/root.zig", &.{
        .{ .name = "ra8_session", .module = session },
        .{ .name = "ra8_chip", .module = chip },
        .{ .name = "ra8_host", .module = host },
    });
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

/// The two applications' own files, each a module so that its executable and
/// the tests import the same code (ADR 0004 section 1, RA8EMU-1031).
const Apps = struct {
    cli: *std.Build.Module,
    gui: *std.Build.Module,
};

/// The CLI is given every library. The GUI is given the session, the
/// adapters it talks and draws through, and the host, and neither ra8_board
/// nor ra8_chip, so the compiler keeps it on the Session API (RA8EMU-984).
fn applications(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, libs: Libraries, firmware: *std.Build.Dependency) Apps {
    const wire = firmware.module("ra8_rpc");
    const cli = b.createModule(.{ .root_source_file = b.path("src/interfaces/cli/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    libs.importInto(cli);
    cli.addImport("ra8_rpc_wire", wire);
    const gui = b.createModule(.{ .root_source_file = b.path("src/interfaces/gui/root.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{
        .{ .name = "ra8_session", .module = libs.session },
        .{ .name = "ra8_rpc", .module = libs.rpc },
        .{ .name = "ra8_render", .module = libs.render },
        .{ .name = "ra8_components", .module = libs.components },
        .{ .name = "ra8_host", .module = libs.host },
        .{ .name = "ra8_rpc_wire", .module = wire },
        .{ .name = "ra8_widget", .module = firmware.module("ra8_widget") },
    } });
    return .{ .cli = cli, .gui = gui };
}

/// A tools/ program's module, shared by its executable and its tests.
fn toolModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, path: []const u8) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize });
}

/// The modules every unit test root imports.
const TestImports = struct {
    emu: *std.Build.Module,
    cli: *std.Build.Module,
    gui: *std.Build.Module,
    widget: *std.Build.Module,
    gate: *std.Build.Module,
    terms: *std.Build.Module,
    table: *std.Build.Module,
};

/// One unit test binary over `root`, with every module the tests import.
fn testBinary(b: *std.Build, name: []const u8, root: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, imports: TestImports, exe: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const tests = b.addTest(.{ .name = name, .root_module = b.createModule(.{ .root_source_file = b.path(root), .target = target, .optimize = optimize, .link_libc = true }) });
    tests.root_module.addImport("ra8", imports.emu);
    tests.root_module.addImport("cli_app", imports.cli);
    tests.root_module.addImport("gui_app", imports.gui);
    tests.root_module.addImport("ra8_widget", imports.widget);
    tests.root_module.addImport("gate", imports.gate);
    tests.root_module.addImport("terms", imports.terms);
    tests.root_module.addImport("example_table", imports.table);
    testPaths(b, tests, exe);
    return tests;
}

/// The serve test (RA8EMU-737) spawns the emulator this build produced.
fn testPaths(b: *std.Build, tests: *std.Build.Step.Compile, exe: *std.Build.Step.Compile) void {
    const paths = b.addOptions();
    paths.addOptionPath("emulator", exe.getEmittedBin());
    tests.root_module.addOptions("test_paths", paths);
}

/// `test` runs the unit tests and the harness checks; `test-exe` installs the
/// same test binaries without running them, so a cross build can run on another host.
fn unitTests(b: *std.Build, tests: []const *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, emu: *std.Build.Module, exe_step: *std.Build.Step) void {
    const test_step = b.step("test", "Run the unit tests and compile the emulator");
    for (tests) |binary| test_step.dependOn(&b.addRunArtifact(binary).step);
    harnessChecks(b, target, optimize, emu, test_step, exe_step);
    const test_exe = b.step("test-exe", "Install the unit test binaries without running them, for a run on another host");
    for (tests) |binary| test_exe.dependOn(&b.addInstallArtifact(binary, .{}).step);
}

fn harnessChecks(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, emu: *std.Build.Module, test_step: *std.Build.Step, exe_step: *std.Build.Step) void {
    const consumer = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "run" });
    consumer.setCwd(b.path("tests/consumer"));
    const consumer_step = b.step("consumer-smoke", "Build and run the public harness consumer");
    consumer_step.dependOn(&consumer.step);
    test_step.dependOn(&consumer.step);
    test_step.dependOn(exe_step);
    const harness_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/session/harness_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    harness_tests.root_module.addImport("ra8", emu);
    const harness_step = b.step("harness-test", "Run public harness behavior tests");
    harness_step.dependOn(&b.addRunArtifact(harness_tests).step);
}

/// The light gate AGENTS.md promises and nothing more: `zig fmt --check` over
/// everything we write, then a file and function length check over the same
/// paths. Anything heavier belongs in ra8-firmware, not in a tool.
fn gate(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step {
    const paths = [_][]const u8{ "build.zig", "src", "tests", "tools" };

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
    const paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src", "tests", "tools", "panels", "README.md", "AGENTS.md" };
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

/// The SDL3 backend module (src/interfaces/gui/sdl.zig, RA8EMU-616, ADR 0001 in the
/// knowledge base, RA8EMU-A-8) that ra8_gui and gui-test take under
/// -Dgui. It draws what gui_app hands it and imports nothing else of ours
/// but the render library. SDL is a lazy dependency asked for only under -Dgui, so test and
/// gate never fetch or compile it.
fn sdlModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, gui_app: *std.Build.Module, render: *std.Build.Module, enabled: bool) ?*std.Build.Module {
    if (!enabled) return null;
    const sdl_dep = b.lazyDependency("sdl", .{ .target = target, .optimize = optimize }) orelse return null;
    const sdl_mod = b.createModule(.{ .root_source_file = b.path("src/interfaces/gui/sdl.zig"), .target = target, .optimize = optimize });
    sdl_mod.addImport("gui_app", gui_app);
    sdl_mod.addImport("ra8_render", render);
    sdl_mod.linkLibrary(sdl_dep.artifact("SDL3"));
    sdl_mod.addImport("sdl3", sdlTranslation(b, target, optimize, sdl_dep.artifact("SDL3")));
    return sdl_mod;
}

/// SDL3's C API as a Zig module, translated by the translate-c package
/// (0.17 has no @cImport) against the SDL3 artifact's headers.
fn sdlTranslation(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, sdl: *std.Build.Step.Compile) *std.Build.Module {
    const header = b.addWriteFiles().add("sdl3.h", "#include <SDL3/SDL.h>\n");
    const translator: Translator = .init(b.dependency("translate_c", .{}), .{ .c_source_file = header, .target = target, .optimize = optimize });
    translator.linkLibrary(sdl);
    return translator.mod;
}

/// ra8_gui (RA8EMU-1087, ADR 0004 step 6): the debugger shell in its SDL
/// window, installed next to ra8_emulator in a -Dgui build.
fn guiExe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, gui_app: *std.Build.Module, host: *std.Build.Module, sdl: *std.Build.Module) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "ra8_gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/interfaces/gui/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{ .{ .name = "gui_app", .module = gui_app }, .{ .name = "gui_sdl", .module = sdl }, .{ .name = "ra8_host", .module = host } },
        }),
    });
    b.installArtifact(exe);
    return exe;
}

/// The SDL-backed GUI tests (RA8EMU-733): the geometry presenter against
/// the CPU golden on SDL's software renderer, then the smoke run
/// (RA8EMU-1089), both headless. Kept out of `zig build test` so the tests
/// need no SDL.
fn guiTest(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, emu: *std.Build.Module, enabled: bool, sdl_mod: ?*std.Build.Module, gui_exe: ?*std.Build.Step.Compile) void {
    const step = b.step("gui-test", "Run the SDL-backed GUI tests and the ra8_gui --frames smoke run (needs -Dgui)");
    if (!enabled) {
        step.dependOn(&b.addFail("gui-test needs SDL3: run `zig build gui-test -Dgui`").step);
        return;
    }
    const sdl = sdl_mod orelse return;
    const mod = b.createModule(.{ .root_source_file = b.path("tests/interfaces/gui/sdl_geometry_test.zig"), .target = target, .optimize = optimize });
    mod.addImport("ra8", emu);
    mod.addImport("gui_sdl", sdl);
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    if (gui_exe) |exe| step.dependOn(guiSmoke(b, exe));
}

/// The real ra8_gui with no display: it opens its window on SDL's dummy
/// video driver, serves a fixture image in-process, draws five frames with
/// the image loaded and exits 0.
fn guiSmoke(b: *std.Build, exe: *std.Build.Step.Compile) *std.Build.Step {
    const smoke = b.addRunArtifact(exe);
    smoke.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
    smoke.addArgs(&.{ "--frames", "5" });
    smoke.addFileArg(b.path("tests/fixtures/gpio/blink.elf"));
    smoke.expectExitCode(0);
    return &smoke.step;
}
