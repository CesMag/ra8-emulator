//! Unit test binaries and independent suite steps (RA8EMU-1182).
const std = @import("std");

/// The modules every unit test root imports.
pub const Imports = struct {
    filter: ?[]const u8,
    emu: *std.Build.Module,
    cli: *std.Build.Module,
    gate: *std.Build.Module,
    terms: *std.Build.Module,
    table: *std.Build.Module,
};

/// One unit test binary over `root`, with every module the tests import.
pub fn compile(b: *std.Build, name: []const u8, root: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, imports: Imports, exe: *std.Build.Step.Compile, move_peer: *std.Build.Step.Compile, lifecycle_peer: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const tests = b.addTest(.{ .name = name, .filters = if (imports.filter) |text| &.{text} else &.{}, .root_module = b.createModule(.{ .root_source_file = b.path(root), .target = target, .optimize = optimize, .link_libc = true }) });
    tests.root_module.addImport("ra8", imports.emu);
    tests.root_module.addImport("cli_app", imports.cli);
    tests.root_module.addImport("gate", imports.gate);
    tests.root_module.addImport("terms", imports.terms);
    tests.root_module.addImport("example_table", imports.table);
    testPaths(b, tests, exe, move_peer, lifecycle_peer);
    return tests;
}

/// The serve test (RA8EMU-737) spawns the emulator this build produced;
/// guest images built from Zig source ride along (RA8EMU-955).
fn testPaths(b: *std.Build, tests: *std.Build.Step.Compile, exe: *std.Build.Step.Compile, move_peer: *std.Build.Step.Compile, lifecycle_peer: *std.Build.Step.Compile) void {
    const paths = b.addOptions();
    paths.addOptionPath("emulator", exe.getEmittedBin());
    paths.addOptionPath("host_move_peer", move_peer.getEmittedBin());
    paths.addOptionPath("host_lifecycle_peer", lifecycle_peer.getEmittedBin());
    if (exe.root_module.resolved_target.?.result.os.tag == .windows) {
        const fixture = b.addExecutable(.{ .name = "ssh_fixture", .root_module = b.createModule(.{
            .root_source_file = b.path("tests/interfaces/cli/ctl_host_test.zig"),
            .target = exe.root_module.resolved_target.?,
            .optimize = exe.root_module.optimize.?,
        }) });
        paths.addOptionPath("ssh_fixture", fixture.getEmittedBin());
    }
    @import("tests/fixtures/guests.zig").add(b, paths);
    tests.root_module.addOptions("test_paths", paths);
}

/// `test` runs the unit tests and the harness checks; `test-exe` installs the
/// same test binaries without running them, so a cross build can run on another host.
pub fn add(b: *std.Build, tests: []const *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, emu: *std.Build.Module, exe_step: *std.Build.Step) void {
    const test_step = b.step("test", "Run the unit tests and compile the emulator");
    for (tests) |binary| {
        const run = b.addRunArtifact(binary);
        test_step.dependOn(&run.step);
        b.step(binary.name, b.fmt("Run {s} only", .{binary.name})).dependOn(&run.step);
        b.step(b.fmt("{s}-exe", .{binary.name}), b.fmt("Install {s} without running it", .{binary.name}))
            .dependOn(&b.addInstallArtifact(binary, .{}).step);
    }
    harnessChecks(b, target, optimize, emu, test_step, exe_step);
    const test_exe = b.step("test-exe", "Install the unit test binaries without running them, for a run on another host");
    for (tests) |binary| test_exe.dependOn(&b.addInstallArtifact(binary, .{}).step);
}

fn harnessChecks(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, emu: *std.Build.Module, test_step: *std.Build.Step, exe_step: *std.Build.Step) void {
    const consumer = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "run" });
    consumer.addArg("-j1");
    consumer.setCwd(b.path("tests/consumer"));
    const consumer_step = b.step("consumer-smoke", "Build and run the public harness consumer");
    consumer_step.dependOn(&consumer.step);
    test_step.dependOn(&consumer.step);
    test_step.dependOn(exe_step);
    const harness_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/session/harness/harness_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    harness_tests.root_module.addImport("ra8", emu);
    const harness_step = b.step("harness-test", "Run public harness behavior tests");
    harness_step.dependOn(&b.addRunArtifact(harness_tests).step);
}
