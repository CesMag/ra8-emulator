//! Initial CPU1 ownership and frozen history boundaries.
const std = @import("std");
const ra8 = @import("ra8");
const Served = ra8.rpc.served_setup.Served;
const gpa = std.testing.allocator;
const image = "tests/fixtures/trustzone/cpu1_pingpong_ipc.elf";
const second = @embedFile("../../fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf");

test "late CPU1 creation rejects before path access and preserves root and checkpoints" {
    var served: Served = undefined;
    try served.open(gpa, std.testing.io, image, null, .{ .ram_budget = 128 * 1024 * 1024 });
    defer served.deinit();
    var before: std.Io.Writer.Allocating = .init(gpa);
    defer before.deinit();
    try served.owner.state.files.writeTo(&before.writer);
    try std.testing.expectError(error.HistoryAlreadyRooted, served.openSecond("absent-cpu1.elf"));
    try std.testing.expect(served.root.elf1 == null);
    try std.testing.expect(served.second == null);
    try std.testing.expect(served.owner.session().persistent_recorder != null);
    var after: std.Io.Writer.Allocating = .init(gpa);
    defer after.deinit();
    try served.owner.state.files.writeTo(&after.writer);
    try std.testing.expectEqualSlices(u8, before.written(), after.written());
    const plane = served.owner.transport();
    const facts = try plane.history.?.facts(plane.history.?.context);
    try std.testing.expectEqual(@as(usize, 1), facts.checkpoints.len);
}

test "invalid CPU1 initial bytes free partial served ownership" {
    var served: Served = undefined;
    try std.testing.expectError(error.Truncated, served.openInitial(gpa, std.testing.io, image, null, .{ .ram_budget = 128 * 1024 * 1024 }, .{ .bytes = "invalid image" }));
}

test "initial CPU1 bytes are copied and a second attachment is refused" {
    const bytes = try gpa.dupe(u8, second);
    defer gpa.free(bytes);
    var served: Served = undefined;
    try served.openInitial(gpa, std.testing.io, image, null, null, .{ .bytes = bytes });
    defer served.deinit();
    @memset(bytes, 0);
    try std.testing.expectEqualSlices(u8, second, served.second.?.bytes);
    try std.testing.expectEqualSlices(u8, second, served.owner.loadedImage(.cpu1).?.bytes);
    try std.testing.expectError(error.SecondCoreAlreadyOpen, served.openSecond("absent-cpu1.elf"));
}
