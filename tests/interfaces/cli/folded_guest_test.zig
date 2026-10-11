//! RA8EMU-955's done condition: the call-tree pair the test step builds from
//! Zig source (tests/fixtures/guests.zig) runs on both cores with `--profile-folded`,
//! and the folded file has each core's known stacks in the known ratio.
//!
//! Tolerance: CPU0's heavy:light work is 3:1 and CPU1's wide:narrow is 2:1
//! by construction (tests/fixtures/profile/work.zig units); each sampled
//! ratio must land within 15% of that. Call and loop overhead and the
//! sampling period keep it off the exact figure (about 2.98 and 2.03 on
//! the first runs). Rows name functions as the symbol table does, with
//! the Zig module in front (`call_tree.heavy`).
const std = @import("std");
const test_paths = @import("test_paths");

const gpa = std.testing.allocator;
const Term = std.process.Child.Term;
const tolerance = 0.15;

/// Run both halves for `instructions` and return the folded file's bytes.
fn foldedRun(instructions: []const u8) ![]u8 {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/run.folded", .{tmp.sub_path});
    defer gpa.free(path);
    const argv = [_][]const u8{ test_paths.emulator, test_paths.call_tree, "--cpu", "zig", "--cpu1", test_paths.call_tree_cpu1, "--instructions", instructions, "--profile-folded", path, "--profile" };
    const result = try std.process.run(gpa, std.testing.io, .{ .argv = &argv, .stdout_limit = .limited(1 << 20) });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(Term{ .exited = 0 }, result.term);
    return tmp.dir.readFileAlloc(std.testing.io, "run.folded", gpa, .limited(1 << 16));
}

/// Samples on rows of `core` whose stack ends in `leaf`.
fn under(folded: []const u8, core: []const u8, leaf: []const u8) u64 {
    var total: u64 = 0;
    var lines = std.mem.splitScalar(u8, folded, '\n');
    while (lines.next()) |line| {
        const gap = std.mem.lastIndexOfScalar(u8, line, ' ') orelse continue;
        const stack = line[0..gap];
        if (!std.mem.startsWith(u8, stack, core) or stack[core.len] != ';') continue;
        const tail = stack[(std.mem.lastIndexOfScalar(u8, stack, ';') orelse continue) + 1 ..];
        if (!std.mem.eql(u8, tail, leaf)) continue;
        total += std.fmt.parseInt(u64, line[gap + 1 ..], 10) catch continue;
    }
    return total;
}

fn expectRatio(big: u64, small: u64, want: f64) !void {
    try std.testing.expect(small != 0);
    const got = @as(f64, @floatFromInt(big)) / @as(f64, @floatFromInt(small));
    if (@abs(got - want) > want * tolerance) {
        std.debug.print("ratio {d:.3}, want {d} within {d}%\n", .{ got, want, tolerance * 100 });
        return error.RatioOutOfTolerance;
    }
}

test "both cores' known call trees fold into their own rows in the known ratio" {
    const folded = try foldedRun("400000");
    defer gpa.free(folded);
    try std.testing.expect(std.mem.indexOf(u8, folded, "cpu0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, folded, "cpu1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, folded, ";call_tree.outer;call_tree.heavy ") != null);
    try std.testing.expect(std.mem.indexOf(u8, folded, ";call_tree_cpu1.cpu1_outer;call_tree_cpu1.cpu1_wide ") != null);
    try std.testing.expectEqual(@as(u64, 0), under(folded, "cpu1", "call_tree.heavy"));
    try std.testing.expectEqual(@as(u64, 0), under(folded, "cpu0", "call_tree_cpu1.cpu1_wide"));
    try expectRatio(under(folded, "cpu0", "call_tree.heavy"), under(folded, "cpu0", "call_tree.light"), 3.0);
    try expectRatio(under(folded, "cpu1", "call_tree_cpu1.cpu1_wide"), under(folded, "cpu1", "call_tree_cpu1.cpu1_narrow"), 2.0);
}

test "the same run folds the same bytes" {
    const first = try foldedRun("100000");
    defer gpa.free(first);
    const second = try foldedRun("100000");
    defer gpa.free(second);
    try std.testing.expectEqualStrings(first, second);
}
