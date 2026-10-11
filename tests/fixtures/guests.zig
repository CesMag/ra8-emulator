//! Guest images the test step builds from Zig source (no C, no committed
//! binary): each is a Cortex-M85 executable linked with its own script,
//! handed to the tests as a path in `test_paths`. Not stripped: the
//! profile names its rows from the symbol table.
const std = @import("std");

/// RA8EMU-955: the profile call-tree pair, CPU0's and CPU1's halves.
const images = [_]struct { option: []const u8, root: []const u8, script: []const u8 }{
    .{ .option = "call_tree", .root = "tests/fixtures/profile/call_tree.zig", .script = "tests/fixtures/profile/call_tree.ld" },
    .{ .option = "call_tree_cpu1", .root = "tests/fixtures/profile/call_tree_cpu1.zig", .script = "tests/fixtures/profile/call_tree_cpu1.ld" },
};

/// Build every guest image and add its path to `paths`.
pub fn add(b: *std.Build, paths: *std.Build.Step.Options) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .thumb,
        .os_tag = .freestanding,
        .abi = .eabihf,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m85 },
    });
    for (images) |image| {
        const guest = b.addExecutable(.{
            .name = image.option,
            .root_module = b.createModule(.{ .root_source_file = b.path(image.root), .target = target, .optimize = .ReleaseSmall, .strip = false }),
        });
        guest.setLinkerScript(b.path(image.script));
        guest.entry = .{ .symbol_name = "Reset_Handler" };
        paths.addOptionPath(image.option, guest.getEmittedBin());
    }
}
