const std = @import("std");
const history = @import("ra8").host.history;

test "Windows write-through publication preserves an existing winner and exposes complete bytes" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try temp.dir.writeFile(io, .{ .sub_path = "source", .data = "complete object" });
    var source = try temp.dir.openFile(io, "source", .{ .mode = .read_write });
    try source.sync(io);
    defer source.close(io);
    try history.move.windows.publish(gpa, io, temp.dir, "source", "target");
    try std.testing.expectError(error.FileNotFound, temp.dir.statFile(io, "source", .{}));
    const final = try temp.dir.openFile(io, "target", .{ .mode = .read_write });
    defer final.close(io);
    var bytes: [15]u8 = undefined;
    try std.testing.expectEqual(bytes.len, try final.readPositionalAll(io, &bytes, 0));
    try std.testing.expectEqualStrings("complete object", &bytes);
    try final.sync(io);
    try temp.dir.writeFile(io, .{ .sub_path = "loser", .data = "different" });
    try std.testing.expectError(error.PathAlreadyExists, history.move.windows.publish(gpa, io, temp.dir, "loser", "target"));
    try std.testing.expectEqual(bytes.len, try final.readPositionalAll(io, &bytes, 0));
    try std.testing.expectEqualStrings("complete object", &bytes);
    try std.testing.expectEqual(@as(u64, 9), (try temp.dir.statFile(io, "loser", .{})).size);
}
