//! Covers src/components/usb_stick/snapshot.zig (RA8EMU-1104): the MSC
//! target's half of the `usb` section reads back over a fresh target with
//! its cursors rebuilt over that target's own buffers, a cursor outside
//! every buffer cannot be saved, and a cursor the target cannot hold does
//! not fit.
const std = @import("std");
const ra8 = @import("ra8");
const half = ra8.components.usb_stick.snapshot;
const fields = ra8.snapshot.fields;
const stick = ra8.components.usb_stick;
const Target = stick.Target;

var disk_a: [2048]u8 = @splat(0x5A);
var disk_b: [2048]u8 = @splat(0x5A);

/// Fills `target` in place: its data cursor points into its own scratch, so
/// it must not move afterwards.
fn fill(target: *Target) void {
    target.* = .{ .disk = &disk_a };
    target.phase = .data_in;
    target.tag = 0xCAFE;
    target.commands = 4;
    for (&target.scratch, 0..) |*byte, i| byte.* = @intCast(i);
    target.data = target.scratch[2..10];
    target.sink = disk_a[512..1024];
}

test "the target reads back with its cursors over the fresh target's buffers" {
    var target: Target = undefined;
    fill(&target);
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try half.write(&out.writer, &target);

    var fresh: Target = .{ .disk = &disk_b };
    var cursor: fields.Cursor = .{ .bytes = out.written() };
    const staged = try half.read(&cursor, &fresh);
    try std.testing.expect(cursor.done());
    try std.testing.expect(staged.fits());
    try std.testing.expectEqual(@as(u32, 0), fresh.tag);

    staged.install(&fresh);
    try std.testing.expectEqual(@as(u32, 0xCAFE), fresh.tag);
    try std.testing.expectEqual(stick.Phase.data_in, fresh.phase);
    try std.testing.expect(fresh.disk.ptr == @as([*]u8, &disk_b));
    try std.testing.expect(fresh.data.ptr == @as([*]const u8, &fresh.scratch) + 2);
    try std.testing.expectEqual(@as(usize, 8), fresh.data.len);
    try std.testing.expect(fresh.sink.ptr == @as([*]u8, &disk_b) + 512);
    try std.testing.expectEqual(@as(usize, 512), fresh.sink.len);
}

test "a cursor into the INQUIRY data comes back into the INQUIRY data" {
    var target: Target = .{ .disk = &disk_a };
    target.data = stick.inquiry_data[4..12];
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try half.write(&out.writer, &target);
    var fresh: Target = .{};
    var cursor: fields.Cursor = .{ .bytes = out.written() };
    const staged = try half.read(&cursor, &fresh);
    try std.testing.expect(staged.fits());
    staged.install(&fresh);
    try std.testing.expect(fresh.data.ptr == @as([*]const u8, &stick.inquiry_data) + 4);
    try std.testing.expectEqual(@as(usize, 0), fresh.sink.len);
}

test "a cursor outside every buffer cannot be saved" {
    var target: Target = .{ .disk = &disk_a };
    target.data = disk_b[0..4];
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.Stray, half.write(&out.writer, &target));
}

test "a cursor the target cannot hold does not fit, and the target is untouched" {
    var target: Target = undefined;
    fill(&target);
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try half.write(&out.writer, &target);
    var diskless: Target = .{};
    var cursor: fields.Cursor = .{ .bytes = out.written() };
    const staged = try half.read(&cursor, &diskless);
    try std.testing.expect(!staged.fits());
    try std.testing.expectEqualDeep(Target{}, diskless);
}
