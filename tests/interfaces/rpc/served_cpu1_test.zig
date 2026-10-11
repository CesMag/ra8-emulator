//! Tests for served_setup's CPU1 (RA8EMU-1147): a served session brought
//! up with openSecond runs CPU1 by core, and `folded` answers CPU1's
//! sampled stacks named from CPU1's own image. The fixtures are the
//! call-tree pair the test step builds (tests/fixtures/guests.zig).
const std = @import("std");
const ra8 = @import("ra8");
const test_paths = @import("test_paths");

const setup = ra8.rpc.served_setup;
const folded = ra8.rpc.session_folded;
const proto = ra8.rpc.session_rpc;
const stack_samples = ra8.session.stack_samples;
const stack_profile = ra8.session.stack_profile;

fn ask(context: anytype, core: proto.FoldedAsk) ![]const u8 {
    return switch (folded.folded(context, core)) {
        .ok => |rows| rows.text,
        .err => error.Refused,
    };
}

/// Both cores up and sampled; each core then runs its own budget.
fn bothRan(opened: *setup.Served) !void {
    try opened.open(std.testing.allocator, std.testing.io, test_paths.call_tree);
    errdefer opened.deinit();
    opened.owner.session().live.budget = 200_000;
    try opened.openSecond(test_paths.call_tree_cpu1);
    try opened.sampleStacks(200);
    const session = opened.owner.session();
    _ = try session.run(.cpu1, .cont);
    _ = try session.run(.cpu0, .cont);
}

test "folded answers CPU1's stacks, named from CPU1's image" {
    var opened: setup.Served = undefined;
    try bothRan(&opened);
    defer opened.deinit();
    const rows = try ask(&opened.context, .{ .core = .cpu1 });
    try std.testing.expect(std.mem.indexOf(u8, rows, ";call_tree_cpu1.cpu1_outer;call_tree_cpu1.cpu1_wide ") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows, "call_tree.heavy") == null);
    var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer expected.deinit();
    var scratch: [stack_samples.limits.samples]usize = undefined;
    const named = opened.second.?.image.?;
    try stack_samples.fold(&opened.stacks.?.store, .{ .core = 1 }, stack_profile.names(&named), &expected.writer, &scratch);
    try std.testing.expectEqualStrings(expected.written(), rows);
}

test "CPU0's rows stay CPU0's once CPU1 is up" {
    var opened: setup.Served = undefined;
    try bothRan(&opened);
    defer opened.deinit();
    const rows = try ask(&opened.context, .{ .core = .cpu0 });
    try std.testing.expect(std.mem.indexOf(u8, rows, ";call_tree.outer;call_tree.heavy ") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows, "call_tree_cpu1") == null);
}

test "a CPU1 image that cannot be read is refused and leaves CPU0 served" {
    var opened: setup.Served = undefined;
    try opened.open(std.testing.allocator, std.testing.io, test_paths.call_tree);
    defer opened.deinit();
    try std.testing.expectError(error.FileNotFound, opened.openSecond("tests/fixtures/no_such_cpu1.elf"));
    try std.testing.expect(opened.second == null);
}
