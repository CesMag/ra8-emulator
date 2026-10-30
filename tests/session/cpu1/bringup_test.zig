//! Offline CPU1 startup owns its input and publishes only a complete core.
const std = @import("std");
const ra8 = @import("ra8");
const gpa = std.testing.allocator;
const first = @embedFile("../../fixtures/trustzone/cpu1_pingpong_ipc.elf");
const second = @embedFile("../../fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf");

test "failed bytes startup leaves no attached core and permits a successful retry" {
    var h = try ra8.session.harness.open(gpa, std.testing.io, .{ .elf_path = "absent.elf", .elf_bytes = first });
    defer h.deinit();
    var cpu1: ra8.session.cpu1.bringup.Cpu1 = .{};
    try std.testing.expectError(error.Truncated, cpu1.openBytes(gpa, &h, "invalid"));
    try std.testing.expectEqual(@as(usize, 0), cpu1.bytes.len);
    try std.testing.expect(cpu1.image == null);
    try std.testing.expect(h.session().live.other == null);
    try std.testing.expect(h.state.files.pair == null);
    const bytes = try gpa.dupe(u8, second);
    defer gpa.free(bytes);
    try cpu1.openBytes(gpa, &h, bytes);
    defer cpu1.close(gpa);
    @memset(bytes, 0);
    try std.testing.expectEqualSlices(u8, second, cpu1.bytes);
    try std.testing.expectEqualSlices(u8, second, h.loadedImage(.cpu1).?.bytes);
    try std.testing.expect(h.state.files.pair == &cpu1.pair);
}
